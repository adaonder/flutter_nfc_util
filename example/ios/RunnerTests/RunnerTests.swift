import CoreNFC
import Flutter
import UIKit
import XCTest

@testable import nfc_util

/*
 * Unit tests for the pure-logic parts of the Swift implementation.
 *
 * Run `flutter build ios --simulator --debug` from `example/` FIRST, then from `example/ios`
 * run `xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination '<simulator>'`,
 * or use the Runner scheme's test action in Xcode.
 *
 * The build step is not optional. Xcode resolves FlutterGeneratedPluginSwiftPackage before
 * running the Flutter script phase that regenerates it, so a package left over from a device
 * build fails the test target with "requires minimum platform version 15.6 ... but this
 * target supports 13.0".
 *
 * The session lifecycle itself is not reachable from here: `NFCTagReaderSession` refuses to
 * initialize wherever `readingAvailable` is false, which includes every simulator, so
 * anything needing a live session is covered by review rather than by a test. The same goes
 * for `NFCVASReaderSession`, and for anything taking an `NFCTag` -- that enum wraps concrete
 * CoreNFC types with no public initializer.
 */

// MARK: - Thread hop

class OnMainTests: XCTestCase {

  func testStaysSynchronousWhenAlreadyOnThePlatformThread() {
    XCTAssertTrue(Thread.isMainThread, "the assertion below depends on XCTest running this on the main thread")

    var delivered = false
    TagMapper.onMain { delivered = true }

    // Synchronous on purpose. An unconditional hop would defer every reply by a runloop
    // turn, which reorders startSession's reply against the session it has already begun.
    XCTAssertTrue(delivered, "a reply raised on the platform thread must not be deferred")
  }

  func testHopsBackToThePlatformThreadFromABackgroundQueue() {
    let delivered = expectation(description: "result delivered")
    var wasOnMainThread = false

    // Stands in for a CoreNFC completion handler, which runs on the session's own queue.
    DispatchQueue.global(qos: .userInitiated).async {
      XCTAssertFalse(Thread.isMainThread)
      TagMapper.onMain {
        wasOnMainThread = Thread.isMainThread
        delivered.fulfill()
      }
    }

    waitForExpectations(timeout: 2)
    XCTAssertTrue(wasOnMainThread, "channel replies belong to the platform thread")
  }
}

// MARK: - The NDEF probe

/// A stand-in for a discovered tag that counts the round trips the discovery path makes.
// The explicit Objective-C name keeps NSCoding conformance off a mangled private symbol.
@objc(CountingNdefTag)
private final class CountingNdefTag: NSObject, NFCNDEFTag {
  var isAvailable: Bool = true
  var status: NFCNDEFStatus = .readWrite
  private(set) var queryNDEFStatusCount = 0
  private(set) var readNDEFCount = 0

  func queryNDEFStatus(completionHandler: @escaping (NFCNDEFStatus, Int, Error?) -> Void) {
    queryNDEFStatusCount += 1
    completionHandler(status, 128, nil)
  }

  func readNDEF(completionHandler: @escaping (NFCNDEFMessage?, Error?) -> Void) {
    readNDEFCount += 1
    completionHandler(
      NFCNDEFMessage(records: [
        NFCNDEFPayload(
          format: .nfcWellKnown,
          type: Data([0x54]),
          identifier: Data(),
          payload: Data([0x02, 0x65, 0x6E, 0x68, 0x69])
        )
      ]),
      nil
    )
  }

  func writeNDEF(_ ndefMessage: NFCNDEFMessage, completionHandler: @escaping (Error?) -> Void) {
    completionHandler(nil)
  }

  func writeLock(completionHandler: @escaping (Error?) -> Void) {
    completionHandler(nil)
  }

  // Required by NFCNDEFTag's NSSecureCoding/NSCopying conformance; unused by the code here.
  override init() { super.init() }
  static var supportsSecureCoding: Bool { true }
  func encode(with coder: NSCoder) {}
  init?(coder: NSCoder) { nil }
  func copy(with zone: NSZone? = nil) -> Any { self }
}

class NdefProbeTests: XCTestCase {

  func testProbesNdefByDefault() {
    let tag = CountingNdefTag()
    let done = expectation(description: "probe finished")
    var ndef: NdefIosPigeon?

    TagMapper.ndefToWire(tag, skipNdef: false) {
      ndef = $0
      done.fulfill()
    }
    waitForExpectations(timeout: 2)

    XCTAssertEqual(tag.queryNDEFStatusCount, 1)
    XCTAssertEqual(tag.readNDEFCount, 1)
    XCTAssertNotNil(ndef, "Ndef.from(tag) has to keep working when the flag is off")
    XCTAssertEqual(ndef?.status, .readWrite)
    XCTAssertEqual(ndef?.capacity, 128)
    XCTAssertEqual(ndef?.cachedMessage?.records.count, 1)
  }

