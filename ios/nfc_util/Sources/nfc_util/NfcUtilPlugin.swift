import CoreNFC
import Flutter
import Foundation
import UIKit

public class NfcUtilPlugin: NSObject, FlutterPlugin {

  private var flutterApi: NfcFlutterApi?

  /// Touched only on the main thread.
  private var tagSession: NFCTagReaderSession?
  private var vasSession: NFCVASReaderSession?

  /// Whether the running session should keep polling after each tag.
  private var continuousPolling = false

  /// Whether to skip the NDEF probe at discovery.
  private var skipNdefCheck = false

  /// Written from the CoreNFC delegate queue, read from the platform thread.
  private let tagsLock = NSLock()
  private var tags: [String: NFCTag] = [:]

  /// An NDEF message delivered by background tag reading before Dart asked for it.
  private var pendingInitialNdefMessage: NdefMessagePigeon?

  /// Set when the app was launched by a user activity, so the NDEF message that follows is
  /// held for `takeInitialNdefMessage` rather than pushed at a handler Dart has not
  /// registered yet.
  private var launchedByUserActivity = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NfcUtilPlugin()
    instance.flutterApi = NfcFlutterApi(binaryMessenger: registrar.messenger())
    NfcHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    NfcIosHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    registrar.addApplicationDelegate(instance)
  }

  // -------------------------------------------------------------------------------------
  // Tag bookkeeping
  // -------------------------------------------------------------------------------------

  private func store(_ tag: NFCTag, forHandle handle: String) {
    tagsLock.lock()
    defer { tagsLock.unlock() }
    tags[handle] = tag
  }

  private func removeTag(forHandle handle: String) {
    tagsLock.lock()
    defer { tagsLock.unlock() }
    tags.removeValue(forKey: handle)
  }

  private func removeAllTags() {
    tagsLock.lock()
    defer { tagsLock.unlock() }
    tags.removeAll()
  }

  /// Resolves a handle to whichever CoreNFC protocol the caller asked for.
  private func tag<T>(_ handle: String, as type: T.Type) -> T? {
    tagsLock.lock()
    defer { tagsLock.unlock() }
    guard let tag = tags[handle] else { return nil }

    switch tag {
    case .feliCa(let value): return value as? T
    case .iso7816(let value): return value as? T
    case .iso15693(let value): return value as? T
    case .miFare(let value): return value as? T
    @unknown default: return nil
    }
  }

  private static func notFound<T>() -> Result<T, Error> {
    .failure(PigeonError(code: "invalid_parameter", message: "Tag is not found.", details: nil))
  }

  private static func unavailable<T>(_ message: String) -> Result<T, Error> {
    .failure(PigeonError(code: "unavailable", message: message, details: nil))
  }

  private static func outOfRange<T>(_ name: String, _ value: Int64) -> Result<T, Error> {
    .failure(PigeonError(
      code: "invalid_parameter",
      message: "\(name) must be 0...255, got \(value).",
      details: nil
    ))
  }

  /// Narrows a wire integer to the byte the CoreNFC API takes, reporting instead of trapping.
  ///
  /// Pigeon types every one of these as a 64-bit int, and `UInt8(x)` traps on anything
  /// outside 0...255 -- which is not hypothetical: `Iso15693.getSystemInfo()` reports
  /// `totalBlocks` as a plain int, and a 2048-block tag is ordinary, so the obvious loop over
  /// every block kills the app at block 256. Checked before the tag is resolved, so an
  /// out-of-range argument reads as itself rather than hiding behind "Tag is not found."
  private static func byte<T>(
    _ value: Int64,
    _ name: String,
    _ completion: @escaping (Result<T, Error>) -> Void
  ) -> UInt8? {
    guard let narrowed = UInt8(exactly: value) else {
      TagMapper.onMain { completion(outOfRange(name, value)) }
      return nil
    }
    return narrowed
  }

  /// Resolves a handle and hands the tag to `body`, or completes with "not found".
  private func withTag<Tag, Value>(
    _ handle: String,
    as type: Tag.Type,
    _ completion: @escaping (Result<Value, Error>) -> Void,
    _ body: (Tag) -> Void
  ) {
    guard let tag = tag(handle, as: Tag.self) else {
      TagMapper.onMain { completion(Self.notFound()) }
      return
    }
    body(tag)
  }

  /// Completes on the platform thread with either the error or the mapped value.
  private static func finish<Raw, Value>(
    _ raw: Raw?,
    _ error: Error?,
    _ completion: @escaping (Result<Value, Error>) -> Void,
    _ transform: @escaping (Raw) -> Value
  ) {
    TagMapper.onMain {
      if let error = error {
        completion(.failure(TagMapper.flutterError(error)))
      } else if let raw = raw {
        completion(.success(transform(raw)))
      } else {
        completion(.failure(PigeonError(code: "no_result", message: "The tag returned nothing.", details: nil)))
      }
    }
  }

  /// Completes a command that returns nothing.
  private static func finishVoid(_ error: Error?, _ completion: @escaping (Result<Void, Error>) -> Void) {
    TagMapper.onMain {
      if let error = error {
        completion(.failure(TagMapper.flutterError(error)))
      } else {
        completion(.success(()))
      }
    }
  }
}

