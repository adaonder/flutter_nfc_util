// Pigeon schema for nfc_util.
//
// Regenerate with `tool/generate_pigeon.sh` after editing. The generated files are
// checked in; never edit them by hand.
//
// Everything crossing the platform boundary is declared here. There is deliberately no
// hand-written codec: the 3.0.0 rewrite removed `lib/src/translator.dart`,
// `android/.../Translator.kt` and `ios/.../Translator.swift` in favour of this file, so a
// field added on one side cannot silently go missing on the other.
//
// One schema file rather than three: `TagPigeon` carries both the Android and the iOS
// technology objects, and Pigeon cannot share a class across schema files. The iOS host
// API is therefore also generated into Kotlin (and the Android one into Swift) as an
// interface that is simply never registered on that platform.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon.g.dart',
    dartOptions: DartOptions(),
    kotlinOut: 'android/src/main/kotlin/com/onderada/nfc_util/Pigeon.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.onderada.nfc_util'),
    swiftOut: 'ios/nfc_util/Sources/nfc_util/Pigeon.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'nfc_util',
  ),
)
// ---------------------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------------------
/// The kind of tag a session polls for.
enum PollingOptionPigeon { iso14443, iso15693, iso18092 }

/// Whether NFC can be used on this device right now.
enum AvailabilityPigeon { enabled, disabled, unsupported }

/// `NfcAdapter.ACTION_ADAPTER_STATE_CHANGED` states. Android only.
enum AdapterStatePigeon { off, turningOn, on, turningOff }

/// `NfcAdapter.FLAG_READER_*`. Android only.
enum ReaderFlagPigeon { nfcA, nfcB, nfcF, nfcV, nfcBarcode, noPlatformSounds, skipNdefCheck }

/// What `NfcAdapter.setDiscoveryTechnology` polls for. Android only, API 35 and above.
///
/// [disable] and [keep] are not technologies and do not combine with one: the platform
/// spells them as `FLAG_READER_DISABLE` (no bits at all) and `FLAG_READER_KEEP` (bit 31),
/// so a set holding either alongside a technology has no meaningful reading.
enum PollTechPigeon { nfcA, nfcB, nfcF, nfcV, disable, keep }

/// What `NfcAdapter.setDiscoveryTechnology` listens as. Android only, API 35 and above.
///
/// There is no NFC-V entry: the platform offers `FLAG_LISTEN_NFC_PASSIVE_A`, `_B` and `_F`
/// only. See [PollTechPigeon] for [disable] and [keep].
enum ListenTechPigeon { nfcA, nfcB, nfcF, disable, keep }

/// `PollingFrame.POLLING_LOOP_TYPE_*`. Android only, API 35 and above.
enum PollingFrameTypePigeon { a, b, f, off, on, unknown }

/// Which `CardEmulation.NfcEventCallback` method fired. Android only, API 36 and above.
///
/// One flat kind rather than seven callbacks: the interface gains methods with the platform
/// -- API 37 adds `onOffHostAidSelected` -- and a single event class absorbs those without a
/// change to the wire.
enum NfcEventKindPigeon {
  preferredServiceChanged,
  observeModeStateChanged,
  aidConflictOccurred,
  aidNotRouted,
  nfcStateChanged,
  remoteFieldChanged,
  internalError,
}

/// `CardEmulation.NFC_INTERNAL_ERROR_*`. Android only, API 36 and above.
enum NfcInternalErrorPigeon { unknown, nfcCrashRestart, nfcHardwareError, commandTimeout }

/// Selects which `android.nfc.tech` class a tag operation runs against.
///
/// Collapsing the technology into a parameter is what lets one `transceive` replace the
/// seven the 2.x channel had, and one `getMaxTransceiveLength` replace seven more.
/// Only the technologies that answer a raw exchange. NDEF and NdefFormatable are addressed
/// by their own methods, which take no technology.
enum AndroidTechPigeon { nfcA, nfcB, nfcF, nfcV, isoDep, mifareClassic, mifareUltralight }

