import 'dart:typed_data';

import '../android/tags.dart';
import '../common.dart';
import '../ios/tags.dart';
import '../mapping.dart';
import '../ndef/message.dart';
import '../pigeon.g.dart';

// The numeric defaults below are plausible rather than measured, and no test should assert
// on them. What they are for is being non-zero: a zero maximum transceive length turns a
// caller's chunking loop into an endless one, and a zero capacity makes every write look too
// large for the tag -- both of which read as a bug in the code under test rather than as a
// value nobody bothered to set.
const int _maxTransceiveLength = 253;
const Duration _timeout = Duration(milliseconds: 618);
const int _ndefCapacity = 492;

/// A tag that answers to the technologies given, and to nothing else.
///
/// The tag is inert -- its handle addresses nothing, because nothing is in the field -- so
/// what this covers is the code that inspects a tag and decides what it is. Put the fake host
/// APIs in place as well when the code under test goes on to talk to the tag.
///
/// ```dart
/// final tag = fakeNfcTag(
///   id: Uint8List.fromList([0x04, 0xA2, 0x1B]),
///   techs: [FakeTech.nfcA(), FakeTech.mifareClassic()],
/// );
///
/// expect(MifareClassic.from(tag)?.sectorCount, 16);
/// expect(FeliCa.from(tag), isNull);
/// ```
///
/// [techList] is derived from the Android technologies in [techs] by default, because a tag
/// carrying a technology the platform left off its list is a tag no device would deliver, and
/// code that branches on the list would quietly take the wrong branch. Pass it to say
/// something the derivation cannot. An iOS tag has no such list at all, which is what a tag
/// built from CoreNFC protocols alone reports.
///
/// [handle] is arbitrary: the fake host APIs ignore it, and a real one refuses it.
NfcTag fakeNfcTag({
  String handle = 'fake-tag',
  Uint8List? id,
  List<FakeTech> techs = const [],
  List<String>? techList,
  int? otherTagCount,
}) {
  final data = TagPigeon(handle: handle, id: id, otherTagCount: otherTagCount);
  for (final tech in techs) {
    tech._apply(data);
  }

  final names = techs.map((tech) => tech._techName).whereType<String>().toList();
  data.techList = techList ?? (names.isEmpty ? null : names);
  return NfcTag(data);
}

/// One technology on a tag built by [fakeNfcTag], as the platform would report it.
///
/// Every factory takes this package's own value types and plain Dart values. That is
/// deliberate: the generated wire classes a tag is really made of are `@internal` and their
/// shape changes without a major version, so a test written against them would break on a
/// patch release that only touched the schema.
///
/// The Android technologies and the CoreNFC protocols live side by side here, and nothing
/// stops a tag carrying both. No device delivers such a tag, but a test that wants one
/// object to drive both platforms' branches through is a reasonable thing to want.
class FakeTech {
  FakeTech._(this._techName, this._apply);

  /// `android.nfc.tech.NfcA`. ISO 14443-3A.
  factory FakeTech.nfcA({
    Uint8List? atqa,
    int sak = 0x08,
    int maxTransceiveLength = _maxTransceiveLength,
    Duration timeout = _timeout,
  }) => FakeTech._(
    'NfcA',
    (data) => data.nfcA = NfcAPigeon(
      atqa: atqa,
      sak: sak,
      maxTransceiveLength: maxTransceiveLength,
      timeout: timeout.inMilliseconds,
    ),
  );

  /// `android.nfc.tech.NfcB`. ISO 14443-3B.
  factory FakeTech.nfcB({
    Uint8List? applicationData,
    Uint8List? protocolInfo,
    int maxTransceiveLength = _maxTransceiveLength,
  }) => FakeTech._(
    'NfcB',
    (data) => data.nfcB = NfcBPigeon(
      applicationData: applicationData,
      protocolInfo: protocolInfo,
      maxTransceiveLength: maxTransceiveLength,
    ),
  );

  /// `android.nfc.tech.NfcF`. JIS 6319-4, the FeliCa transport.
  factory FakeTech.nfcF({
    Uint8List? manufacturer,
    Uint8List? systemCode,
    int maxTransceiveLength = _maxTransceiveLength,
    Duration timeout = _timeout,
  }) => FakeTech._(
    'NfcF',
    (data) => data.nfcF = NfcFPigeon(
      manufacturer: manufacturer,
      systemCode: systemCode,
      maxTransceiveLength: maxTransceiveLength,
      timeout: timeout.inMilliseconds,
    ),
  );