// ---------------------------------------------------------------------------------------
// NfcHostApi
// ---------------------------------------------------------------------------------------

extension NfcUtilPlugin: NfcHostApi {

  func checkAvailability() throws -> AvailabilityPigeon {
    // CoreNFC has no "switched off" state to report, so this is enabled or unsupported.
    NFCTagReaderSession.readingAvailable ? .enabled : .unsupported
  }

  func startSession(config: SessionConfigPigeon, completion: @escaping (Result<Void, Error>) -> Void) {
    guard NFCTagReaderSession.readingAvailable else {
      completion(Self.unavailable("This device cannot read NFC tags."))
      return
    }
    guard tagSession == nil else {
      completion(.failure(PigeonError(
        code: "session_already_exists",
        message: "A session is already running. Stop it first.",
        details: nil
      )))
      return
    }

    let pollingOption = TagMapper.pollingOption(config.pollingOptions)
    guard !pollingOption.isEmpty,
          let session = NFCTagReaderSession(pollingOption: pollingOption, delegate: self)
    else {
      completion(Self.unavailable("The requested polling options are not usable on this device."))
      return
    }

    continuousPolling = !config.invalidateAfterFirstRead
    skipNdefCheck = config.skipNdefCheck
    if let alertMessage = config.alertMessage { session.alertMessage = alertMessage }

    tagSession = session
    session.begin()
    completion(.success(()))
  }

  func stopSession(alertMessage: String?, errorMessage: String?, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let session = tagSession else {
      completion(.success(()))
      return
    }

    tagSession = nil
    // Cleared here rather than in the invalidation callback: `invalidate` returns long
    // before CoreNFC calls back, and by then this session is no longer the plugin's.
    removeAllTags()

    if let errorMessage = errorMessage {
      session.invalidate(errorMessage: errorMessage)
    } else {
      if let alertMessage = alertMessage { session.alertMessage = alertMessage }
      session.invalidate()
    }
    completion(.success(()))
  }

  func disposeTag(handle: String) throws {
    removeTag(forHandle: handle)
  }

  func ndefRead(handle: String, completion: @escaping (Result<NdefMessagePigeon?, Error>) -> Void) {
    withTag(handle, as: NFCNDEFTag.self, completion) { tag in
      tag.readNDEF { message, error in
        TagMapper.onMain {
          // A tag with nothing written reports an error rather than an empty message. That
          // is not a failure -- it means "nothing written yet" -- so it maps to null.
          if let message = message {
            completion(.success(TagMapper.messageToWire(message)))
          } else if let error = error, TagMapper.readerErrorCode(error) != .zeroLengthMessage {
            completion(.failure(TagMapper.flutterError(error)))
          } else {
            completion(.success(nil))
          }
        }
      }
    }
  }

  func ndefWrite(handle: String, message: NdefMessagePigeon, completion: @escaping (Result<Void, Error>) -> Void) {
    withTag(handle, as: NFCNDEFTag.self, completion) { tag in
      tag.writeNDEF(TagMapper.messageFromWire(message)) { error in Self.finishVoid(error, completion) }
    }
  }

  func ndefWriteLock(handle: String, completion: @escaping (Result<Void, Error>) -> Void) {
    withTag(handle, as: NFCNDEFTag.self, completion) { tag in
      tag.writeLock { error in Self.finishVoid(error, completion) }
    }
  }
}

// ---------------------------------------------------------------------------------------
// NfcIosHostApi -- sessions
// ---------------------------------------------------------------------------------------

extension NfcUtilPlugin: NfcIosHostApi {

  func tagSessionReadingAvailable() throws -> Bool {
    NFCTagReaderSession.readingAvailable
  }

  func tagSessionSetAlertMessage(alertMessage: String, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let session = tagSession else {
      completion(Self.unavailable("No tag session is running."))
      return
    }
    session.alertMessage = alertMessage
    completion(.success(()))
  }

  func tagSessionRestartPolling(completion: @escaping (Result<Void, Error>) -> Void) {
    guard let session = tagSession else {
      completion(Self.unavailable("No tag session is running."))
      return
    }
    session.restartPolling()
    completion(.success(()))
  }