/// NDEF Type-Name-Format, as defined by the NFC Forum. Ordinals match the on-tag values
/// 0x00..0x06.
enum TypeNameFormatPigeon { empty, wellKnown, media, absoluteUri, external, unknown, unchanged }

enum MifareClassicTypePigeon { classic, plus, pro, unknown }

enum MifareUltralightTypePigeon { ultralight, ultralightC, unknown }

enum NfcBarcodeTypePigeon { kovio, unknown }

enum MiFareFamilyPigeon { unknown, ultralight, plus, desfire }

/// `NFCNDEFStatus`. iOS only.
enum NdefStatusPigeon { notSupported, readOnly, readWrite }

enum Iso15693RequestFlagPigeon { address, dualSubCarriers, highDataRate, option, protocolExtension, select }

enum FeliCaPollingRequestCodePigeon { noRequest, systemCode, communicationPerformance }

enum FeliCaPollingTimeSlotPigeon { max1, max2, max4, max8, max16 }

/// `NFCVASCommandConfiguration.Mode`. iOS only.
enum VasModePigeon { normal, urlOnly }

/// `NFCVASReaderSessionVASResponse.ErrorCode`. iOS only.
enum VasResponseErrorCodePigeon {
  success,
  userIntervention,
  dataNotActivated,
  dataNotFound,
  incorrectData,
  unsupportedApplicationVersion,
  wrongLcField,
  wrongParameters,
}

/// Which platform raised an error, so the two code enums below can be read unambiguously.
enum ErrorSourcePigeon { android, ios }

/// Which kind of session an event belongs to.
///
/// iOS runs tag reading and Value Added Services as two separate session objects with two
/// separate delegates, and the plugin tears them down independently. Without this on the
/// wire, Dart cannot tell whose error or whose "sheet is up" it just received, and one
/// family's teardown silently unregisters the other's callbacks.
enum SessionKindPigeon { tag, vas }

/// Typed Android failures.
///
/// Every Android throwable the plugin can see maps to one of these. 2.x reported four bare
/// strings, which left an app unable to tell a tag that moved out of range from a tag that
/// refused the command -- the two call for opposite responses.
enum AndroidErrorCodePigeon {
  tagLost,
  io,
  security,
  unsupportedTech,
  notConnected,
  adapterDisabled,
  invalidParameter,
  unknown,
}

/// `NFCReaderError.Code`. iOS only.
enum ReaderErrorCodePigeon {
  firstNdefTagRead,
  sessionTerminatedUnexpectedly,
  sessionTimeout,
  systemIsBusy,
  userCanceled,
  tagNotWritable,
  tagSizeTooSmall,
  tagUpdateFailure,
  zeroLengthMessage,
  retryExceeded,
  tagConnectionLost,
  tagNotConnected,
  tagResponseError,
  sessionInvalidated,
  packetTooLong,
  invalidParameters,
  unsupportedFeature,
  invalidParameter,
  invalidParameterLength,
  parameterOutOfBound,
  radioDisabled,
  securityViolation,
  ineligible,
  accessNotAccepted,
  unknown,
}

// ---------------------------------------------------------------------------------------
// NDEF
// ---------------------------------------------------------------------------------------

class NdefRecordPigeon {
  late TypeNameFormatPigeon typeNameFormat;
  late Uint8List type;
  late Uint8List identifier;
  late Uint8List payload;
}

class NdefMessagePigeon {
  late List<NdefRecordPigeon> records;
}

// ---------------------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------------------

/// Everything `startSession` needs, in one object.
///
/// Pigeon takes positional parameters only, and a seven-argument call is unreadable at both
/// ends.
class SessionConfigPigeon {
  late List<PollingOptionPigeon> pollingOptions;

  /// iOS. Text on the system reader sheet.
  String? alertMessage;

  /// iOS. When false the session keeps polling after each tag, so one session can read many.
  late bool invalidateAfterFirstRead;