  func testSkipsBothRoundTripsWhenAsked() {
    let tag = CountingNdefTag()
    let done = expectation(description: "probe finished")
    var ndef: NdefIosPigeon?

    TagMapper.ndefToWire(tag, skipNdef: true) {
      ndef = $0
      done.fulfill()
    }
    waitForExpectations(timeout: 2)

    // The whole point of the flag: no NDEF traffic at all before onDiscovered fires.
    XCTAssertEqual(tag.queryNDEFStatusCount, 0, "queryNDEFStatus is a round trip the caller opted out of")
    XCTAssertEqual(tag.readNDEFCount, 0, "readNDEF is a round trip the caller opted out of")
    XCTAssertNil(ndef, "Ndef.from(tag) must return null, as it does on Android under the same flag")
  }

  func testReportsNothingAndReadsNothingWhenTheTagDoesNotHoldNdef() {
    let tag = CountingNdefTag()
    tag.status = .notSupported
    let done = expectation(description: "probe finished")
    var ndef: NdefIosPigeon?

    TagMapper.ndefToWire(tag, skipNdef: false) {
      ndef = $0
      done.fulfill()
    }
    waitForExpectations(timeout: 2)

    XCTAssertNil(ndef)
    XCTAssertEqual(tag.readNDEFCount, 0, "there is nothing to read on a tag that does not support NDEF")
  }
}

// MARK: - Session options

class PollingOptionTests: XCTestCase {

  func testMapsEveryValue() {
    XCTAssertEqual(TagMapper.pollingOption([.iso14443]), .iso14443)
    XCTAssertEqual(TagMapper.pollingOption([.iso15693]), .iso15693)
    XCTAssertEqual(TagMapper.pollingOption([.iso18092]), .iso18092)
    XCTAssertEqual(
      TagMapper.pollingOption([.iso14443, .iso15693, .iso18092]),
      [.iso14443, .iso15693, .iso18092]
    )
  }

  func testIsEmptyForAnEmptySet() {
    // NFCTagReaderSession returns nil for an empty option set, which startSession reports as
    // "unavailable" rather than pretending a session began.
    XCTAssertEqual(TagMapper.pollingOption([]), NFCTagReaderSession.PollingOption())
  }

  func testRequestFlagsMapEveryValue() {
    XCTAssertEqual(TagMapper.requestFlags([.address]), .address)
    XCTAssertEqual(TagMapper.requestFlags([.highDataRate, .select]), [.highDataRate, .select])
    XCTAssertEqual(TagMapper.requestFlags([]), NFCISO15693RequestFlag())
  }
}

// MARK: - Errors

class ReaderErrorCodeTests: XCTestCase {

  private func error(_ code: NFCReaderError.Code) -> NFCReaderError {
    NFCReaderError(_nsError: NSError(domain: NFCErrorDomain, code: code.rawValue))
  }

  func testNamesTheDocumentedCodes() {
    XCTAssertEqual(TagMapper.readerErrorCode(error(.readerSessionInvalidationErrorUserCanceled)), .userCanceled)
    XCTAssertEqual(TagMapper.readerErrorCode(error(.readerTransceiveErrorTagConnectionLost)), .tagConnectionLost)
    XCTAssertEqual(TagMapper.readerErrorCode(error(.readerErrorRadioDisabled)), .radioDisabled)
    XCTAssertEqual(TagMapper.readerErrorCode(error(.ndefReaderSessionErrorZeroLengthMessage)), .zeroLengthMessage)
  }

  func testCarriesTheCodesNamedOnlyInNewerSdks() {
    // Matched by raw value so this compiles against an older SDK. Losing them would turn an
    // iOS 26 failure into an unexplained `unknown`.
    XCTAssertEqual(TagMapper.readerErrorCode(error(NFCReaderError.Code(rawValue: 7)!)), .ineligible)
    XCTAssertEqual(TagMapper.readerErrorCode(error(NFCReaderError.Code(rawValue: 8)!)), .accessNotAccepted)
  }

  func testDegradesToUnknownRatherThanTrapping() {
    // A code from an SDK newer than this build still has to decode to something.
    XCTAssertEqual(TagMapper.readerErrorCode(error(NFCReaderError.Code(rawValue: 9999)!)), .unknown)
    // And so does a failure that did not come from CoreNFC at all.
    XCTAssertEqual(
      TagMapper.readerErrorCode(NSError(domain: "com.example", code: 1)),
      .unknown
    )
  }