  func vasSessionReadingAvailable() throws -> Bool {
    NFCVASReaderSession.readingAvailable
  }

  func vasSessionBegin(
    configurations: [VasCommandConfigurationPigeon],
    alertMessage: String?,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard NFCVASReaderSession.readingAvailable else {
      completion(Self.unavailable("This device cannot read Wallet passes."))
      return
    }
    guard vasSession == nil else {
      completion(.failure(PigeonError(
        code: "session_already_exists",
        message: "A VAS session is already running. Stop it first.",
        details: nil
      )))
      return
    }
    guard !configurations.isEmpty else {
      completion(.failure(PigeonError(
        code: "invalid_parameter",
        message: "At least one pass configuration is required.",
        details: nil
      )))
      return
    }

    let session = NFCVASReaderSession(
      vasCommandConfigurations: configurations.map(TagMapper.vasConfiguration),
      delegate: self,
      queue: nil
    )

    if let alertMessage = alertMessage { session.alertMessage = alertMessage }
    vasSession = session
    session.begin()
    completion(.success(()))
  }

  func vasSessionInvalidate(
    alertMessage: String?,
    errorMessage: String?,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let session = vasSession else {
      completion(.success(()))
      return
    }

    vasSession = nil
    if let errorMessage = errorMessage {
      session.invalidate(errorMessage: errorMessage)
    } else {
      if let alertMessage = alertMessage { session.alertMessage = alertMessage }
      session.invalidate()
    }
    completion(.success(()))
  }

  func vasSessionSetAlertMessage(alertMessage: String, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let session = vasSession else {
      completion(Self.unavailable("No VAS session is running."))
      return
    }
    session.alertMessage = alertMessage
    completion(.success(()))
  }

  func ndefQueryStatus(handle: String, completion: @escaping (Result<QueryNdefStatusResponsePigeon, Error>) -> Void) {
    withTag(handle, as: NFCNDEFTag.self, completion) { tag in
      tag.queryNDEFStatus { status, capacity, error in
        TagMapper.onMain {
          if let error = error {
            completion(.failure(TagMapper.flutterError(error)))
          } else {
            completion(.success(QueryNdefStatusResponsePigeon(
              status: TagMapper.ndefStatus(status),
              capacity: Int64(capacity)
            )))
          }
        }
      }
    }
  }

  func takeInitialNdefMessage() throws -> NdefMessagePigeon? {
    let message = pendingInitialNdefMessage
    // Consumed, so a widget rebuild cannot process the same message twice.
    pendingInitialNdefMessage = nil
    return message
  }
}

// ---------------------------------------------------------------------------------------
// NfcIosHostApi -- FeliCa
// ---------------------------------------------------------------------------------------

extension NfcUtilPlugin {

  func felicaPolling(
    handle: String,
    systemCode: FlutterStandardTypedData,
    requestCode: FeliCaPollingRequestCodePigeon,
    timeSlot: FeliCaPollingTimeSlotPigeon,
    completion: @escaping (Result<FeliCaPollingResponsePigeon, Error>) -> Void
  ) {
    withTag(handle, as: NFCFeliCaTag.self, completion) { tag in
      let code: PollingRequestCode = switch requestCode {
      case .noRequest: .noRequest
      case .systemCode: .systemCode
      case .communicationPerformance: .communicationPerformance
      }
      let slot: PollingTimeSlot = switch timeSlot {
      case .max1: .max1
      case .max2: .max2
      case .max4: .max4
      case .max8: .max8
      case .max16: .max16
      }

      tag.polling(systemCode: systemCode.data, requestCode: code, timeSlot: slot) { manufacturer, request, error in
        TagMapper.onMain {
          if let error = error {
            completion(.failure(TagMapper.flutterError(error)))
          } else {
            completion(.success(FeliCaPollingResponsePigeon(
              manufacturerParameter: FlutterStandardTypedData(bytes: manufacturer),
              requestData: FlutterStandardTypedData(bytes: request)
            )))
          }
        }
      }
    }
  }

  func felicaRequestResponse(handle: String, completion: @escaping (Result<Int64, Error>) -> Void) {
    withTag(handle, as: NFCFeliCaTag.self, completion) { tag in
      tag.requestResponse { mode, error in
        TagMapper.onMain {
          if let error = error {
            completion(.failure(TagMapper.flutterError(error)))
          } else {
            completion(.success(Int64(mode)))
          }
        }
      }
    }
  }