  /// Android. `FLAG_READER_NO_PLATFORM_SOUNDS`.
  late bool noPlatformSounds;

  /// Both. Skips the NDEF probe at discovery.
  late bool skipNdefCheck;

  /// Android. `FLAG_READER_NFC_BARCODE`; without it barcode tags are never discovered.
  late bool discoverNfcBarcode;

  /// Android. `EXTRA_READER_PRESENCE_CHECK_DELAY`, in milliseconds. 2.x hardcoded 250.
  late int presenceCheckDelayMillis;
}

// ---------------------------------------------------------------------------------------
// Adapter and card-emulation state
// ---------------------------------------------------------------------------------------

/// One frame of the reader's polling loop, delivered while observe mode is on.
///
/// Android only, API 35 and above.
class PollingFramePigeon {
  late PollingFrameTypePigeon type;

  /// The frame bytes. Empty for the field-on and field-off frames, which carry no data.
  late Uint8List data;

  /// The controller's own measure of field strength, in vendor-defined units. Zero on a
  /// device whose stack does not report it.
  late int vendorSpecificGain;

  /// `SystemClock.uptimeMillis` when the controller saw the frame, wrapping at 2^32.
  late int timestamp;

  /// Whether this frame matched a filter registered with `autoTransact`, which takes the
  /// device out of observe mode for the exchange that follows.
  late bool triggeredAutoTransact;
}

/// One antenna's position, in millimetres from the top-left of the *back* of the device
/// held face up in its natural orientation.
class AvailableNfcAntennaPigeon {
  late int locationX;
  late int locationY;
}

/// `NfcAdapter.getNfcAntennaInfo`. Android only, API 34 and above.
class NfcAntennaInfoPigeon {
  late int deviceWidth;
  late int deviceHeight;

  /// True for a foldable, where the coordinates describe the device unfolded.
  late bool deviceFoldable;

  /// Empty on a device that reports NFC but publishes no antenna geometry.
  late List<AvailableNfcAntennaPigeon> availableNfcAntennas;
}

/// One `CardEmulation.NfcEventCallback` notification.
///
/// Flat rather than a union: which optional fields are set follows from [kind], and Pigeon
/// has no sealed-class support to express that on both sides.
class NfcEventPigeon {
  late NfcEventKindPigeon kind;

  /// Set for [NfcEventKindPigeon.preferredServiceChanged],
  /// [NfcEventKindPigeon.observeModeStateChanged] and
  /// [NfcEventKindPigeon.remoteFieldChanged].
  bool? enabled;

  /// Set for [NfcEventKindPigeon.aidConflictOccurred] and
  /// [NfcEventKindPigeon.aidNotRouted].
  String? aid;

  /// Set for [NfcEventKindPigeon.nfcStateChanged].
  AdapterStatePigeon? adapterState;

  /// Set for [NfcEventKindPigeon.internalError].
  NfcInternalErrorPigeon? internalError;
}

/// What the platform can tell an app about whether tag *intents* will reach it.
///
/// Android 16 gave the user a per-app "launch via NFC" switch, and Android 17 made the
/// receiving activity's `android:permission` load-bearing. Both fail silently -- the tap
/// simply does nothing -- so this exists to turn that into something an app can report.
class TagIntentSetupPigeon {
  /// True on API 37 and above, where an activity with an NFC intent filter is only
  /// dispatched to when it declares `android.permission.DISPATCH_NFC_MESSAGE`.
  late bool dispatchPermissionRequired;

  /// Activities in this package that declare an NFC intent filter without that permission.
  /// Always empty when [dispatchPermissionRequired] is false.
  late List<String> unguardedActivities;

  /// Whether the user has this app on the tag-scan allowlist. True below API 36, which has
  /// no allowlist.
  late bool tagIntentAllowed;

  /// Whether the device implements the allowlist at all.
  late bool tagIntentPreferenceSupported;
}

// ---------------------------------------------------------------------------------------
// Tag technologies
// ---------------------------------------------------------------------------------------

