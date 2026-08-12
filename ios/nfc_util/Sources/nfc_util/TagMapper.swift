import CoreNFC
import Flutter
import Foundation

/// Converts between CoreNFC types and the generated wire types.
///
/// This replaces the hand-written translator the 2.x line carried on both sides of the
/// channel. What is left is only what Pigeon cannot do: reading CoreNFC's own objects.
enum TagMapper {

  // -------------------------------------------------------------------------------------
  // Threading
  // -------------------------------------------------------------------------------------

  /// Runs `body` on the platform thread.
  ///
  /// Every CoreNFC callback arrives on the session's own queue, but channel replies belong
  /// to the platform thread. Work already on the main thread stays synchronous, so nothing
  /// that was correctly ordered gets reordered.
  static func onMain(_ body: @escaping () -> Void) {
    if Thread.isMainThread {
      body()
    } else {
      DispatchQueue.main.async(execute: body)
    }
  }

  // -------------------------------------------------------------------------------------
  // Sessions
  // -------------------------------------------------------------------------------------

  static func pollingOption(_ options: [PollingOptionPigeon]) -> NFCTagReaderSession.PollingOption {
    var result: NFCTagReaderSession.PollingOption = []
    for option in options {
      switch option {
      case .iso14443: result.insert(.iso14443)
      case .iso15693: result.insert(.iso15693)
      case .iso18092: result.insert(.iso18092)
      }
    }
    return result
  }

  static func requestFlags(_ flags: [Iso15693RequestFlagPigeon]) -> NFCISO15693RequestFlag {
    var result: NFCISO15693RequestFlag = []
    for flag in flags {
      switch flag {
      case .address: result.insert(.address)
      case .dualSubCarriers: result.insert(.dualSubCarriers)
      case .highDataRate: result.insert(.highDataRate)
      case .option: result.insert(.option)
      case .protocolExtension: result.insert(.protocolExtension)
      case .select: result.insert(.select)
      }
    }
    return result
  }

  // -------------------------------------------------------------------------------------
  // Errors
  // -------------------------------------------------------------------------------------

  /// Wraps a CoreNFC failure for the wire.
  ///
  /// `sessionEnded` defaults to true because every `didInvalidateWithError` is exactly that:
  /// CoreNFC has no notion of a session surviving an error. The one caller that passes false
  /// is the connect failure inside `didDetect`, where the session stays up and keeps polling.
  static func error(_ error: Error, sessionEnded: Bool = true) -> NfcErrorPigeon {
    NfcErrorPigeon(
      source: .ios,
      iosCode: readerErrorCode(error),
      androidCode: nil,
      message: error.localizedDescription,
      sessionEnded: sessionEnded
    )
  }

  /// Maps an `NFCReaderError` onto the wire enum.
  ///
  /// The two codes added in the iOS 26 SDK are matched by raw value so this still compiles
  /// against older SDKs. An unrecognised code becomes `.unknown` rather than throwing: a
  /// code this version has never heard of still means the session failed, and turning that
  /// into a crash would be worse than reporting it vaguely.
  static func readerErrorCode(_ error: Error) -> ReaderErrorCodePigeon {
    guard let readerError = error as? NFCReaderError else { return .unknown }

    switch readerError.code {
    case .readerErrorUnsupportedFeature: return .unsupportedFeature
    case .readerErrorSecurityViolation: return .securityViolation
    case .readerErrorInvalidParameter: return .invalidParameter
    case .readerErrorInvalidParameterLength: return .invalidParameterLength
    case .readerErrorParameterOutOfBound: return .parameterOutOfBound
    case .readerErrorRadioDisabled: return .radioDisabled
    case .readerTransceiveErrorTagConnectionLost: return .tagConnectionLost
    case .readerTransceiveErrorRetryExceeded: return .retryExceeded
    case .readerTransceiveErrorTagResponseError: return .tagResponseError
    case .readerTransceiveErrorSessionInvalidated: return .sessionInvalidated
    case .readerTransceiveErrorTagNotConnected: return .tagNotConnected
    case .readerTransceiveErrorPacketTooLong: return .packetTooLong
    case .readerSessionInvalidationErrorUserCanceled: return .userCanceled
    case .readerSessionInvalidationErrorSessionTimeout: return .sessionTimeout
    case .readerSessionInvalidationErrorSessionTerminatedUnexpectedly: return .sessionTerminatedUnexpectedly
    case .readerSessionInvalidationErrorSystemIsBusy: return .systemIsBusy
    case .readerSessionInvalidationErrorFirstNDEFTagRead: return .firstNdefTagRead
    case .tagCommandConfigurationErrorInvalidParameters: return .invalidParameters
    case .ndefReaderSessionErrorTagNotWritable: return .tagNotWritable
    case .ndefReaderSessionErrorTagUpdateFailure: return .tagUpdateFailure
    case .ndefReaderSessionErrorTagSizeTooSmall: return .tagSizeTooSmall
    case .ndefReaderSessionErrorZeroLengthMessage: return .zeroLengthMessage
    default:
      // Raw values 7 and 8 are `readerErrorIneligible` and `readerErrorAccessNotAccepted`,
      // named only in the iOS 26 SDK.
      switch readerError.code.rawValue {
      case 7: return .ineligible
      case 8: return .accessNotAccepted
      default: return .unknown
      }
    }
  }