  func felicaRequestSystemCode(handle: String, completion: @escaping (Result<[FlutterStandardTypedData], Error>) -> Void) {
    withTag(handle, as: NFCFeliCaTag.self, completion) { tag in
      tag.requestSystemCode { codes, error in
        Self.finish(codes, error, completion) { $0.map { FlutterStandardTypedData(bytes: $0) } }
      }
    }
  }

  func felicaRequestService(
    handle: String,
    nodeCodeList: [FlutterStandardTypedData],
    completion: @escaping (Result<[FlutterStandardTypedData], Error>) -> Void
  ) {
    withTag(handle, as: NFCFeliCaTag.self, completion) { tag in
      tag.requestService(nodeCodeList: nodeCodeList.map { $0.data }) { versions, error in
        Self.finish(versions, error, completion) { $0.map { FlutterStandardTypedData(bytes: $0) } }
      }
    }
  }

  func felicaRequestServiceV2(
    handle: String,
    nodeCodeList: [FlutterStandardTypedData],
    completion: @escaping (Result<FeliCaRequestServiceV2ResponsePigeon, Error>) -> Void
  ) {
    withTag(handle, as: NFCFeliCaTag.self, completion) { tag in
      tag.requestServiceV2(nodeCodeList: nodeCodeList.map { $0.data }) {
        statusFlag1, statusFlag2, encryptionIdentifier, aes, des, error in
        TagMapper.onMain {
          if let error = error {
            completion(.failure(TagMapper.flutterError(error)))
          } else {
            completion(.success(FeliCaRequestServiceV2ResponsePigeon(
              statusFlag1: Int64(statusFlag1),
              statusFlag2: Int64(statusFlag2),
              encryptionIdentifier: Int64(encryptionIdentifier.rawValue),
              nodeKeyVersionListAes: aes.map { FlutterStandardTypedData(bytes: $0) },
              nodeKeyVersionListDes: des.map { FlutterStandardTypedData(bytes: $0) }
            )))
          }
        }
      }
    }
  }

  func felicaReadWithoutEncryption(
    handle: String,
    serviceCodeList: [FlutterStandardTypedData],
    blockList: [FlutterStandardTypedData],
    completion: @escaping (Result<FeliCaReadWithoutEncryptionResponsePigeon, Error>) -> Void
  ) {
    withTag(handle, as: NFCFeliCaTag.self, completion) { tag in
      tag.readWithoutEncryption(
        serviceCodeList: serviceCodeList.map { $0.data },
        blockList: blockList.map { $0.data }
      ) { statusFlag1, statusFlag2, blockData, error in
        TagMapper.onMain {
          if let error = error {
            completion(.failure(TagMapper.flutterError(error)))
          } else {
            completion(.success(FeliCaReadWithoutEncryptionResponsePigeon(
              statusFlag1: Int64(statusFlag1),
              statusFlag2: Int64(statusFlag2),
              blockData: blockData.map { FlutterStandardTypedData(bytes: $0) }
            )))
          }
        }
      }
    }
  }

  func felicaWriteWithoutEncryption(
    handle: String,
    serviceCodeList: [FlutterStandardTypedData],
    blockList: [FlutterStandardTypedData],
    blockData: [FlutterStandardTypedData],
    completion: @escaping (Result<FeliCaStatusFlagPigeon, Error>) -> Void
  ) {
    withTag(handle, as: NFCFeliCaTag.self, completion) { tag in
      tag.writeWithoutEncryption(
        serviceCodeList: serviceCodeList.map { $0.data },
        blockList: blockList.map { $0.data },
        blockData: blockData.map { $0.data }
      ) { statusFlag1, statusFlag2, error in
        TagMapper.onMain {
          if let error = error {
            completion(.failure(TagMapper.flutterError(error)))
          } else {
            completion(.success(FeliCaStatusFlagPigeon(
              statusFlag1: Int64(statusFlag1),
              statusFlag2: Int64(statusFlag2)
            )))
          }
        }
      }
    }
  }

  func felicaRequestSpecificationVersion(
    handle: String,
    completion: @escaping (Result<FeliCaRequestSpecificationVersionResponsePigeon, Error>) -> Void
  ) {
    withTag(handle, as: NFCFeliCaTag.self, completion) { tag in
      tag.requestSpecificationVersion { statusFlag1, statusFlag2, basicVersion, optionVersion, error in
        TagMapper.onMain {
          if let error = error {
            completion(.failure(TagMapper.flutterError(error)))
          } else {
            completion(.success(FeliCaRequestSpecificationVersionResponsePigeon(
              statusFlag1: Int64(statusFlag1),
              statusFlag2: Int64(statusFlag2),
              basicVersion: FlutterStandardTypedData(bytes: basicVersion),
              optionVersion: FlutterStandardTypedData(bytes: optionVersion)
            )))
          }
        }
      }
    }
  }