class NfcAPigeon {
  /// Null when the stack did not report the poll bytes: AOSP only populates the tech extras
  /// once it has enough of them, and a target that answered a short SENS_RES has none.
  Uint8List? atqa;
  late int sak;
  late int maxTransceiveLength;
  late int timeout;
}

class NfcBPigeon {
  /// Null when the tag reported no ATQB parameters. AOSP fills these two only when the poll
  /// bytes reach seven, and a B-prime target -- Innovatron, legacy Calypso transit -- answers
  /// no SENSB_RES at all while still being reported as ISO 14443-3B.
  Uint8List? applicationData;
  Uint8List? protocolInfo;
  late int maxTransceiveLength;
}

class NfcFPigeon {
  /// Null when the stack did not report the poll bytes, as for [NfcAPigeon.atqa].
  Uint8List? manufacturer;
  Uint8List? systemCode;
  late int maxTransceiveLength;
  late int timeout;
}

class NfcVPigeon {
  late int dsfId;
  late int responseFlags;
  late int maxTransceiveLength;
}

class IsoDepPigeon {
  Uint8List? hiLayerResponse;
  Uint8List? historicalBytes;
  late bool isExtendedLengthApduSupported;
  late int maxTransceiveLength;
  late int timeout;
}

class MifareClassicPigeon {
  late MifareClassicTypePigeon type;
  late int blockCount;
  late int sectorCount;
  late int size;
  late int maxTransceiveLength;
  late int timeout;
}

class MifareUltralightPigeon {
  late MifareUltralightTypePigeon type;
  late int maxTransceiveLength;
  late int timeout;
}

class NfcBarcodePigeon {
  late NfcBarcodeTypePigeon type;
  Uint8List? barcode;
}

class NdefAndroidPigeon {
  /// `org.nfcforum.ndef.type1` .. `type4`, or `android.ndef.unknown`.
  late String type;
  late int maxSize;
  late bool isWritable;
  late bool canMakeReadOnly;

  /// Captured at discovery. May already be stale; call `read()` for the current message.
  NdefMessagePigeon? cachedMessage;
}

class NdefIosPigeon {
  late NdefStatusPigeon status;
  late int capacity;
  NdefMessagePigeon? cachedMessage;
}

class FeliCaPigeon {
  late Uint8List currentSystemCode;
  late Uint8List currentIDm;
}

class Iso7816Pigeon {
  late String initialSelectedAID;
  Uint8List? historicalBytes;
  Uint8List? applicationData;
  late bool proprietaryApplicationDataCoding;
}

class Iso15693Pigeon {
  late int icManufacturerCode;
  late Uint8List icSerialNumber;
}

class MiFarePigeon {
  late MiFareFamilyPigeon family;
  Uint8List? historicalBytes;
}

/// One discovered tag.
///
/// Every technology field is null when the tag does not support it, which is what the
/// `X.from(tag)` constructors test. [id] is hoisted here because on Android every
/// `android.nfc.tech` class reports the same `Tag.getId()`, and on iOS every tag protocol
/// carries one identifier; 2.x repeated it on twelve of its thirteen technology classes.
class TagPigeon {
  late String handle;

  /// The tag UID. Null for the rare tag that reports none.
  Uint8List? id;

  /// `Tag.getTechList()`, short names. Android only.
  List<String>? techList;

  NdefAndroidPigeon? ndefAndroid;
  bool? ndefFormatable;
  NfcAPigeon? nfcA;
  NfcBPigeon? nfcB;
  NfcFPigeon? nfcF;
  NfcVPigeon? nfcV;
  IsoDepPigeon? isoDep;
  MifareClassicPigeon? mifareClassic;
  MifareUltralightPigeon? mifareUltralight;
  NfcBarcodePigeon? nfcBarcode;

  NdefIosPigeon? ndefIos;
  FeliCaPigeon? felica;
  Iso7816Pigeon? iso7816;
  Iso15693Pigeon? iso15693;
  MiFarePigeon? mifare;
}

