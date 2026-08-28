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
    .failure(PigeonError(code: "invalidParameter", message: "Tag is not found.", details: nil))
  }

  private static func unavailable<T>(_ message: String) -> Result<T, Error> {
    .failure(PigeonError(code: "unavailable", message: message, details: nil))
  }

  private static func outOfRange<T>(_ name: String, _ value: Int64) -> Result<T, Error> {
    .failure(PigeonError(
      code: "invalidParameter",
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

  /// Narrows a wire block range to the `NSRange` the multi-block commands take, reporting
  /// instead of handing CoreNFC something that cannot mean anything.
  ///
  /// The non-extended single-block commands run their block number through [byte], and the
  /// extended ones through [extendedBlockNumber], which is two bytes wide as they are; the
  /// range commands ran theirs through nothing at all, so a negative block number or a
  /// zero-length range reached the framework as an `NSRange` with no defined reading. The
  /// ceiling is the extended
  /// commands' 16-bit block address, and it is deliberately generous rather than the 0...255
  /// the non-extended ones can address: a range this package refuses is one the tag never gets
  /// to answer, and CoreNFC already reports an unaddressable one as `parameterOutOfBound`.
  ///
  /// Both bounds are checked before the sum, which would otherwise overflow -- and trap -- on
  /// a wire value near `Int64.max`.
  private static func blockRange<T>(
    _ blockNumber: Int64,
    _ numberOfBlocks: Int64,
    _ completion: @escaping (Result<T, Error>) -> Void
  ) -> NSRange? {
    let ceiling: Int64 = 0x1_0000
    guard blockNumber >= 0, numberOfBlocks >= 1,
          blockNumber <= ceiling, numberOfBlocks <= ceiling,
          blockNumber + numberOfBlocks <= ceiling
    else {
      TagMapper.onMain {
        completion(.failure(PigeonError(
          code: "invalidParameter",
          message: "blockNumber \(blockNumber) and numberOfBlocks \(numberOfBlocks) are not a block range.",
          details: nil
        )))
      }
      return nil
    }
    return NSRange(location: Int(blockNumber), length: Int(numberOfBlocks))
  }

  /// Narrows a wire integer to the closed range CoreNFC documents for it, reporting instead
  /// of forwarding a number the framework has no reading for.
  ///
  /// The sibling of [byte] for the arguments that are wider than a byte -- an extended block
  /// number, a chunk size -- and that reach CoreNFC as a plain `Int` rather than a `UInt8`.
  /// Some are `NSUInteger` on the ObjC side, where a negative does not arrive small but
  /// enormous, and the rest are `NSInteger` with a documented range a negative simply sits
  /// outside; one bounds check covers both.
  ///
  /// Where the bound comes from is the caller's to say, and the two callers do not answer the
  /// same way: [extendedBlockNumber] quotes Apple, while the chunk size has no documented
  /// range to quote. Each call site states which it is rather than leaving this helper to
  /// imply a provenance it cannot have, holding only the parameter it was handed.
  private static func inRange<T>(
    _ value: Int64,
    _ name: String,
    _ bounds: ClosedRange<Int64>,
    _ completion: @escaping (Result<T, Error>) -> Void
  ) -> Int? {
    guard bounds.contains(value) else {
      TagMapper.onMain {
        completion(.failure(PigeonError(
          code: "invalidParameter",
          message: "\(name) must be \(bounds.lowerBound)...\(bounds.upperBound), got \(value).",
          details: nil
        )))
      }
      return nil
    }
    return Int(value)
  }

  /// Narrows the two-byte block address the extended ISO 15693 commands take.
  ///
  /// Named rather than spelled out at each call site, so the bound is stated once and is
  /// Apple's: "2 bytes block number, valid range from 0 to 65535 inclusively".
  private static func extendedBlockNumber<T>(
    _ value: Int64,
    _ completion: @escaping (Result<T, Error>) -> Void
  ) -> Int? {
    inRange(value, "blockNumber", 0...0xFFFF, completion)
  }

  /// Narrows the Le field of an ISO 7816 command APDU.
  ///
  /// Not [inRange], because the valid set is not a range. Apple's header reads "Valid range
  /// is from 1 to 65536 inclusively; -1 means no response data field is expected", so -1 is
  /// the one negative here that carries meaning instead of being an error -- and zero is
  /// outside the set, because a command expecting nothing back says so with -1 rather than
  /// with a length of none.
  private static func expectedResponseLength<T>(
    _ value: Int64,
    _ completion: @escaping (Result<T, Error>) -> Void
  ) -> Int? {
    guard value == -1 || (1...0x1_0000).contains(value) else {
      TagMapper.onMain {
        completion(.failure(PigeonError(
          code: "invalidParameter",
          message: "expectedResponseLength must be 1...65536, or -1 for no response data, got \(value).",
          details: nil
        )))
      }
      return nil
    }
    return Int(value)
  }

  /// Narrows the retry settings both `WithConfiguration` commands carry.
  ///
  /// `maximumRetries` is an `NSUInteger` and `retryInterval` a count of seconds, so a
  /// negative retry count reaches CoreNFC as a very large one and a negative interval as a
  /// wait that cannot happen. Neither is a number the tag ever gets to refuse, which is the
  /// same reasoning [blockRange] is built on.
  ///
  /// The ceiling is Apple's own, and it is on the base class both configurations inherit
  /// rather than on either initialiser: `NFCTagCommandConfiguration.maximumRetries` in
  /// `NFCTag.h` reads "Valid value is 0 to 256. Default is 0." Unlike [blockRange]'s
  /// deliberately generous ceiling there is no reason to be wider here -- a retry count is
  /// not something a tag answers, so nothing is lost by holding it to the documented range,
  /// and CoreNFC's own answer to a configuration outside it is
  /// `NFCTagCommandConfigurationErrorInvalidParameters`.
  ///
  /// The interval is checked as `>= 0` rather than `!(< 0)` on purpose -- that also refuses a
  /// NaN, which no `Duration` on the Dart side can produce but the wire can still carry. It
  /// gets no ceiling: Apple documents none for it, and a wait long enough to matter ends on
  /// the reader session's own timeout.
  private static func retrySettings<T>(
    _ configuration: Iso15693CommandConfigurationPigeon,
    _ completion: @escaping (Result<T, Error>) -> Void
  ) -> (maximumRetries: Int, retryInterval: TimeInterval)? {
    guard configuration.maximumRetries >= 0, configuration.maximumRetries <= 256,
          configuration.retryIntervalSeconds >= 0
    else {
      TagMapper.onMain {
        completion(.failure(PigeonError(
          code: "invalidParameter",
          message: "maximumRetries must be 0...256 and retryInterval must not be negative, "
            + "got \(configuration.maximumRetries) and \(configuration.retryIntervalSeconds)s.",
          details: nil
        )))
      }
      return nil
    }
    return (Int(configuration.maximumRetries), configuration.retryIntervalSeconds)
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
        completion(.failure(PigeonError(code: "unknown", message: "The tag returned nothing.", details: nil)))
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

  func tagIsAvailable(handle: String) throws -> Bool {
    // A handle the session has already let go of answers false rather than raising: "that
    // tag is gone" is exactly what the caller asked, and is the same answer CoreNFC gives
    // for a tag that has left the field. `__NFCTag` is the CoreNFC protocol every branch of
    // the `NFCTag` enum conforms to; the underscores are Apple's, not this package's.
    tag(handle, as: (any __NFCTag).self)?.isAvailable ?? false
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
        code: "invalidParameter",
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
    guard let range = Self.blockRange(blockNumber, numberOfBlocks, completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.readMultipleBlocks(
        requestFlags: TagMapper.requestFlags(flags),
        blockRange: range
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
    guard let range = Self.blockRange(blockNumber, numberOfBlocks, completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.writeMultipleBlocks(
        requestFlags: TagMapper.requestFlags(flags),
        blockRange: range,
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
    guard let range = Self.blockRange(blockNumber, numberOfBlocks, completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.getMultipleBlockSecurityStatus(
        requestFlags: TagMapper.requestFlags(flags),
        blockRange: range
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
    // The extended commands address two bytes of block, "valid range from 0 to 65535
    // inclusively" -- which is why these three do not run their block number through [byte]
    // the way the non-extended single-block commands do. Widening the address is the whole
    // point of the extended forms; leaving it unchecked was not part of that.
    guard let block = Self.extendedBlockNumber(blockNumber, completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.extendedReadSingleBlock(
        requestFlags: TagMapper.requestFlags(flags),
        blockNumber: block
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
    guard let block = Self.extendedBlockNumber(blockNumber, completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.extendedWriteSingleBlock(
        requestFlags: TagMapper.requestFlags(flags),
        blockNumber: block,
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
    guard let block = Self.extendedBlockNumber(blockNumber, completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.extendedLockBlock(requestFlags: TagMapper.requestFlags(flags), blockNumber: block) { error in
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
    guard let range = Self.blockRange(blockNumber, numberOfBlocks, completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.extendedReadMultipleBlocks(
        requestFlags: TagMapper.requestFlags(flags),
        blockRange: range
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
              totalBlocks: Int64(totalBlocks),
              // Always nil: the 0x2B selector this calls predates the one that returns a
              // UID. `iso15693GetSystemInfoAndUid` is the call that fills it in.
              uid: nil
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
    // 0...255 rather than the 0xA0...0xDF Apple documents, on the same terms as [blockRange]:
    // a command code this package refuses is one the tag never gets to answer, and a code the
    // tag does not implement comes back as an ISO 15693-3 error from the tag itself. What is
    // narrowed here is only what has no defined reading -- and that has two different shapes
    // on the two custom command paths, because CoreNFC takes this one as a signed `NSInteger`
    // and the configuration below as an `NSUInteger`, where a negative arrives enormous.
    guard let code = Self.byte(customCommandCode, "customCommandCode", completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.customCommand(
        requestFlags: TagMapper.requestFlags(flags),
        customCommandCode: Int(code),
        customRequestParameters: customRequestParameters.data
      ) { data, error in
        Self.finish(data, error, completion) { FlutterStandardTypedData(bytes: $0) }
      }
    }
  }

  // CoreNFC.apinotes marks every iOS 14 addition below `SwiftPrivate`, which is why they
  // reach Swift with a leading double underscore -- the unprefixed spelling belongs to the
  // async form. The completion-handler form is the one that fits the rest of this file.
  // All of them are iOS 14 against a 15.6 deployment target, so none needs availability.

  func iso15693SendRequest(
    handle: String,
    flags: Int64,
    commandCode: Int64,
    data: FlutterStandardTypedData?,
    completion: @escaping (Result<Iso15693ResponsePigeon, Error>) -> Void
  ) {
    // The flag byte arrives raw rather than as the wire enum: this carries whatever the tag
    // vendor's command wants in bit 8, which the six named request flags cannot express.
    //
    // Raw is not the same as unbounded, though, and this is the one place where the two are
    // easy to confuse. Apple's header describes the frame as "8 bits request flag, 8 bits
    // command code, and optional data", so both are bytes however little this call interprets
    // them -- and the escape hatch that lets an app reach a command no typed method covers is
    // exactly the call where a wrong number is least likely to be caught anywhere else.
    guard let flag = Self.byte(flags, "requestFlags", completion),
          let code = Self.byte(commandCode, "commandCode", completion)
    else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.__sendRequest(withFlag: Int(flag), commandCode: Int(code), data: data?.data) {
        responseFlag, response, error in
        Self.iso15693Response(responseFlag, response, error, completion)
      }
    }
  }

  func iso15693FastReadMultipleBlocks(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    numberOfBlocks: Int64,
    completion: @escaping (Result<[FlutterStandardTypedData], Error>) -> Void
  ) {
    guard let range = Self.blockRange(blockNumber, numberOfBlocks, completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.__fastReadMultipleBlocks(
        with: TagMapper.requestFlags(flags),
        blockRange: range
      ) { blocks, error in
        Self.finish(blocks, error, completion) { $0.map { FlutterStandardTypedData(bytes: $0) } }
      }
    }
  }

  func iso15693ExtendedFastReadMultipleBlocks(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    numberOfBlocks: Int64,
    completion: @escaping (Result<[FlutterStandardTypedData], Error>) -> Void
  ) {
    guard let range = Self.blockRange(blockNumber, numberOfBlocks, completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.__extendedFastReadMultipleBlocks(
        with: TagMapper.requestFlags(flags),
        blockRange: range
      ) { blocks, error in
        Self.finish(blocks, error, completion) { $0.map { FlutterStandardTypedData(bytes: $0) } }
      }
    }
  }

  func iso15693ExtendedWriteMultipleBlocks(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    numberOfBlocks: Int64,
    dataBlocks: [FlutterStandardTypedData],
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let range = Self.blockRange(blockNumber, numberOfBlocks, completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.__extendedWriteMultipleBlocks(
        withRequestFlags: TagMapper.requestFlags(flags),
        blockRange: range,
        dataBlocks: dataBlocks.map { $0.data }
      ) { error in Self.finishVoid(error, completion) }
    }
  }

  func iso15693ExtendedGetMultipleBlockSecurityStatus(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    blockNumber: Int64,
    numberOfBlocks: Int64,
    completion: @escaping (Result<[Int64], Error>) -> Void
  ) {
    guard let range = Self.blockRange(blockNumber, numberOfBlocks, completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.__extendedGetMultipleBlockSecurityStatus(
        with: TagMapper.requestFlags(flags),
        blockRange: range
      ) { status, error in
        Self.finish(status, error, completion) { $0.map { Int64(truncating: $0) } }
      }
    }
  }

  func iso15693Authenticate(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    cryptoSuiteIdentifier: Int64,
    message: FlutterStandardTypedData,
    completion: @escaping (Result<Iso15693ResponsePigeon, Error>) -> Void
  ) {
    // ISO/IEC 29167 gives the crypto suite indicator one byte, and so does Apple's header.
    // The suite decides how the tag reads `message`, so a suite number that was never one is
    // the argument least worth forwarding: what comes back is a tag interpreting the rest of
    // the frame under rules nobody chose.
    guard let suite = Self.byte(cryptoSuiteIdentifier, "cryptoSuiteIdentifier", completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.__authenticate(
        withRequestFlags: TagMapper.requestFlags(flags),
        cryptoSuiteIdentifier: Int(suite),
        message: message.data
      ) { responseFlag, response, error in
        Self.iso15693Response(responseFlag, response, error, completion)
      }
    }
  }

  func iso15693KeyUpdate(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    keyIdentifier: Int64,
    message: FlutterStandardTypedData,
    completion: @escaping (Result<Iso15693ResponsePigeon, Error>) -> Void
  ) {
    // One byte, as in Apple's header. Narrowed for the same reason as the crypto suite above,
    // and with more at stake: this names the key the tag is about to overwrite.
    guard let key = Self.byte(keyIdentifier, "keyIdentifier", completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.__keyUpdate(
        withRequestFlags: TagMapper.requestFlags(flags),
        keyIdentifier: Int(key),
        message: message.data
      ) { responseFlag, response, error in
        Self.iso15693Response(responseFlag, response, error, completion)
      }
    }
  }

  func iso15693Challenge(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    cryptoSuiteIdentifier: Int64,
    message: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    // As in `iso15693Authenticate`: one byte, and the suite the tag reads `message` under.
    guard let suite = Self.byte(cryptoSuiteIdentifier, "cryptoSuiteIdentifier", completion) else { return }
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.__challenge(
        withRequestFlags: TagMapper.requestFlags(flags),
        cryptoSuiteIdentifier: Int(suite),
        message: message.data
      ) { error in Self.finishVoid(error, completion) }
    }
  }

  func iso15693ReadBuffer(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    completion: @escaping (Result<Iso15693ResponsePigeon, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.__readBuffer(withRequestFlags: TagMapper.requestFlags(flags)) { responseFlag, data, error in
        Self.iso15693Response(responseFlag, data, error, completion)
      }
    }
  }

  func iso15693GetSystemInfoAndUid(
    handle: String,
    flags: [Iso15693RequestFlagPigeon],
    completion: @escaping (Result<Iso15693SystemInfoPigeon, Error>) -> Void
  ) {
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.__getSystemInfoAndUID(with: TagMapper.requestFlags(flags)) {
        uid, dataStorageFormatIdentifier, applicationFamilyIdentifier, blockSize, totalBlocks, icReference, error in
        TagMapper.onMain {
          if let error = error {
            completion(.failure(TagMapper.flutterError(error)))
          } else {
            completion(.success(Iso15693SystemInfoPigeon(
              applicationFamilyIdentifier: Int64(applicationFamilyIdentifier),
              blockSize: Int64(blockSize),
              dataStorageFormatIdentifier: Int64(dataStorageFormatIdentifier),
              icReference: Int64(icReference),
              totalBlocks: Int64(totalBlocks),
              // Nil when the tag answered without one, which CoreNFC reports the same way it
              // reports a missing block count: by leaving the value out rather than failing.
              uid: uid.map { FlutterStandardTypedData(bytes: $0) }
            )))
          }
        }
      }
    }
  }

  // Both configuration-taking commands are the pre-iOS 13 API, and CoreNFC answers them with
  // `unsupportedFeature` unless the process carries the iso15693.tag-identifiers entitlement,
  // which Apple no longer grants. They are here because the retry loop lives inside CoreNFC
  // and cannot be rebuilt from Dart at the same cost; an app without the entitlement wants
  // the plain commands above.

  func iso15693ReadMultipleBlocksWithConfiguration(
    handle: String,
    blockNumber: Int64,
    numberOfBlocks: Int64,
    chunkSize: Int64,
    configuration: Iso15693CommandConfigurationPigeon,
    completion: @escaping (Result<[FlutterStandardTypedData], Error>) -> Void
  ) {
    // chunkSize is an `NSUInteger` count of blocks per command, and the one bound here that is
    // not Apple's: the property says only "may be limited by the tag hardware". So the guard
    // refuses what has no reading at all -- zero blocks per command, and the negatives that
    // would arrive enormous -- and keeps [blockRange]'s 16-bit ceiling above that rather than
    // the 1...256 this command's own range can carry, on [blockRange]'s reasoning: a chunk
    // this package refuses is one CoreNFC never gets to size down or refuse itself.
    guard let range = Self.blockRange(blockNumber, numberOfBlocks, completion),
          let chunk = Self.inRange(chunkSize, "chunkSize", 1...0x1_0000, completion),
          let retries = Self.retrySettings(configuration, completion)
    else { return }
    let readConfiguration = NFCISO15693ReadMultipleBlocksConfiguration(
      range: range,
      chunkSize: chunk,
      maximumRetries: retries.maximumRetries,
      retryInterval: retries.retryInterval
    )
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.readMultipleBlock(readConfiguration: readConfiguration) { data, error in
        Self.finish(data, error, completion) { Self.splitBlocks($0, into: Int(numberOfBlocks)) }
      }
    }
  }

  func iso15693CustomCommandWithConfiguration(
    handle: String,
    manufacturerCode: Int64,
    customCommandCode: Int64,
    customRequestParameters: FlutterStandardTypedData,
    configuration: Iso15693CommandConfigurationPigeon,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    // Both are `NSUInteger` properties Apple documents as byte-wide -- manufacturerCode
    // 0x00...0xFF, customCommandCode 0xA0...0xDF -- so unlike the signed parameter on the
    // plain custom command above, a negative one here does not arrive negative. See there for
    // why the command code is held to a byte rather than to the narrower documented range.
    guard let manufacturer = Self.byte(manufacturerCode, "manufacturerCode", completion),
          let code = Self.byte(customCommandCode, "customCommandCode", completion),
          let retries = Self.retrySettings(configuration, completion)
    else { return }
    let commandConfiguration = NFCISO15693CustomCommandConfiguration(
      manufacturerCode: Int(manufacturer),
      customCommandCode: Int(code),
      requestParameters: customRequestParameters.data,
      maximumRetries: retries.maximumRetries,
      retryInterval: retries.retryInterval
    )
    withTag(handle, as: NFCISO15693Tag.self, completion) { tag in
      tag.sendCustomCommand(commandConfiguration: commandConfiguration) { data, error in
        Self.finish(data, error, completion) { FlutterStandardTypedData(bytes: $0) }
      }
    }
  }

  /// Completes one of the commands that answer with the response flag alongside their data.
  ///
  /// Only `sendRequest` can answer with no data at all, and the wire type has no way to say
  /// that apart from "empty" -- nor any reason to, since a command that succeeded with
  /// nothing to report is not a failure and the flag byte is the part worth reading.
  private static func iso15693Response(
    _ responseFlag: NFCISO15693ResponseFlag,
    _ data: Data?,
    _ error: Error?,
    _ completion: @escaping (Result<Iso15693ResponsePigeon, Error>) -> Void
  ) {
    TagMapper.onMain {
      if let error = error {
        completion(.failure(TagMapper.flutterError(error)))
      } else {
        completion(.success(Iso15693ResponsePigeon(
          flags: TagMapper.responseFlags(responseFlag),
          data: FlutterStandardTypedData(bytes: data ?? Data())
        )))
      }
    }
  }

  /// Cuts the concatenated answer of `readMultipleBlock` back into one element per block.
  ///
  /// It is the one read that hands back a single run of bytes instead of an array, so the
  /// block size has to be recovered by division. A response that does not divide evenly is
  /// handed back whole rather than sliced at a guessed boundary: a block cut in the wrong
  /// place is worse than an uncut one, because it still looks like data.
  ///
  /// An answer with no bytes at all is no blocks, and it has to be caught before the
  /// division: a block size of zero reaches `stride(by:)`, whose "Stride size must not be
  /// zero" precondition traps in release builds as well as debug ones -- so a tag that
  /// answered empty without reporting an error took the app down rather than reading as an
  /// empty read. Nothing is lost by returning no blocks, because there was nothing to cut.
  private static func splitBlocks(_ data: Data, into count: Int) -> [FlutterStandardTypedData] {
    guard !data.isEmpty else { return [] }
    guard count > 0, data.count % count == 0 else { return [FlutterStandardTypedData(bytes: data)] }
    let bytes = [UInt8](data)
    let blockSize = bytes.count / count
    return stride(from: 0, to: bytes.count, by: blockSize).map {
      FlutterStandardTypedData(bytes: Data(bytes[$0..<($0 + blockSize)]))
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
          let p2 = Self.byte(p2Parameter, "p2Parameter", completion),
          let le = Self.expectedResponseLength(expectedResponseLength, completion)
    else { return }
    withTag(handle, as: NFCISO7816Tag.self, completion) { tag in
      let apdu = NFCISO7816APDU(
        instructionClass: cla,
        instructionCode: ins,
        p1Parameter: p1,
        p2Parameter: p2,
        data: data.data,
        expectedResponseLength: le
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
            code: "invalidParameter",
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
          let p2 = Self.byte(p2Parameter, "p2Parameter", completion),
          let le = Self.expectedResponseLength(expectedResponseLength, completion)
    else { return }
    withTag(handle, as: NFCMiFareTag.self, completion) { tag in
      let apdu = NFCISO7816APDU(
        instructionClass: cla,
        instructionCode: ins,
        p1Parameter: p1,
        p2Parameter: p2,
        data: data.data,
        expectedResponseLength: le
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
            code: "invalidParameter",
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

    // The rest of the field is still dropped -- a session addresses one tag at a time -- but
    // the count travels with the tag now. Which of two cards CoreNFC hands over first is not
    // deterministic, so an app that cares can ask the user to tap again with one.
    let otherTagCount = tags.count - 1

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
      TagMapper.tagToWire(
        tag,
        handle: handle,
        otherTagCount: otherTagCount,
        skipNdef: self.skipNdefCheck
      ) { wire in
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
// Background tag reading -- scene lifecycle
// ---------------------------------------------------------------------------------------

extension NfcUtilPlugin: FlutterSceneLifeCycleDelegate {

  /// A tag tapped while the app is running or suspended.
  ///
  /// Without this the delivery relies on Flutter forwarding to the app-delegate hook, which
  /// its own headers describe as a fallback for plugins that are not scene-aware.
  public func scene(_ scene: UIScene, continue userActivity: NSUserActivity) -> Bool {
    let payload = userActivity.ndefMessagePayload
    guard !payload.records.isEmpty else { return false }

    let wire = TagMapper.messageToWire(payload)
    TagMapper.onMain { [weak self] in self?.flutterApi?.onNdefFromBackground(message: wire) { _ in } }

    // Never claims the activity: the app may also want to route the URL.
    return false
  }

  /// A tag that launched the app.
  ///
  /// UIKit does not call `scene(_:continueUserActivity:)` at launch -- the activity arrives
  /// only in the connection options -- so this is the sole path by which
  /// `takeInitialNdefMessage` is ever populated in a scene-based app.
  public func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    // Nullable per FlutterSceneLifeCycle.h: another plugin may already have handled the
    // connection.
    guard let activities = connectionOptions?.userActivities else { return false }
    for activity in activities { captureLaunchActivity(activity) }
    return false
  }
}

// ---------------------------------------------------------------------------------------
// Background tag reading -- application lifecycle
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

  /// Records an NDEF message the app was launched with, from either lifecycle.
  ///
  /// Split out because the launch case arrives through two different doors and neither is
  /// the one that serves a tap on a running app.
  private func captureLaunchActivity(_ userActivity: NSUserActivity) {
    let payload = userActivity.ndefMessagePayload
    guard !payload.records.isEmpty else { return }
    pendingInitialNdefMessage = TagMapper.messageToWire(payload)
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