  func felicaResetMode(handle: String, completion: @escaping (Result<FeliCaStatusFlagPigeon, Error>) -> Void) {
    withTag(handle, as: NFCFeliCaTag.self, completion) { tag in
      tag.resetMode { statusFlag1, statusFlag2, error in
        TagMapper.onMain {
          if let error = error {
            completion(.failure(TagMapper.flutterError(error)))
          } else {
            completion(.success(FeliCaStatusFlagPigeon(
              statusFlag1: Int64(statusFlag1),
              statusFlag2: Int64(statusFlag2)
            )))
          }
        }
      }
    }
  }

  func felicaSendCommand(
    handle: String,
    commandPacket: FlutterStandardTypedData,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    withTag(handle, as: NFCFeliCaTag.self, completion) { tag in
      tag.sendFeliCaCommand(commandPacket: commandPacket.data) { data, error in
        Self.finish(data, error, completion) { FlutterStandardTypedData(bytes: $0) }
      }
    }
  }
}

// ---------------------------------------------------------------------------------------
// NfcIosHostApi -- ISO 15693
// ---------------------------------------------------------------------------------------

extension NfcUtilPlugin {

  func iso15693ReadSingleBlock(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    guard let block = Self.byte(blockNumber, "blockNumber", completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.readSingleBlock(requestFlags: TagMapper.requestFlags(flags), blockNumber: block) { data, error in
        Self.finish(data, error, completion) { FlutterStandardTypedData(bytes: $0) }
      }
    }
  }

  func iso15693WriteSingleBlock(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    dataBlock: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let block = Self.byte(blockNumber, "blockNumber", completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.writeSingleBlock(
        requestFlags: TagMapper.requestFlags(flags),
        blockNumber: block,
        dataBlock: dataBlock.data
      ) { error in Self.finishVoid(error, completion) }
    }
  }

  func iso15693LockBlock(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let block = Self.byte(blockNumber, "blockNumber", completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.lockBlock(requestFlags: TagMapper.requestFlags(flags), blockNumber: block) { error in
        Self.finishVoid(error, completion)
      }
    }
  }

  func iso15693ReadMultipleBlocks(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    numberOfBlocks: Int64,
    completion: @escaping (Result<[FlutterStandardTypedData], Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.readMultipleBlocks(
        requestFlags: TagMapper.requestFlags(flags),
        blockRange: NSRange(location: Int(blockNumber), length: Int(numberOfBlocks))
      ) { blocks, error in
        Self.finish(blocks, error, completion) { $0.map { FlutterStandardTypedData(bytes: $0) } }
      }
    }
  }