// ---------------------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------------------

class Iso7816ResponseApduPigeon {
  late Uint8List payload;
  late int statusWord1;
  late int statusWord2;
}

class FeliCaPollingResponsePigeon {
  late Uint8List manufacturerParameter;
  late Uint8List requestData;
}

class FeliCaStatusFlagPigeon {
  late int statusFlag1;
  late int statusFlag2;
}

class FeliCaReadWithoutEncryptionResponsePigeon {
  late int statusFlag1;
  late int statusFlag2;
  late List<Uint8List> blockData;
}

class FeliCaRequestServiceV2ResponsePigeon {
  late int statusFlag1;
  late int statusFlag2;
  late int encryptionIdentifier;
  List<Uint8List>? nodeKeyVersionListAes;
  List<Uint8List>? nodeKeyVersionListDes;
}

class FeliCaRequestSpecificationVersionResponsePigeon {
  late int statusFlag1;
  late int statusFlag2;
  Uint8List? basicVersion;
  Uint8List? optionVersion;
}

class Iso15693SystemInfoPigeon {
  late int applicationFamilyIdentifier;
  late int blockSize;
  late int dataStorageFormatIdentifier;
  late int icReference;
  late int totalBlocks;
}

class QueryNdefStatusResponsePigeon {
  late NdefStatusPigeon status;
  late int capacity;
}

class VasCommandConfigurationPigeon {
  late VasModePigeon mode;
  late String passTypeIdentifier;
  String? url;
}

class VasResponsePigeon {
  late VasResponseErrorCodePigeon status;
  late Uint8List vasData;
  late Uint8List mobileToken;
}

/// A session failure.
///
/// Exactly one of [iosCode] / [androidCode] is set, chosen by [source]. 2.x could only
/// report iOS failures: the Kotlin side never invoked the error callback at all.
class NfcErrorPigeon {
  late ErrorSourcePigeon source;
  ReaderErrorCodePigeon? iosCode;
  AndroidErrorCodePigeon? androidCode;
  late String message;

  /// Whether the session is over, or merely had one thing go wrong inside it.
  ///
  /// Every CoreNFC invalidation ends the session. Android has both kinds: a tag that cannot
  /// be read is a failure of that tag, and reader mode keeps polling. Without this a caller
  /// cannot tell "start a new session" from "keep waiting", and restarting on a live session
  /// is refused -- which would leave an app that follows the obvious retry pattern
  /// permanently deaf.
  late bool sessionEnded;
}

// ---------------------------------------------------------------------------------------
// Host APIs (Dart -> platform)
// ---------------------------------------------------------------------------------------

/// Implemented by both platforms.
@HostApi()
abstract class NfcHostApi {
  AvailabilityPigeon checkAvailability();

  @async
  void startSession(SessionConfigPigeon config);

  @async
  void stopSession(String? alertMessage, String? errorMessage);

  void disposeTag(String handle);

  @async
  NdefMessagePigeon? ndefRead(String handle);

  @async
  void ndefWrite(String handle, NdefMessagePigeon message);

  @async
  void ndefWriteLock(String handle);
}

/// Implemented on Android only. The generated Swift interface is never registered.
@HostApi()
abstract class NfcAndroidHostApi {
  bool isEnabled();
  bool isSecureNfcSupported();
  bool isSecureNfcEnabled();

  /// The raw escape hatch: full control over `NfcAdapter.enableReaderMode` flags, for
  /// combinations the cross-platform `startSession` does not express.
  @async
  void enableReaderMode(List<ReaderFlagPigeon> flags, int presenceCheckDelayMillis);

  @async
  void disableReaderMode();

  /// Claims tag delivery while the activity is in the foreground, so a tag cannot be
  /// hijacked by another app's intent filter.
  void enableForegroundDispatch();
  void disableForegroundDispatch();

  /// The tag whose intent launched the app, if any. Consumed by the first call.
  TagPigeon? takeInitialTag();