  /// `android.nfc.tech.NfcV`. ISO 15693, which iOS reaches through [FakeTech.iso15693].
  factory FakeTech.nfcV({
    int dsfId = 0,
    int responseFlags = 0,
    int maxTransceiveLength = _maxTransceiveLength,
  }) => FakeTech._(
    'NfcV',
    (data) => data.nfcV = NfcVPigeon(
      dsfId: dsfId,
      responseFlags: responseFlags,
      maxTransceiveLength: maxTransceiveLength,
    ),
  );

  /// `android.nfc.tech.IsoDep`. ISO 14443-4, which is what an APDU rides on.
  factory FakeTech.isoDep({
    Uint8List? hiLayerResponse,
    Uint8List? historicalBytes,
    bool isExtendedLengthApduSupported = false,
    int maxTransceiveLength = _maxTransceiveLength,
    Duration timeout = _timeout,
  }) => FakeTech._(
    'IsoDep',
    (data) => data.isoDep = IsoDepPigeon(
      hiLayerResponse: hiLayerResponse,
      historicalBytes: historicalBytes,
      isExtendedLengthApduSupported: isExtendedLengthApduSupported,
      maxTransceiveLength: maxTransceiveLength,
      timeout: timeout.inMilliseconds,
    ),
  );

  /// `android.nfc.tech.MifareClassic`.
  ///
  /// The geometry defaults to a 1K card -- 64 blocks in 16 sectors of four -- and so does
  /// `FakeNfcAndroidHostApi`'s answer to `blockToSector` and its neighbours, so the static
  /// description and the calls that read it agree unless a test changes one of them.
  factory FakeTech.mifareClassic({
    MifareClassicType type = MifareClassicType.classic,
    int blockCount = 64,
    int sectorCount = 16,
    int size = MifareClassic.size1K,
    int maxTransceiveLength = _maxTransceiveLength,
    Duration timeout = _timeout,
  }) => FakeTech._(
    'MifareClassic',
    (data) => data.mifareClassic = MifareClassicPigeon(
      type: _mifareClassicTypeToWire(type),
      blockCount: blockCount,
      sectorCount: sectorCount,
      size: size,
      maxTransceiveLength: maxTransceiveLength,
      timeout: timeout.inMilliseconds,
    ),
  );

  /// `android.nfc.tech.MifareUltralight`.
  factory FakeTech.mifareUltralight({
    MifareUltralightType type = MifareUltralightType.ultralight,
    int maxTransceiveLength = _maxTransceiveLength,
    Duration timeout = _timeout,
  }) => FakeTech._(
    'MifareUltralight',
    (data) => data.mifareUltralight = MifareUltralightPigeon(
      type: _mifareUltralightTypeToWire(type),
      maxTransceiveLength: maxTransceiveLength,
      timeout: timeout.inMilliseconds,
    ),
  );

  /// `android.nfc.tech.NfcBarcode`. Only a session that asked for barcode tags sees one.
  factory FakeTech.nfcBarcode({NfcBarcodeType type = NfcBarcodeType.kovio, Uint8List? barcode}) => FakeTech._(
    'NfcBarcode',
    (data) => data.nfcBarcode = NfcBarcodePigeon(type: _nfcBarcodeTypeToWire(type), barcode: barcode),
  );

  /// `android.nfc.tech.Ndef`, which carries both `Ndef` and `NdefAndroid`.
  ///
  /// [cachedMessage] is the way to hand a test a message without overriding a host API call:
  /// it arrives as `Ndef.from(tag)?.cachedMessage`, the same snapshot a real discovery takes.
  factory FakeTech.ndefAndroid({
    String type = 'org.nfcforum.ndef.type2',
    int maxSize = _ndefCapacity,
    bool isWritable = true,
    bool canMakeReadOnly = true,
    NdefMessage? cachedMessage,
  }) => FakeTech._(
    'Ndef',
    (data) => data.ndefAndroid = NdefAndroidPigeon(
      type: type,
      maxSize: maxSize,
      isWritable: isWritable,
      canMakeReadOnly: canMakeReadOnly,
      cachedMessage: cachedMessage == null ? null : ndefMessageToWire(cachedMessage),
    ),
  );

  /// `android.nfc.tech.NdefFormatable`. A tag that could hold NDEF but does not yet.
  factory FakeTech.ndefFormatable() => FakeTech._('NdefFormatable', (data) => data.ndefFormatable = true);

