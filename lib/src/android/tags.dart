import 'dart:typed_data';

import '../api.dart';
import '../common.dart';
import '../mapping.dart';
import '../ndef/message.dart';
import '../pigeon.g.dart';

/// Shared plumbing for the `android.nfc.tech` classes.
///
/// Every technology answers `transceive` and reports a maximum length, and the call is
/// addressed by a handle plus the technology to run it against. 2.x spelled that out as
/// seven near-identical channel methods per operation.
abstract class _AndroidTag {
  const _AndroidTag(this._handle);

  final String _handle;

  AndroidTechPigeon get _tech;

  /// Sends a raw command to the tag and returns its answer.
  ///
  /// The connection is opened on first use and held for the rest of the session, so a
  /// Mifare Classic sector authentication still applies to the `readBlock` that follows.
  Future<Uint8List> transceive(Uint8List data) => androidApi.transceive(_handle, _tech, data);

  /// The largest payload [transceive] accepts, in bytes.
  Future<int> getMaxTransceiveLength() => androidApi.getMaxTransceiveLength(_handle, _tech);
}

/// A technology whose transceive timeout can be read and changed.
///
/// `android.nfc.tech` offers no timeout accessor for NfcB or NfcV, so those two do not
/// extend this.
abstract class _AndroidTagWithTimeout extends _AndroidTag {
  const _AndroidTagWithTimeout(super.handle);

  /// The current transceive timeout.
  Future<Duration> getTimeout() async => Duration(milliseconds: await androidApi.getTimeout(_handle, _tech));

  /// Gives a slow tag more time before the exchange fails as lost.
  Future<void> setTimeout(Duration timeout) => androidApi.setTimeout(_handle, _tech, timeout.inMilliseconds);
}

/// ISO 14443-3A. Android only.
class NfcA extends _AndroidTagWithTimeout {
  const NfcA._(super.handle, {required this.atqa, required this.sak, required this.maxTransceiveLength, required this.timeout});

  /// Returns an instance for [tag], or null when the tag does not answer to NfcA.
  static NfcA? from(NfcTag tag) {
    final data = tag.data.nfcA;
    if (data == null) return null;
    return NfcA._(
      tag.data.handle,
      atqa: data.atqa,
      sak: data.sak,
      maxTransceiveLength: data.maxTransceiveLength,
      timeout: Duration(milliseconds: data.timeout),
    );
  }

  @override
  AndroidTechPigeon get _tech => AndroidTechPigeon.nfcA;

  /// The answer-to-request value, captured at discovery.
  ///
  /// Null when the stack reported no poll bytes for this tag. Empty would be a lie: it is
  /// not "the tag answered nothing", it is "the platform never told us".
  final Uint8List? atqa;

  /// The select-acknowledge value, captured at discovery.
  final int sak;

  /// The value at discovery. Call [getMaxTransceiveLength] for the live one.
  final int maxTransceiveLength;

  /// The value at discovery. Call [getTimeout] for the live one.
  final Duration timeout;
}

/// ISO 14443-3B. Android only.
class NfcB extends _AndroidTag {
  const NfcB._(super.handle, {required this.applicationData, required this.protocolInfo, required this.maxTransceiveLength});

  /// Returns an instance for [tag], or null when the tag does not answer to NfcB.
  static NfcB? from(NfcTag tag) {
    final data = tag.data.nfcB;
    if (data == null) return null;
    return NfcB._(
      tag.data.handle,
      applicationData: data.applicationData,
      protocolInfo: data.protocolInfo,
      maxTransceiveLength: data.maxTransceiveLength,
    );
  }

  @override
  AndroidTechPigeon get _tech => AndroidTechPigeon.nfcB;

  /// The ATQB application data. Null when the tag reported no ATQB parameters -- a B-prime
  /// target answers no SENSB_RES at all yet is still reported as ISO 14443-3B.
  final Uint8List? applicationData;

  /// The ATQB protocol info. Null under the same conditions as [applicationData].
  final Uint8List? protocolInfo;

  /// The value at discovery. Call [getMaxTransceiveLength] for the live one.
  final int maxTransceiveLength;
}

/// JIS 6319-4, the FeliCa transport. Android only; iOS exposes FeliCa as [FeliCa] instead.
class NfcF extends _AndroidTagWithTimeout {
  const NfcF._(
    super.handle, {
    required this.manufacturer,
    required this.systemCode,
    required this.maxTransceiveLength,
    required this.timeout,
  });