  /// Restricts what the controller polls for and answers as, for as long as the activity is
  /// in the foreground. API 35 and above.
  @async
  void setDiscoveryTechnology(List<PollTechPigeon> poll, List<ListenTechPigeon> listen);

  @async
  void resetDiscoveryTechnology();

  /// Where the antennas are, so an app can say where to hold the tag. API 34 and above;
  /// null below, and on a device that publishes no geometry.
  NfcAntennaInfoPigeon? getAntennaInfo();

  /// Whether the device implements the Android 16 tag-scan allowlist.
  bool isTagIntentAppPreferenceSupported();

  /// Whether the user has allowed this app to be launched by a tag. True below API 36.
  bool isTagIntentAllowed();

  /// Opens the system screen where the user changes that. False when there is no activity
  /// to start it from, or the device has no such screen.
  bool openTagIntentPreferenceSettings();

  /// Everything that decides whether a tag *intent* can reach this app, in one call.
  TagIntentSetupPigeon checkTagIntentSetup();

  @async
  Uint8List transceive(String handle, AndroidTechPigeon tech, Uint8List data);

  @async
  int getMaxTransceiveLength(String handle, AndroidTechPigeon tech);

  @async
  int getTimeout(String handle, AndroidTechPigeon tech);

  @async
  void setTimeout(String handle, AndroidTechPigeon tech, int timeout);

  @async
  bool mifareClassicAuthenticateSector(String handle, int sectorIndex, Uint8List key, bool useKeyA);

  @async
  Uint8List mifareClassicReadBlock(String handle, int blockIndex);

  @async
  void mifareClassicWriteBlock(String handle, int blockIndex, Uint8List data);

  @async
  void mifareClassicIncrement(String handle, int blockIndex, int value);

  @async
  void mifareClassicDecrement(String handle, int blockIndex, int value);

  @async
  void mifareClassicRestore(String handle, int blockIndex);

  @async
  void mifareClassicTransfer(String handle, int blockIndex);

  /// Sector geometry is not uniform -- a 4K card has 32 sectors of 4 blocks then 8 of 16 --
  /// so this cannot be computed from blockCount and sectorCount. Reads a static description
  /// rather than talking to the tag, so it needs no connection.
  int mifareClassicBlockToSector(String handle, int blockIndex);
  int mifareClassicSectorToBlock(String handle, int sectorIndex);
  int mifareClassicBlockCountInSector(String handle, int sectorIndex);

  @async
  Uint8List mifareUltralightReadPages(String handle, int pageOffset);

  @async
  void mifareUltralightWritePage(String handle, int pageOffset, Uint8List data);

  @async
  void ndefFormat(String handle, NdefMessagePigeon firstMessage, bool readOnly);

  // Host Card Emulation.

  bool hceIsSupported();

  /// Registers AIDs against the plugin's `HostApduService` at run time, so an app does not
  /// have to ship a static AID list in its manifest.
  @async
  bool hceRegisterAids(List<String> aids);

  @async
  bool hceUnregisterAids();

  /// Answers the APDU most recently delivered to `onApduReceived`.
  void hceRespond(Uint8List response);

  /// Makes this app the preferred handler while it is in the foreground, so a tap reaches
  /// it rather than the user's default wallet.
  void hceSetPreferredService(bool preferred);

  // Observe mode and polling loop filters. API 35 and above.

  bool hceIsObserveModeSupported();
  bool hceIsObserveModeEnabled();

  /// Stops the device answering readers and starts delivering their polling frames instead.
  /// Only the preferred service may change this, so pair it with [hceSetPreferredService].
  @async
  bool hceSetObserveModeEnabled(bool enabled);

  /// Whether the service should come up in observe mode whenever it becomes preferred,
  /// rather than needing [hceSetObserveModeEnabled] each time.
  @async
  bool hceSetDefaultToObserveMode(bool shouldDefault);