  static func flutterError(_ error: Error) -> PigeonError {
    PigeonError(
      code: String(describing: readerErrorCode(error)),
      message: error.localizedDescription,
      details: nil
    )
  }

  // -------------------------------------------------------------------------------------
  // NDEF
  // -------------------------------------------------------------------------------------

  static func messageToWire(_ message: NFCNDEFMessage) -> NdefMessagePigeon {
    NdefMessagePigeon(
      records: message.records.map { record in
        NdefRecordPigeon(
          typeNameFormat: typeNameFormat(record.typeNameFormat),
          type: FlutterStandardTypedData(bytes: record.type),
          identifier: FlutterStandardTypedData(bytes: record.identifier),
          payload: FlutterStandardTypedData(bytes: record.payload)
        )
      }
    )
  }

  static func messageFromWire(_ message: NdefMessagePigeon) -> NFCNDEFMessage {
    NFCNDEFMessage(
      records: message.records.map { record in
        NFCNDEFPayload(
          format: typeNameFormat(record.typeNameFormat),
          type: record.type.data,
          identifier: record.identifier.data,
          payload: record.payload.data
        )
      }
    )
  }

  private static func typeNameFormat(_ format: NFCTypeNameFormat) -> TypeNameFormatPigeon {
    switch format {
    case .empty: return .empty
    case .nfcWellKnown: return .wellKnown
    case .media: return .media
    case .absoluteURI: return .absoluteUri
    case .nfcExternal: return .external
    case .unchanged: return .unchanged
    default: return .unknown
    }
  }

  private static func typeNameFormat(_ format: TypeNameFormatPigeon) -> NFCTypeNameFormat {
    switch format {
    case .empty: return .empty
    case .wellKnown: return .nfcWellKnown
    case .media: return .media
    case .absoluteUri: return .absoluteURI
    case .external: return .nfcExternal
    case .unchanged: return .unchanged
    case .unknown: return .unknown
    }
  }

  static func ndefStatus(_ status: NFCNDEFStatus) -> NdefStatusPigeon {
    switch status {
    case .readOnly: return .readOnly
    case .readWrite: return .readWrite
    default: return .notSupported
    }
  }

  // -------------------------------------------------------------------------------------
  // Tags
  // -------------------------------------------------------------------------------------