  func iso15693WriteMultipleBlocks(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    numberOfBlocks: Int64,
    dataBlocks: [FlutterStandardTypedData],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.writeMultipleBlocks(
        requestFlags: TagMapper.requestFlags(flags),
        blockRange: NSRange(location: Int(blockNumber), length: Int(numberOfBlocks)),
        dataBlocks: dataBlocks.map { $0.data }
      ) { error in Self.finishVoid(error, completion) }
    }
  }

  func iso15693GetMultipleBlockSecurityStatus(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    numberOfBlocks: Int64,
    completion: @escaping (Result<[Int64], Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.getMultipleBlockSecurityStatus(
        requestFlags: TagMapper.requestFlags(flags),
        blockRange: NSRange(location: Int(blockNumber), length: Int(numberOfBlocks))
      ) { status, error in
        Self.finish(status, error, completion) { $0.map { Int64(truncating: $0) } }
      }
    }
  }

  func iso15693WriteAfi(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    afi: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let value = Self.byte(afi, "afi", completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.writeAFI(requestFlags: TagMapper.requestFlags(flags), afi: value) { error in
        Self.finishVoid(error, completion)
      }
    }
  }

  func iso15693LockAfi(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.lockAFI(requestFlags: TagMapper.requestFlags(flags)) { error in Self.finishVoid(error, completion) }
    }
  }

  func iso15693WriteDsfId(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    dsfId: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let value = Self.byte(dsfId, "dsfId", completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.writeDSFID(requestFlags: TagMapper.requestFlags(flags), dsfid: value) { error in
        Self.finishVoid(error, completion)
      }
    }
  }

  func iso15693LockDsfId(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.lockDFSID(requestFlags: TagMapper.requestFlags(flags)) { error in Self.finishVoid(error, completion) }
    }
  }

  func iso15693ResetToReady(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.resetToReady(requestFlags: TagMapper.requestFlags(flags)) { error in Self.finishVoid(error, completion) }
    }
  }

  func iso15693Select(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.select(requestFlags: TagMapper.requestFlags(flags)) { error in Self.finishVoid(error, completion) }
    }
  }

  func iso15693StayQuiet(handle: String, completion: @escaping (Result<Void, Error>) -> Void) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.stayQuiet { error in Self.finishVoid(error, completion) }
    }
  }

  func iso15693ExtendedReadSingleBlock(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.extendedReadSingleBlock(
        requestFlags: TagMapper.requestFlags(flags),
        blockNumber: Int(blockNumber)
      ) { data, error in
        Self.finish(data, error, completion) { FlutterStandardTypedData(bytes: $0) }
      }
    }
  }

  func iso15693ExtendedWriteSingleBlock(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    dataBlock: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.extendedWriteSingleBlock(
        requestFlags: TagMapper.requestFlags(flags),
        blockNumber: Int(blockNumber),
        dataBlock: dataBlock.data
      ) { error in Self.finishVoid(error, completion) }
    }
  }

  func iso15693ExtendedLockBlock(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.extendedLockBlock(requestFlags: TagMapper.requestFlags(flags), blockNumber: Int(blockNumber)) { error in
        Self.finishVoid(error, completion)
      }
    }
  }

  func iso15693ExtendedReadMultipleBlocks(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    numberOfBlocks: Int64,
    completion: @escaping (Result<[FlutterStandardTypedData], Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.extendedReadMultipleBlocks(
        requestFlags: TagMapper.requestFlags(flags),
        blockRange: NSRange(location: Int(blockNumber), length: Int(numberOfBlocks))
      ) { blocks, error in
        Self.finish(blocks, error, completion) { $0.map { FlutterStandardTypedData(bytes: $0) } }
      }
    }
  }

  func iso15693GetSystemInfo(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    completion: @escaping (Result<Iso15693SystemInfoPigeon, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.getSystemInfo(requestFlags: TagMapper.requestFlags(flags)) {
        dataStorageFormatIdentifier, applicationFamilyIdentifier, blockSize, totalBlocks, icReference, error in
        TagMapper.onMain {
          if let error = error {
            completion(.failure(TagMapper.flutterError(error)))
          } else {
            completion(.success(Iso15693SystemInfoPigeon(
              applicationFamilyIdentifier: Int64(applicationFamilyIdentifier),
              blockSize: Int64(blockSize),
              dataStorageFormatIdentifier: Int64(dataStorageFormatIdentifier),
              icReference: Int64(icReference),
              totalBlocks: Int64(totalBlocks)
            )))
          }
        }
      }
    }
  }

  func iso15693CustomCommand(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    customCommandCode: Int64,
    customRequestParameters: FlutterStandardTypedData,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.customCommand(
        requestFlags: TagMapper.requestFlags(flags),
        customCommandCode: Int(customCommandCode),
        customRequestParameters: customRequestParameters.data
      ) { data, error in
        Self.finish(data, error, completion) { FlutterStandardTypedData(bytes: $0) }
      }
    }
  }
}

// ---------------------------------------------------------------------------------------
// NfcIosHostApi -- ISO 7816 and Mifare
// ---------------------------------------------------------------------------------------

extension NfcUtilPlugin {

  func iso7816SendCommand(
    handle: String,
    instructionClass: Int64,
    instructionCode: Int64,
    p1Parameter: Int64,
    p2Parameter: Int64,
    data: FlutterStandardTypedData,
    expectedResponseLength: Int64,
    completion: @escaping (Result<Iso7816ResponseApduPigeon, Error>) -> Void
  ) {
    guard let cla = Self.byte(instructionClass, "instructionClass", completion),
          let ins = Self.byte(instructionCode, "instructionCode", completion),
          let p1 = Self.byte(p1Parameter, "p1Parameter", completion),
          let p2 = Self.byte(p2Parameter, "p2Parameter", completion)
    else { return }
    withTag(handle, as: NFCISO7816Tag.self, completion) { tag in
      let apdu = NFCISO7816APDU(
        instructionClass: cla,
        instructionCode: ins,
        p1Parameter: p1,
        p2Parameter: p2,
        data: data.data,
        expectedResponseLength: Int(expectedResponseLength)
      )
      tag.sendCommand(apdu: apdu) { payload, sw1, sw2, error in
        Self.apduResult(payload, sw1, sw2, error, completion)
      }
    }
  }

  func iso7816SendCommandRaw(
    handle: String,
    data: FlutterStandardTypedData,
    completion: @escaping (Result<Iso7816ResponseApduPigeon, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO7816Tag.self, completion) { tag in
      guard let apdu = NFCISO7816APDU(data: data.data) else {
        TagMapper.onMain {
          completion(.failure(PigeonError(
            code: "invalid_parameter",
            message: "The bytes are not a well-formed command APDU.",
            details: nil
          )))
        }
        return
      }
      tag.sendCommand(apdu: apdu) { payload, sw1, sw2, error in
        Self.apduResult(payload, sw1, sw2, error, completion)
      }
    }
  }