  /// Returns an instance for [tag], or null when the tag does not answer to NfcF.
  static NfcF? from(NfcTag tag) {
    final data = tag.data.nfcF;
    if (data == null) return null;
    return NfcF._(
      tag.data.handle,
      manufacturer: data.manufacturer,
      systemCode: data.systemCode,
      maxTransceiveLength: data.maxTransceiveLength,
      timeout: Duration(milliseconds: data.timeout),
    );
  }

  @override
  AndroidTechPigeon get _tech => AndroidTechPigeon.nfcF;

  /// Null when the stack reported no poll bytes for this tag.
  final Uint8List? manufacturer;

  /// Null under the same conditions as [manufacturer].
  final Uint8List? systemCode;

  /// The value at discovery. Call [getMaxTransceiveLength] for the live one.
  final int maxTransceiveLength;

  /// The value at discovery. Call [getTimeout] for the live one.
  final Duration timeout;
}

/// ISO 15693. Android only; iOS exposes it as [Iso15693] with typed commands instead.
class NfcV extends _AndroidTag {
  const NfcV._(super.handle, {required this.dsfId, required this.responseFlags, required this.maxTransceiveLength});

  /// Returns an instance for [tag], or null when the tag does not answer to NfcV.
  static NfcV? from(NfcTag tag) {
    final data = tag.data.nfcV;
    if (data == null) return null;
    return NfcV._(
      tag.data.handle,
      dsfId: data.dsfId,
      responseFlags: data.responseFlags,
      maxTransceiveLength: data.maxTransceiveLength,
    );
  }

  @override
  AndroidTechPigeon get _tech => AndroidTechPigeon.nfcV;

  /// The data storage format identifier, 0-255. Matches
  /// [Iso15693SystemInfo.dataStorageFormatIdentifier] on iOS for the same tag.
  final int dsfId;

  /// The response flags the tag answered the inventory with, 0-255.
  final int responseFlags;

  /// The value at discovery. Call [getMaxTransceiveLength] for the live one.
  final int maxTransceiveLength;
}

/// ISO 14443-4, the APDU transport. Android only; iOS exposes it as [Iso7816].
class IsoDep extends _AndroidTagWithTimeout {
  const IsoDep._(
    super.handle, {
    required this.hiLayerResponse,
    required this.historicalBytes,
    required this.isExtendedLengthApduSupported,
    required this.maxTransceiveLength,
    required this.timeout,
  });

  /// Returns an instance for [tag], or null when the tag does not answer to IsoDep.
  static IsoDep? from(NfcTag tag) {
    final data = tag.data.isoDep;
    if (data == null) return null;
    return IsoDep._(
      tag.data.handle,
      hiLayerResponse: data.hiLayerResponse,
      historicalBytes: data.historicalBytes,
      isExtendedLengthApduSupported: data.isExtendedLengthApduSupported,
      maxTransceiveLength: data.maxTransceiveLength,
      timeout: Duration(milliseconds: data.timeout),
    );
  }

  @override
  AndroidTechPigeon get _tech => AndroidTechPigeon.isoDep;

  /// Set for an ISO 14443-4B tag; null for 14443-4A, which reports [historicalBytes].
  final Uint8List? hiLayerResponse;

  /// Set for an ISO 14443-4A tag; null for 14443-4B.
  final Uint8List? historicalBytes;

  /// Whether the card accepts APDUs longer than 255 bytes.
  final bool isExtendedLengthApduSupported;

  /// The value at discovery. Call [getMaxTransceiveLength] for the live one.
  final int maxTransceiveLength;

  /// The value at discovery. Call [getTimeout] for the live one.
  final Duration timeout;
}

/// The Mifare Classic variant a tag reports.
enum MifareClassicType { classic, plus, pro, unknown }

/// NXP Mifare Classic. Android only -- iOS cannot talk to these tags at all, which is an
/// Apple restriction rather than a gap in this package.
class MifareClassic extends _AndroidTagWithTimeout {
  const MifareClassic._(
    super.handle, {
    required this.type,
    required this.blockCount,
    required this.sectorCount,
    required this.size,
    required this.maxTransceiveLength,
    required this.timeout,
  });