  /// Builds the wire tag, reading the NDEF status and content unless asked to skip them.
  ///
  /// The NDEF probe is two round trips over the air before the app hears about the tag, and
  /// a tag holding a large message makes the second one slow. `skipNdef` is pure profit for
  /// an app that only sends APDUs.
  static func tagToWire(
    _ tag: NFCTag,
    handle: String,
    skipNdef: Bool,
    completion: @escaping (TagPigeon) -> Void
  ) {
    var wire = TagPigeon(handle: handle)

    switch tag {
    case .feliCa(let felica):
      wire.id = FlutterStandardTypedData(bytes: felica.currentIDm)
      wire.felica = FeliCaPigeon(
        currentSystemCode: FlutterStandardTypedData(bytes: felica.currentSystemCode),
        currentIDm: FlutterStandardTypedData(bytes: felica.currentIDm)
      )
    case .iso7816(let card):
      wire.id = FlutterStandardTypedData(bytes: card.identifier)
      wire.iso7816 = Iso7816Pigeon(
        initialSelectedAID: card.initialSelectedAID,
        historicalBytes: card.historicalBytes.map { FlutterStandardTypedData(bytes: $0) },
        applicationData: card.applicationData.map { FlutterStandardTypedData(bytes: $0) },
        proprietaryApplicationDataCoding: card.proprietaryApplicationDataCoding
      )
    case .iso15693(let card):
      wire.id = FlutterStandardTypedData(bytes: card.identifier)
      wire.iso15693 = Iso15693Pigeon(
        icManufacturerCode: Int64(card.icManufacturerCode),
        icSerialNumber: FlutterStandardTypedData(bytes: card.icSerialNumber)
      )
    case .miFare(let card):
      wire.id = FlutterStandardTypedData(bytes: card.identifier)
      wire.mifare = MiFarePigeon(
        family: miFareFamily(card.mifareFamily),
        historicalBytes: card.historicalBytes.map { FlutterStandardTypedData(bytes: $0) }
      )
    @unknown default:
      break
    }

    guard let ndefTag = ndefTag(from: tag) else {
      completion(wire)
      return
    }

    ndefToWire(ndefTag, skipNdef: skipNdef) { ndef in
      wire.ndefIos = ndef
      completion(wire)
    }
  }

  /// Reads a tag's NDEF status and content, or reports nothing when asked to skip.
  ///
  /// Split out of [tagToWire] so it can be driven by a fake: the `NFCTag` enum wraps concrete
  /// CoreNFC types that cannot be constructed in a test, but this takes the protocol.
  static func ndefToWire(
    _ tag: NFCNDEFTag,
    skipNdef: Bool,
    completion: @escaping (NdefIosPigeon?) -> Void
  ) {
    guard !skipNdef else {
      completion(nil)
      return
    }

    tag.queryNDEFStatus { status, capacity, _ in
      guard status != .notSupported else {
        completion(nil)
        return
      }

      tag.readNDEF { message, _ in
        // A tag with nothing written reports an error rather than an empty message; that is
        // not a failure, it means "nothing written yet".
        completion(NdefIosPigeon(
          status: ndefStatus(status),
          capacity: Int64(capacity),
          cachedMessage: message.map(messageToWire)
        ))
      }
    }
  }

  static func ndefTag(from tag: NFCTag) -> NFCNDEFTag? {
    switch tag {
    case .feliCa(let value): return value
    case .iso7816(let value): return value
    case .iso15693(let value): return value
    case .miFare(let value): return value
    @unknown default: return nil
    }
  }

  private static func miFareFamily(_ family: NFCMiFareFamily) -> MiFareFamilyPigeon {
    switch family {
    case .ultralight: return .ultralight
    case .plus: return .plus
    case .desfire: return .desfire
    default: return .unknown
    }
  }

  // -------------------------------------------------------------------------------------
  // Value Added Services
  // -------------------------------------------------------------------------------------

  static func vasConfiguration(_ configuration: VasCommandConfigurationPigeon) -> NFCVASCommandConfiguration {
    NFCVASCommandConfiguration(
      vasMode: configuration.mode == .urlOnly ? .urlOnly : .normal,
      passTypeIdentifier: configuration.passTypeIdentifier,
      url: configuration.url.flatMap(URL.init(string:))
    )
  }

  static func vasResponse(_ response: NFCVASResponse) -> VasResponsePigeon {
    VasResponsePigeon(
      status: vasStatus(response.status),
      vasData: FlutterStandardTypedData(bytes: response.vasData),
      mobileToken: FlutterStandardTypedData(bytes: response.mobileToken)
    )
  }

  private static func vasStatus(_ status: NFCVASResponse.ErrorCode) -> VasResponseErrorCodePigeon {
    switch status {
    case .success: return .success
    case .userIntervention: return .userIntervention
    case .dataNotActivated: return .dataNotActivated
    case .dataNotFound: return .dataNotFound
    case .incorrectData: return .incorrectData
    case .unsupportedApplicationVersion: return .unsupportedApplicationVersion
    case .wrongLCField: return .wrongLcField
    case .wrongParameters: return .wrongParameters
    @unknown default: return .incorrectData
    }
  }
}