  /// Delivers polling frames whose bytes are exactly [filter], as uppercase hex.
  ///
  /// With [autoTransact] the platform leaves observe mode by itself on a match, so the
  /// exchange that follows is answered rather than merely watched.
  @async
  bool hceRegisterPollingLoopFilter(String filter, bool autoTransact);

  /// As [hceRegisterPollingLoopFilter], but [pattern] is a regular expression matched
  /// against the frame's hex.
  @async
  bool hceRegisterPollingLoopPatternFilter(String pattern, bool autoTransact);

  @async
  bool hceRemovePollingLoopFilter(String filter);

  @async
  bool hceRemovePollingLoopPatternFilter(String pattern);

  // Card-emulation events. API 36 and above.

  /// Starts delivering `onNfcEvent`. False on a device below API 36.
  @async
  bool enableNfcEvents();

  @async
  void disableNfcEvents();
}

/// Implemented on iOS only. The generated Kotlin interface is never registered.
@HostApi()
abstract class NfcIosHostApi {
  bool tagSessionReadingAvailable();

  @async
  void tagSessionSetAlertMessage(String alertMessage);

  /// Drops the current tag and polls again, without tearing down the reader sheet.
  @async
  void tagSessionRestartPolling();

  bool vasSessionReadingAvailable();

  @async
  void vasSessionBegin(List<VasCommandConfigurationPigeon> configurations, String? alertMessage);

  @async
  void vasSessionInvalidate(String? alertMessage, String? errorMessage);

  @async
  void vasSessionSetAlertMessage(String alertMessage);

  /// The live status, as opposed to the copy captured at discovery.
  @async
  QueryNdefStatusResponsePigeon ndefQueryStatus(String handle);

  /// An NDEF message delivered by iOS background tag reading. Consumed by the first call.
  NdefMessagePigeon? takeInitialNdefMessage();

  @async
  FeliCaPollingResponsePigeon felicaPolling(
    String handle,
    Uint8List systemCode,
    FeliCaPollingRequestCodePigeon requestCode,
    FeliCaPollingTimeSlotPigeon timeSlot,
  );

  @async
  int felicaRequestResponse(String handle);

  @async
  List<Uint8List> felicaRequestSystemCode(String handle);

  @async
  List<Uint8List> felicaRequestService(String handle, List<Uint8List> nodeCodeList);

  @async
  FeliCaRequestServiceV2ResponsePigeon felicaRequestServiceV2(String handle, List<Uint8List> nodeCodeList);

  @async
  FeliCaReadWithoutEncryptionResponsePigeon felicaReadWithoutEncryption(
    String handle,
    List<Uint8List> serviceCodeList,
    List<Uint8List> blockList,
  );

  @async
  FeliCaStatusFlagPigeon felicaWriteWithoutEncryption(
    String handle,
    List<Uint8List> serviceCodeList,
    List<Uint8List> blockList,
    List<Uint8List> blockData,
  );

  @async
  FeliCaRequestSpecificationVersionResponsePigeon felicaRequestSpecificationVersion(String handle);

  @async
  FeliCaStatusFlagPigeon felicaResetMode(String handle);

  @async
  Uint8List felicaSendCommand(String handle, Uint8List commandPacket);

  @async
  Uint8List iso15693ReadSingleBlock(String handle, List<Iso15693RequestFlagPigeon> flags, int blockNumber);

  @async
  void iso15693WriteSingleBlock(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    Uint8List dataBlock,
  );

  @async
  void iso15693LockBlock(String handle, List<Iso15693RequestFlagPigeon> flags, int blockNumber);

  @async
  List<Uint8List> iso15693ReadMultipleBlocks(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
  );

  @async
  void iso15693WriteMultipleBlocks(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
    List<Uint8List> dataBlocks,
  );

  @async
  List<int> iso15693GetMultipleBlockSecurityStatus(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
  );

  @async
  void iso15693WriteAfi(String handle, List<Iso15693RequestFlagPigeon> flags, int afi);

  @async
  void iso15693LockAfi(String handle, List<Iso15693RequestFlagPigeon> flags);