  /// Returns an instance for [tag], or null when the tag is not a Mifare Classic.
  static MifareClassic? from(NfcTag tag) {
    final data = tag.data.mifareClassic;
    if (data == null) return null;
    return MifareClassic._(
      tag.data.handle,
      type: switch (data.type) {
        MifareClassicTypePigeon.classic => MifareClassicType.classic,
        MifareClassicTypePigeon.plus => MifareClassicType.plus,
        MifareClassicTypePigeon.pro => MifareClassicType.pro,
        MifareClassicTypePigeon.unknown => MifareClassicType.unknown,
      },
      blockCount: data.blockCount,
      sectorCount: data.sectorCount,
      size: data.size,
      maxTransceiveLength: data.maxTransceiveLength,
      timeout: Duration(milliseconds: data.timeout),
    );
  }

  @override
  AndroidTechPigeon get _tech => AndroidTechPigeon.mifareClassic;

  /// Which Mifare Classic product this is.
  final MifareClassicType type;

  /// How many 16-byte blocks the card holds in total.
  final int blockCount;

  /// How many sectors the card holds. Sector sizes are not uniform -- see [blockToSector].
  final int sectorCount;

  /// The tag's total size in bytes.
  final int size;

  /// The value at discovery. Call [getMaxTransceiveLength] for the live one.
  final int maxTransceiveLength;

  /// The value at discovery. Call [getTimeout] for the live one.
  final Duration timeout;

  /// Authenticates a sector with key A. Returns false when the key is wrong.
  ///
  /// The authentication holds for the rest of the session, so the reads and writes that
  /// follow do not need to repeat it.
  Future<bool> authenticateSectorWithKeyA({required int sectorIndex, required Uint8List key}) =>
      androidApi.mifareClassicAuthenticateSector(_handle, sectorIndex, key, true);

  /// Authenticates a sector with key B. Returns false when the key is wrong.
  Future<bool> authenticateSectorWithKeyB({required int sectorIndex, required Uint8List key}) =>
      androidApi.mifareClassicAuthenticateSector(_handle, sectorIndex, key, false);

  /// Reads one 16-byte block.
  Future<Uint8List> readBlock({required int blockIndex}) => androidApi.mifareClassicReadBlock(_handle, blockIndex);

  /// Writes one 16-byte block.
  Future<void> writeBlock({required int blockIndex, required Uint8List data}) =>
      androidApi.mifareClassicWriteBlock(_handle, blockIndex, data);

  /// Adds to a value block, leaving the result in the internal transfer buffer.
  Future<void> increment({required int blockIndex, required int value}) =>
      androidApi.mifareClassicIncrement(_handle, blockIndex, value);

  /// Subtracts from a value block, leaving the result in the internal transfer buffer.
  Future<void> decrement({required int blockIndex, required int value}) =>
      androidApi.mifareClassicDecrement(_handle, blockIndex, value);

  /// Copies a value block into the internal transfer buffer.
  Future<void> restore({required int blockIndex}) => androidApi.mifareClassicRestore(_handle, blockIndex);

  /// Writes the internal transfer buffer to a value block.
  Future<void> transfer({required int blockIndex}) => androidApi.mifareClassicTransfer(_handle, blockIndex);

  /// The sector a block belongs to.
  ///
  /// Sector geometry is not uniform -- a 4K card has 32 sectors of 4 blocks followed by 8
  /// of 16 -- so this cannot be worked out by hand from [blockCount] and [sectorCount].
  /// Reads a static description rather than talking to the tag, so it needs no connection.
  Future<int> blockToSector({required int blockIndex}) => androidApi.mifareClassicBlockToSector(_handle, blockIndex);

  /// The first block of a sector.
  Future<int> sectorToBlock({required int sectorIndex}) => androidApi.mifareClassicSectorToBlock(_handle, sectorIndex);

  /// How many blocks a sector holds.
  Future<int> getBlockCountInSector({required int sectorIndex}) =>
      androidApi.mifareClassicBlockCountInSector(_handle, sectorIndex);
}

/// The Mifare Ultralight variant a tag reports.
enum MifareUltralightType { ultralight, ultralightC, unknown }

/// NXP Mifare Ultralight. Android only; iOS reaches these through [MiFare].
class MifareUltralight extends _AndroidTagWithTimeout {
  const MifareUltralight._(super.handle, {required this.type, required this.maxTransceiveLength, required this.timeout});