  func testErrorCarriesTheIosSourceAndAMessage() {
    let wire = TagMapper.error(error(.readerSessionInvalidationErrorSessionTimeout))
    XCTAssertEqual(wire.source, .ios)
    XCTAssertEqual(wire.iosCode, .sessionTimeout)
    XCTAssertNil(wire.androidCode)
    XCTAssertFalse(wire.message.isEmpty)
  }
}

// MARK: - Argument narrowing

class ByteNarrowingTests: XCTestCase {

  /// Mirrors the guard the ISO 15693 and APDU entry points apply before touching CoreNFC.
  ///
  /// `UInt8(x)` traps rather than throwing, and the values reaching it are plain 64-bit ints
  /// from the wire. `Iso15693.getSystemInfo()` reports `totalBlocks` for tags with thousands
  /// of blocks, so a loop over every block used to kill the app at block 256.
  private func narrow(_ value: Int64) -> UInt8? { UInt8(exactly: value) }

  func testAcceptsTheWholeByteRange() {
    XCTAssertEqual(narrow(0), 0)
    XCTAssertEqual(narrow(255), 255)
    XCTAssertEqual(narrow(128), 128)
  }

  func testRejectsRatherThanTrappingOutsideIt() {
    XCTAssertNil(narrow(256), "the first block past a 256-block tag must report, not trap")
    XCTAssertNil(narrow(2048), "an ST M24LR64E-R exposes 2048 blocks")
    XCTAssertNil(narrow(-1))
    XCTAssertNil(narrow(Int64.max))
  }
}

// MARK: - NDEF conversion

class NdefConversionTests: XCTestCase {

  func testRoundTripsEveryTypeNameFormat() {
    let formats: [NFCTypeNameFormat] = [.empty, .nfcWellKnown, .media, .absoluteURI, .nfcExternal, .unchanged, .unknown]

    for format in formats {
      let original = NFCNDEFMessage(records: [
        NFCNDEFPayload(format: format, type: Data([0x54]), identifier: Data([0x01]), payload: Data([0x61, 0x62]))
      ])

      let restored = TagMapper.messageFromWire(TagMapper.messageToWire(original))
      let record = restored.records.first

      XCTAssertEqual(record?.typeNameFormat, format, "\(format) did not survive the round trip")
      XCTAssertEqual(record?.type, Data([0x54]))
      XCTAssertEqual(record?.identifier, Data([0x01]))
      XCTAssertEqual(record?.payload, Data([0x61, 0x62]))
    }
  }

  func testCarriesEveryRecordInAMultiRecordMessage() {
    let original = NFCNDEFMessage(records: [
      NFCNDEFPayload(format: .nfcWellKnown, type: Data([0x54]), identifier: Data(), payload: Data([0x01])),
      NFCNDEFPayload(format: .media, type: Data("text/plain".utf8), identifier: Data(), payload: Data([0x02])),
    ])

    XCTAssertEqual(TagMapper.messageToWire(original).records.count, 2)
    XCTAssertEqual(TagMapper.messageFromWire(TagMapper.messageToWire(original)).records.count, 2)
  }

  func testNdefStatusMapsEveryValue() {
    XCTAssertEqual(TagMapper.ndefStatus(.notSupported), .notSupported)
    XCTAssertEqual(TagMapper.ndefStatus(.readOnly), .readOnly)
    XCTAssertEqual(TagMapper.ndefStatus(.readWrite), .readWrite)
  }
}

// MARK: - Value Added Services

class VasTests: XCTestCase {

  func testConfigurationCarriesModeAndIdentifier() {
    let normal = TagMapper.vasConfiguration(
      VasCommandConfigurationPigeon(mode: .normal, passTypeIdentifier: "pass.com.example.loyalty", url: nil)
    )
    XCTAssertEqual(normal.mode, .normal)
    XCTAssertEqual(normal.passTypeIdentifier, "pass.com.example.loyalty")
    XCTAssertNil(normal.url)

    let urlOnly = TagMapper.vasConfiguration(
      VasCommandConfigurationPigeon(
        mode: .urlOnly,
        passTypeIdentifier: "pass.com.example.loyalty",
        url: "https://example.com/enrol"
      )
    )
    XCTAssertEqual(urlOnly.mode, .urlOnly)
    XCTAssertEqual(urlOnly.url?.absoluteString, "https://example.com/enrol")
  }

  func testConfigurationSurvivesAnUnparseableUrl() {
    // A malformed URL must not trap; the session simply gets no fallback URL.
    let configuration = TagMapper.vasConfiguration(
      VasCommandConfigurationPigeon(mode: .normal, passTypeIdentifier: "pass.com.example", url: "")
    )
    XCTAssertEqual(configuration.passTypeIdentifier, "pass.com.example")
  }
}