  func mifareSendCommand(
    handle: String,
    commandPacket: FlutterStandardTypedData,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    withTag(handle, as: NFCMiFareTag.self, completion) { tag in
      tag.sendMiFareCommand(commandPacket: commandPacket.data) { data, error in
        Self.finish(data, error, completion) { FlutterStandardTypedData(bytes: $0) }
      }
    }
  }

  func mifareSendIso7816Command(
    handle: String,
    instructionClass: Int64,
    instructionCode: Int64,
    p1Parameter: Int64,
    p2Parameter: Int64,
    data: FlutterStandardTypedData,
    expectedResponseLength: Int64,
    completion: @escaping (Result<Iso7816ResponseApduPigeon, Error>) -> Void
  ) {
    guard let cla = Self.byte(instructionClass, "instructionClass", completion),
          let ins = Self.byte(instructionCode, "instructionCode", completion),
          let p1 = Self.byte(p1Parameter, "p1Parameter", completion),
          let p2 = Self.byte(p2Parameter, "p2Parameter", completion)
    else { return }
    withTag(handle, as: NFCMiFareTag.self, completion) { tag in
      let apdu = NFCISO7816APDU(
        instructionClass: cla,
        instructionCode: ins,
        p1Parameter: p1,
        p2Parameter: p2,
        data: data.data,
        expectedResponseLength: Int(expectedResponseLength)
      )
      tag.sendMiFareISO7816Command(apdu) { payload, sw1, sw2, error in
        Self.apduResult(payload, sw1, sw2, error, completion)
      }
    }
  }

  func mifareSendIso7816CommandRaw(
    handle: String,
    data: FlutterStandardTypedData,
    completion: @escaping (Result<Iso7816ResponseApduPigeon, Error>) -> Void
  ) {
    withTag(handle, as: NFCMiFareTag.self, completion) { tag in
      guard let apdu = NFCISO7816APDU(data: data.data) else {
        TagMapper.onMain {
          completion(.failure(PigeonError(
            code: "invalid_parameter",
            message: "The bytes are not a well-formed command APDU.",
            details: nil
          )))
        }
        return
      }
      tag.sendMiFareISO7816Command(apdu) { payload, sw1, sw2, error in
        Self.apduResult(payload, sw1, sw2, error, completion)
      }
    }
  }

  private static func apduResult(
    _ payload: Data,
    _ sw1: UInt8,
    _ sw2: UInt8,
    _ error: Error?,
    _ completion: @escaping (Result<Iso7816ResponseApduPigeon, Error>) -> Void
  ) {
    TagMapper.onMain {
      if let error = error {
        completion(.failure(TagMapper.flutterError(error)))
      } else {
        completion(.success(Iso7816ResponseApduPigeon(
          payload: FlutterStandardTypedData(bytes: payload),
          statusWord1: Int64(sw1),
          statusWord2: Int64(sw2)
        )))
      }
    }
  }
}

// ---------------------------------------------------------------------------------------
// Tag session delegate
// ---------------------------------------------------------------------------------------

extension NfcUtilPlugin: NFCTagReaderSessionDelegate {