  /// Returns an instance for [tag], or null when the tag is not a Mifare Ultralight.
  static MifareUltralight? from(NfcTag tag) {
    final data = tag.data.mifareUltralight;
    if (data == null) return null;
    return MifareUltralight._(
      tag.data.handle,
      type: switch (data.type) {
        MifareUltralightTypePigeon.ultralight => MifareUltralightType.ultralight,
        MifareUltralightTypePigeon.ultralightC => MifareUltralightType.ultralightC,
        MifareUltralightTypePigeon.unknown => MifareUltralightType.unknown,
      },
      maxTransceiveLength: data.maxTransceiveLength,
      timeout: Duration(milliseconds: data.timeout),
    );
  }

  @override
  AndroidTechPigeon get _tech => AndroidTechPigeon.mifareUltralight;

  /// Which Mifare Ultralight product this is.
  final MifareUltralightType type;

  /// The value at discovery. Call [getMaxTransceiveLength] for the live one.
  final int maxTransceiveLength;

  /// The value at discovery. Call [getTimeout] for the live one.
  final Duration timeout;

  /// Reads four pages -- 16 bytes -- starting at [pageOffset].
  Future<Uint8List> readPages({required int pageOffset}) =>
      androidApi.mifareUltralightReadPages(_handle, pageOffset);

  /// Writes one four-byte page.
  Future<void> writePage({required int pageOffset, required Uint8List data}) =>
      androidApi.mifareUltralightWritePage(_handle, pageOffset, data);
}

/// The barcode standard a tag follows.
enum NfcBarcodeType { kovio, unknown }

/// A Kovio barcode tag. Android only.
///
/// Carries data and nothing else, because `android.nfc.tech.NfcBarcode` has no operations.
/// Discovered only when the session sets `discoverNfcBarcodeAndroid`.
class NfcBarcode {
  const NfcBarcode._({required this.type, required this.barcode});

  /// Returns an instance for [tag], or null when the tag is not a barcode tag.
  static NfcBarcode? from(NfcTag tag) {
    final data = tag.data.nfcBarcode;
    if (data == null) return null;
    return NfcBarcode._(
      type: switch (data.type) {
        NfcBarcodeTypePigeon.kovio => NfcBarcodeType.kovio,
        NfcBarcodeTypePigeon.unknown => NfcBarcodeType.unknown,
      },
      barcode: data.barcode,
    );
  }

  /// Which barcode standard the tag follows.
  final NfcBarcodeType type;

  /// The barcode payload, when the tag reports one.
  final Uint8List? barcode;
}

/// What Android reports about a tag's NDEF support beyond what the cross-platform `Ndef`
/// exposes.
///
/// Use `Ndef.from(tag)` for reading and writing; this is for the two facts only Android
/// knows.
class NdefAndroid {
  const NdefAndroid._({required this.type, required this.canMakeReadOnly});

  /// Returns an instance for [tag], or null when the tag does not hold NDEF.
  static NdefAndroid? from(NfcTag tag) {
    final data = tag.data.ndefAndroid;
    if (data == null) return null;
    return NdefAndroid._(type: data.type, canMakeReadOnly: data.canMakeReadOnly);
  }

  /// The NFC Forum tag type, such as `org.nfcforum.ndef.type2`.
  final String type;

  /// Whether `Ndef.writeLock()` can succeed on this tag. Not every tag can be locked, and
  /// iOS offers no way to ask at all.
  final bool canMakeReadOnly;
}

/// A tag that can be formatted to hold NDEF but has not been yet. Android only: CoreNFC
/// has no equivalent, so an unformatted tag cannot be prepared from iOS.
class NdefFormatable {
  const NdefFormatable._(this._handle);

  /// Returns an instance for [tag], or null when the tag cannot be NDEF-formatted.
  static NdefFormatable? from(NfcTag tag) =>
      tag.data.ndefFormatable == true ? NdefFormatable._(tag.data.handle) : null;

  final String _handle;

  /// Formats the tag and writes [firstMessage].
  Future<void> format(NdefMessage firstMessage) =>
      androidApi.ndefFormat(_handle, ndefMessageToWire(firstMessage), false);

  /// Formats the tag, writes [firstMessage], and locks it.
  ///
  /// Permanent: the tag can never be written again.
  Future<void> formatReadOnly(NdefMessage firstMessage) =>
      androidApi.ndefFormat(_handle, ndefMessageToWire(firstMessage), true);
}