  /// `NFCNDEFTag`, which carries both `Ndef` and `NdefIos`. iOS reports no technology name.
  ///
  /// [cachedMessage] arrives as `Ndef.from(tag)?.cachedMessage`, as on Android.
  factory FakeTech.ndefIos({
    NdefStatus status = NdefStatus.readWrite,
    int capacity = _ndefCapacity,
    NdefMessage? cachedMessage,
  }) => FakeTech._(
    null,
    (data) => data.ndefIos = NdefIosPigeon(
      status: _ndefStatusToWire(status),
      capacity: capacity,
      cachedMessage: cachedMessage == null ? null : ndefMessageToWire(cachedMessage),
    ),
  );

  /// `NFCFeliCaTag`. iOS only.
  ///
  /// Both values default to zeroes of the length the real thing has, since a wrong length is
  /// the failure a test of FeliCa framing would want to catch and an invented value is not.
  factory FakeTech.felica({Uint8List? currentSystemCode, Uint8List? currentIDm}) => FakeTech._(
    null,
    (data) => data.felica = FeliCaPigeon(
      currentSystemCode: currentSystemCode ?? Uint8List(2),
      currentIDm: currentIDm ?? Uint8List(8),
    ),
  );

  /// `NFCISO7816Tag`. iOS only; Android reaches the same cards through [FakeTech.isoDep].
  factory FakeTech.iso7816({
    String initialSelectedAID = '',
    Uint8List? historicalBytes,
    Uint8List? applicationData,
    bool proprietaryApplicationDataCoding = false,
  }) => FakeTech._(
    null,
    (data) => data.iso7816 = Iso7816Pigeon(
      initialSelectedAID: initialSelectedAID,
      historicalBytes: historicalBytes,
      applicationData: applicationData,
      proprietaryApplicationDataCoding: proprietaryApplicationDataCoding,
    ),
  );

  /// `NFCISO15693Tag`. iOS only; Android reaches the same tags through [FakeTech.nfcV].
  factory FakeTech.iso15693({int icManufacturerCode = 0, Uint8List? icSerialNumber}) => FakeTech._(
    null,
    (data) => data.iso15693 = Iso15693Pigeon(
      icManufacturerCode: icManufacturerCode,
      icSerialNumber: icSerialNumber ?? Uint8List(6),
    ),
  );

  /// `NFCMiFareTag`. iOS only.
  factory FakeTech.mifare({MiFareFamily family = MiFareFamily.ultralight, Uint8List? historicalBytes}) => FakeTech._(
    null,
    (data) => data.mifare = MiFarePigeon(family: _miFareFamilyToWire(family), historicalBytes: historicalBytes),
  );

  /// The `android.nfc.tech` short name this technology appears in a tech list as, or null for
  /// a CoreNFC protocol, which iOS names nothing.
  final String? _techName;

  final void Function(TagPigeon data) _apply;
}

// The public-to-wire direction of the enums the factories above accept, as exhaustive
// switches so that a value added to either side fails the build rather than a test.
// lib/src/mapping.dart explains the reasoning; these live here because this is the only file
// that maps this direction.

MifareClassicTypePigeon _mifareClassicTypeToWire(MifareClassicType value) => switch (value) {
  MifareClassicType.classic => MifareClassicTypePigeon.classic,
  MifareClassicType.plus => MifareClassicTypePigeon.plus,
  MifareClassicType.pro => MifareClassicTypePigeon.pro,
  MifareClassicType.unknown => MifareClassicTypePigeon.unknown,
};

MifareUltralightTypePigeon _mifareUltralightTypeToWire(MifareUltralightType value) => switch (value) {
  MifareUltralightType.ultralight => MifareUltralightTypePigeon.ultralight,
  MifareUltralightType.ultralightC => MifareUltralightTypePigeon.ultralightC,
  MifareUltralightType.unknown => MifareUltralightTypePigeon.unknown,
};

NfcBarcodeTypePigeon _nfcBarcodeTypeToWire(NfcBarcodeType value) => switch (value) {
  NfcBarcodeType.kovio => NfcBarcodeTypePigeon.kovio,
  NfcBarcodeType.unknown => NfcBarcodeTypePigeon.unknown,
};

NdefStatusPigeon _ndefStatusToWire(NdefStatus value) => switch (value) {
  NdefStatus.notSupported => NdefStatusPigeon.notSupported,
  NdefStatus.readOnly => NdefStatusPigeon.readOnly,
  NdefStatus.readWrite => NdefStatusPigeon.readWrite,
};

MiFareFamilyPigeon _miFareFamilyToWire(MiFareFamily value) => switch (value) {
  MiFareFamily.unknown => MiFareFamilyPigeon.unknown,
  MiFareFamily.ultralight => MiFareFamilyPigeon.ultralight,
  MiFareFamily.plus => MiFareFamilyPigeon.plus,
  MiFareFamily.desfire => MiFareFamilyPigeon.desfire,
};