  public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
    TagMapper.onMain { [weak self] in self?.flutterApi?.onSessionBecameActive(kind: .tag) { _ in } }
  }

  public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
    TagMapper.onMain { [weak self] in
      guard let self = self else { return }

      // `invalidate` returns long before CoreNFC calls back, so this can be the death
      // notice of a session that has already been replaced. Acting on it would wipe the
      // live session's tags and leave stopSession a no-op.
      guard self.tagSession === session else { return }

      self.tagSession = nil
      self.removeAllTags()
      self.flutterApi?.onError(kind: .tag, error: TagMapper.error(error)) { _ in }
    }
  }

  public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
    guard let tag = tags.first else {
      session.restartPolling()
      return
    }

    session.connect(to: tag) { [weak self] error in
      guard let self = self else { return }

      if let error = error {
        // Reported rather than swallowed. A dropped connect error leaves the app watching
        // a session that looks alive and delivers nothing, with no way to tell that from a
        // tag simply not having been presented yet.
        TagMapper.onMain { self.flutterApi?.onError(kind: .tag, error: TagMapper.error(error, sessionEnded: false)) { _ in } }
        session.restartPolling()
        return
      }

      let handle = UUID().uuidString
      TagMapper.tagToWire(tag, handle: handle, skipNdef: self.skipNdefCheck) { wire in
        TagMapper.onMain {
          // The NDEF probe is two round trips, and CoreNFC still runs a pending completion
          // after the session dies. Without this the plugin would register a tag in a map
          // that stopSession had just emptied, and hand the app a scan for a session it had
          // already been told was over -- which for a UID-driven app means recording a read
          // the user cancelled.
          guard self.tagSession === session else { return }

          self.store(tag, forHandle: handle)
          self.flutterApi?.onDiscovered(tag: wire) { _ in
            // Only now, once the app has finished with the tag. Restarting as soon as the
            // tag is handed over would drop it out from under an app that is still
            // reading it, which is why onDiscovered is awaited rather than fired.
            if self.continuousPolling, self.tagSession === session {
              session.restartPolling()
            }
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------------------
// VAS session delegate
// ---------------------------------------------------------------------------------------

extension NfcUtilPlugin: NFCVASReaderSessionDelegate {

  public func readerSessionDidBecomeActive(_ session: NFCVASReaderSession) {
    TagMapper.onMain { [weak self] in self?.flutterApi?.onSessionBecameActive(kind: .vas) { _ in } }
  }

  public func readerSession(_ session: NFCVASReaderSession, didInvalidateWithError error: Error) {
    TagMapper.onMain { [weak self] in
      guard let self = self, self.vasSession === session else { return }
      self.vasSession = nil
      self.flutterApi?.onError(kind: .vas, error: TagMapper.error(error)) { _ in }
    }
  }

  public func readerSession(_ session: NFCVASReaderSession, didReceive responses: [NFCVASResponse]) {
    let wire = responses.map(TagMapper.vasResponse)
    TagMapper.onMain { [weak self] in self?.flutterApi?.onVasResponse(responses: wire) { _ in } }
  }
}

// ---------------------------------------------------------------------------------------
// Background tag reading
// ---------------------------------------------------------------------------------------

extension NfcUtilPlugin {

  /// Records whether the app was launched by a user activity rather than handed one while
  /// already running.
  ///
  /// This is the iOS counterpart of Android reading the launching intent in
  /// `onAttachedToActivity`: the launch case has to be told apart explicitly, because the
  /// same delegate method serves both. Inferring it from whether the Flutter engine exists
  /// does not work -- the engine is registered during `didFinishLaunchingWithOptions`, so it
  /// is always there by the time the activity arrives.
  /// The dictionary is `[AnyHashable: Any]`, not `[UIApplication.LaunchOptionsKey: Any]`:
  /// `FlutterApplicationLifeCycleDelegate` declares it as a bare `NSDictionary`, and a
  /// near-miss signature would collide with the optional requirement rather than satisfy it.
  @objc
  public func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [AnyHashable: Any]
  ) -> Bool {
    launchedByUserActivity = launchOptions[UIApplication.LaunchOptionsKey.userActivityDictionary] != nil
    return true
  }

  /// Catches an NDEF message read by iOS with no app running.
  ///
  /// iPhone XS and later read NDEF tags in the background with no code in the app. The
  /// message arrives here as a user activity, but only when the tag holds a URL matching one
  /// of the app's associated domains.
  ///
  /// The signature has to match `FlutterApplicationLifeCycleDelegate`, whose restoration
  /// handler is declared `void (^)(NSArray *)` -- not `UIApplicationDelegate`'s
  /// `[UIUserActivityRestoring]`. Flutter dispatches to plugins through
  /// `respondsToSelector:`, so a near-miss signature is silently never called rather than
  /// failing to compile.
  @objc
  public func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([Any]) -> Void
  ) -> Bool {
    // Consumed here, before the payload is even looked at: the launch hand-off has happened
    // whether or not this particular activity carries NDEF. An app launched by a universal
    // link would otherwise leave the flag set and swallow the next background read -- which
    // is a real tap, arriving while the app is on screen -- into the pending slot.
    let wasLaunch = launchedByUserActivity
    launchedByUserActivity = false

    // `ndefMessagePayload` is non-optional and comes back with no records when the activity
    // is an ordinary universal link rather than a background tag read.
    let payload = userActivity.ndefMessagePayload
    guard !payload.records.isEmpty else { return false }

    let wire = TagMapper.messageToWire(payload)

    if wasLaunch {
      // Held for takeInitialNdefMessage rather than pushed at a Dart handler that main() has
      // not had the chance to register yet. Mirrors takeInitialTag on Android.
      pendingInitialNdefMessage = wire
    } else {
      TagMapper.onMain { [weak self] in self?.flutterApi?.onNdefFromBackground(message: wire) { _ in } }
    }

    // Never claims the activity: the app may also want to route the URL.
    return false
  }
}