  @async
  void iso15693WriteDsfId(String handle, List<Iso15693RequestFlagPigeon> flags, int dsfId);

  @async
  void iso15693LockDsfId(String handle, List<Iso15693RequestFlagPigeon> flags);

  @async
  void iso15693ResetToReady(String handle, List<Iso15693RequestFlagPigeon> flags);

  @async
  void iso15693Select(String handle, List<Iso15693RequestFlagPigeon> flags);

  @async
  void iso15693StayQuiet(String handle);

  @async
  Uint8List iso15693ExtendedReadSingleBlock(String handle, List<Iso15693RequestFlagPigeon> flags, int blockNumber);

  @async
  void iso15693ExtendedWriteSingleBlock(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    Uint8List dataBlock,
  );

  @async
  void iso15693ExtendedLockBlock(String handle, List<Iso15693RequestFlagPigeon> flags, int blockNumber);

  @async
  List<Uint8List> iso15693ExtendedReadMultipleBlocks(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
  );

  @async
  Iso15693SystemInfoPigeon iso15693GetSystemInfo(String handle, List<Iso15693RequestFlagPigeon> flags);

  @async
  Uint8List iso15693CustomCommand(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int customCommandCode,
    Uint8List customRequestParameters,
  );

  @async
  Iso7816ResponseApduPigeon iso7816SendCommand(
    String handle,
    int instructionClass,
    int instructionCode,
    int p1Parameter,
    int p2Parameter,
    Uint8List data,
    int expectedResponseLength,
  );

  @async
  Iso7816ResponseApduPigeon iso7816SendCommandRaw(String handle, Uint8List data);

  @async
  Uint8List mifareSendCommand(String handle, Uint8List commandPacket);

  @async
  Iso7816ResponseApduPigeon mifareSendIso7816Command(
    String handle,
    int instructionClass,
    int instructionCode,
    int p1Parameter,
    int p2Parameter,
    Uint8List data,
    int expectedResponseLength,
  );

  @async
  Iso7816ResponseApduPigeon mifareSendIso7816CommandRaw(String handle, Uint8List data);
}

// ---------------------------------------------------------------------------------------
// Flutter API (platform -> Dart)
// ---------------------------------------------------------------------------------------

@FlutterApi()
abstract class NfcFlutterApi {
  /// A tag came into range during a reader session.
  ///
  /// Async on purpose: the platform must not act on the tag again until the app's callback
  /// has finished with it. On iOS that is what lets a continuous session call
  /// `restartPolling` at the right moment rather than immediately, which would drop the tag
  /// out from under an app that is still reading it.
  @async
  void onDiscovered(TagPigeon tag);

  /// The session ended for a reason the app did not ask for. Raised by both platforms.
  void onError(SessionKindPigeon kind, NfcErrorPigeon error);

  /// Android only; there is no NFC toggle to watch on iOS.
  void onAdapterStateChanged(AdapterStatePigeon state);

  /// iOS only. The system reader sheet is up and polling.
  void onSessionBecameActive(SessionKindPigeon kind);

  /// iOS only. Wallet passes matched by a VAS session.
  void onVasResponse(List<VasResponsePigeon> responses);

  /// Android only. A reader sent an APDU to the emulated card.
  void onApduReceived(Uint8List apdu);

  /// Android only. `HostApduService.onDeactivated` reason.
  void onHceDeactivated(int reason);

  /// Android only. Frames from a reader's polling loop, while observe mode is on.
  ///
  /// Batched by the platform: one call can carry a whole loop.
  void onPollingFrames(List<PollingFramePigeon> frames);

  /// Android only. A card-emulation event, once `enableNfcEvents` has been called.
  void onNfcEvent(NfcEventPigeon event);

  /// Android only. A tag delivered by an intent filter rather than a reader session.
  @async
  void onTagFromIntent(TagPigeon tag);

  /// iOS only. An NDEF message from background tag reading.
  void onNdefFromBackground(NdefMessagePigeon message);
}
