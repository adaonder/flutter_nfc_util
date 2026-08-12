import 'dart:typed_data';

import '../api.dart';
import '../common.dart';
import '../pigeon.g.dart';

/// An ISO 15693 request flag.
enum Iso15693RequestFlag { address, dualSubCarriers, highDataRate, option, protocolExtension, select }

/// A FeliCa polling request code.
enum FeliCaPollingRequestCode { noRequest, systemCode, communicationPerformance }

/// How many time slots a FeliCa polling command offers for answers.
enum FeliCaPollingTimeSlot { max1, max2, max4, max8, max16 }

/// The Mifare product family a tag belongs to.
enum MiFareFamily { unknown, ultralight, plus, desfire }

/// Whether a tag holds NDEF, and whether it can still be written.
enum NdefStatus { notSupported, readOnly, readWrite }

/// The two status bytes an ISO 7816 card answers with, plus its payload.
class Iso7816ResponseApdu {
  const Iso7816ResponseApdu({required this.payload, required this.statusWord1, required this.statusWord2});

  /// The response body, without the status bytes.
  final Uint8List payload;

  /// SW1.
  final int statusWord1;

  /// SW2.
  final int statusWord2;

  /// SW1 and SW2 as one 16-bit value, which is how card specifications write them.
  int get statusWord => (statusWord1 << 8) | statusWord2;

  /// Whether the card reported plain success, `9000`.
  ///
  /// A card can also answer `61xx` (more data available) or `62xx`/`63xx` (a warning), none
  /// of which are failures; check [statusWord] when those matter.
  bool get isSuccess => statusWord == 0x9000;

  @override
  String toString() =>
      'Iso7816ResponseApdu(${payload.length} bytes, SW=${statusWord.toRadixString(16).padLeft(4, '0')})';
}

/// The two status bytes a FeliCa card answers with.
class FeliCaStatusFlag {
  const FeliCaStatusFlag({required this.statusFlag1, required this.statusFlag2});

  final int statusFlag1;
  final int statusFlag2;

  /// Whether the card reported success. FeliCa signals that with a zero first flag.
  bool get isSuccess => statusFlag1 == 0x00;
}

/// The answer to a FeliCa polling command.
class FeliCaPollingResponse {
  const FeliCaPollingResponse({required this.manufacturerParameter, required this.requestData});

  final Uint8List manufacturerParameter;
  final Uint8List requestData;
}

/// The answer to a FeliCa read-without-encryption command.
class FeliCaReadWithoutEncryptionResponse {
  const FeliCaReadWithoutEncryptionResponse({
    required this.statusFlag1,
    required this.statusFlag2,
    required this.blockData,
  });

  final int statusFlag1;
  final int statusFlag2;
  final List<Uint8List> blockData;

  bool get isSuccess => statusFlag1 == 0x00;
}

/// The answer to a FeliCa request-service-v2 command.
class FeliCaRequestServiceV2Response {
  const FeliCaRequestServiceV2Response({
    required this.statusFlag1,
    required this.statusFlag2,
    required this.encryptionIdentifier,
    required this.nodeKeyVersionListAes,
    required this.nodeKeyVersionListDes,
  });

  final int statusFlag1;
  final int statusFlag2;
  final int encryptionIdentifier;
  final List<Uint8List>? nodeKeyVersionListAes;
  final List<Uint8List>? nodeKeyVersionListDes;
}

/// The answer to a FeliCa request-specification-version command.
class FeliCaRequestSpecificationVersionResponse {
  const FeliCaRequestSpecificationVersionResponse({
    required this.statusFlag1,
    required this.statusFlag2,
    required this.basicVersion,
    required this.optionVersion,
  });

  final int statusFlag1;
  final int statusFlag2;
  final Uint8List? basicVersion;
  final Uint8List? optionVersion;
}

/// What an ISO 15693 tag reports about itself.
class Iso15693SystemInfo {
  const Iso15693SystemInfo({
    required this.applicationFamilyIdentifier,
    required this.blockSize,
    required this.dataStorageFormatIdentifier,
    required this.icReference,
    required this.totalBlocks,
  });

  final int applicationFamilyIdentifier;
  final int blockSize;
  final int dataStorageFormatIdentifier;
  final int icReference;
  final int totalBlocks;
}

/// A tag's live NDEF status and capacity.
class QueryNdefStatusResponse {
  const QueryNdefStatusResponse({required this.status, required this.capacity});

  final NdefStatus status;

  /// The largest NDEF message the tag can hold, in bytes.
  final int capacity;
}

/// FeliCa, as CoreNFC exposes it. iOS only.
///
/// Polling `iso18092` makes CoreNFC require the
/// `com.apple.developer.nfc.readersession.felica.systemcodes` entitlement. Without it the
/// reader sheet never appears and the failure arrives asynchronously.
class FeliCa {
  const FeliCa._(this._handle, {required this.currentSystemCode, required this.currentIDm});

  /// Returns an instance for [tag], or null when the tag is not a FeliCa card.
  static FeliCa? from(NfcTag tag) {
    final data = tag.data.felica;
    if (data == null) return null;
    return FeliCa._(tag.data.handle, currentSystemCode: data.currentSystemCode, currentIDm: data.currentIDm);
  }

  final String _handle;

  final Uint8List currentSystemCode;
  final Uint8List currentIDm;

  Future<FeliCaPollingResponse> polling({
    required Uint8List systemCode,
    required FeliCaPollingRequestCode requestCode,
    required FeliCaPollingTimeSlot timeSlot,
  }) async {
    final response = await iosApi.felicaPolling(
      _handle,
      systemCode,
      switch (requestCode) {
        FeliCaPollingRequestCode.noRequest => FeliCaPollingRequestCodePigeon.noRequest,
        FeliCaPollingRequestCode.systemCode => FeliCaPollingRequestCodePigeon.systemCode,
        FeliCaPollingRequestCode.communicationPerformance => FeliCaPollingRequestCodePigeon.communicationPerformance,
      },
      switch (timeSlot) {
        FeliCaPollingTimeSlot.max1 => FeliCaPollingTimeSlotPigeon.max1,
        FeliCaPollingTimeSlot.max2 => FeliCaPollingTimeSlotPigeon.max2,
        FeliCaPollingTimeSlot.max4 => FeliCaPollingTimeSlotPigeon.max4,
        FeliCaPollingTimeSlot.max8 => FeliCaPollingTimeSlotPigeon.max8,
        FeliCaPollingTimeSlot.max16 => FeliCaPollingTimeSlotPigeon.max16,
      },
    );
    return FeliCaPollingResponse(
      manufacturerParameter: response.manufacturerParameter,
      requestData: response.requestData,
    );
  }

  Future<int> requestResponse() => iosApi.felicaRequestResponse(_handle);

  Future<List<Uint8List>> requestSystemCode() => iosApi.felicaRequestSystemCode(_handle);

  Future<List<Uint8List>> requestService({required List<Uint8List> nodeCodeList}) =>
      iosApi.felicaRequestService(_handle, nodeCodeList);

  Future<FeliCaRequestServiceV2Response> requestServiceV2({required List<Uint8List> nodeCodeList}) async {
    final response = await iosApi.felicaRequestServiceV2(_handle, nodeCodeList);
    return FeliCaRequestServiceV2Response(
      statusFlag1: response.statusFlag1,
      statusFlag2: response.statusFlag2,
      encryptionIdentifier: response.encryptionIdentifier,
      nodeKeyVersionListAes: response.nodeKeyVersionListAes,
      nodeKeyVersionListDes: response.nodeKeyVersionListDes,
    );
  }

  Future<FeliCaReadWithoutEncryptionResponse> readWithoutEncryption({
    required List<Uint8List> serviceCodeList,
    required List<Uint8List> blockList,
  }) async {
    final response = await iosApi.felicaReadWithoutEncryption(_handle, serviceCodeList, blockList);
    return FeliCaReadWithoutEncryptionResponse(
      statusFlag1: response.statusFlag1,
      statusFlag2: response.statusFlag2,
      blockData: response.blockData,
    );
  }

  Future<FeliCaStatusFlag> writeWithoutEncryption({
    required List<Uint8List> serviceCodeList,
    required List<Uint8List> blockList,
    required List<Uint8List> blockData,
  }) async {
    final response = await iosApi.felicaWriteWithoutEncryption(_handle, serviceCodeList, blockList, blockData);
    return FeliCaStatusFlag(statusFlag1: response.statusFlag1, statusFlag2: response.statusFlag2);
  }

  Future<FeliCaRequestSpecificationVersionResponse> requestSpecificationVersion() async {
    final response = await iosApi.felicaRequestSpecificationVersion(_handle);
    return FeliCaRequestSpecificationVersionResponse(
      statusFlag1: response.statusFlag1,
      statusFlag2: response.statusFlag2,
      basicVersion: response.basicVersion,
      optionVersion: response.optionVersion,
    );
  }

  Future<FeliCaStatusFlag> resetMode() async {
    final response = await iosApi.felicaResetMode(_handle);
    return FeliCaStatusFlag(statusFlag1: response.statusFlag1, statusFlag2: response.statusFlag2);
  }

  /// Sends a command packet the typed methods do not cover.
  Future<Uint8List> sendCommand(Uint8List commandPacket) => iosApi.felicaSendCommand(_handle, commandPacket);
}

/// ISO 15693, as CoreNFC exposes it, with typed commands rather than raw transceive.
/// iOS only; Android reaches the same tags through [NfcV].
class Iso15693 {
  const Iso15693._(this._handle, {required this.icManufacturerCode, required this.icSerialNumber});

  /// Returns an instance for [tag], or null when the tag is not ISO 15693.
  static Iso15693? from(NfcTag tag) {
    final data = tag.data.iso15693;
    if (data == null) return null;
    return Iso15693._(tag.data.handle, icManufacturerCode: data.icManufacturerCode, icSerialNumber: data.icSerialNumber);
  }

  final String _handle;

  final int icManufacturerCode;
  final Uint8List icSerialNumber;

  Future<Uint8List> readSingleBlock({required Set<Iso15693RequestFlag> requestFlags, required int blockNumber}) =>
      iosApi.iso15693ReadSingleBlock(_handle, _flags(requestFlags), blockNumber);

  Future<void> writeSingleBlock({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required Uint8List dataBlock,
  }) => iosApi.iso15693WriteSingleBlock(_handle, _flags(requestFlags), blockNumber, dataBlock);

  Future<void> lockBlock({required Set<Iso15693RequestFlag> requestFlags, required int blockNumber}) =>
      iosApi.iso15693LockBlock(_handle, _flags(requestFlags), blockNumber);

  Future<List<Uint8List>> readMultipleBlocks({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required int numberOfBlocks,
  }) => iosApi.iso15693ReadMultipleBlocks(_handle, _flags(requestFlags), blockNumber, numberOfBlocks);

  Future<void> writeMultipleBlocks({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required int numberOfBlocks,
    required List<Uint8List> dataBlocks,
  }) => iosApi.iso15693WriteMultipleBlocks(_handle, _flags(requestFlags), blockNumber, numberOfBlocks, dataBlocks);

  Future<List<int>> getMultipleBlockSecurityStatus({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required int numberOfBlocks,
  }) => iosApi.iso15693GetMultipleBlockSecurityStatus(_handle, _flags(requestFlags), blockNumber, numberOfBlocks);

  Future<void> writeAfi({required Set<Iso15693RequestFlag> requestFlags, required int afi}) =>
      iosApi.iso15693WriteAfi(_handle, _flags(requestFlags), afi);

  Future<void> lockAfi({required Set<Iso15693RequestFlag> requestFlags}) =>
      iosApi.iso15693LockAfi(_handle, _flags(requestFlags));

  Future<void> writeDsfId({required Set<Iso15693RequestFlag> requestFlags, required int dsfId}) =>
      iosApi.iso15693WriteDsfId(_handle, _flags(requestFlags), dsfId);

  Future<void> lockDsfId({required Set<Iso15693RequestFlag> requestFlags}) =>
      iosApi.iso15693LockDsfId(_handle, _flags(requestFlags));

  Future<void> resetToReady({required Set<Iso15693RequestFlag> requestFlags}) =>
      iosApi.iso15693ResetToReady(_handle, _flags(requestFlags));

  Future<void> select({required Set<Iso15693RequestFlag> requestFlags}) =>
      iosApi.iso15693Select(_handle, _flags(requestFlags));

  Future<void> stayQuiet() => iosApi.iso15693StayQuiet(_handle);

  Future<Uint8List> extendedReadSingleBlock({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
  }) => iosApi.iso15693ExtendedReadSingleBlock(_handle, _flags(requestFlags), blockNumber);

  Future<void> extendedWriteSingleBlock({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required Uint8List dataBlock,
  }) => iosApi.iso15693ExtendedWriteSingleBlock(_handle, _flags(requestFlags), blockNumber, dataBlock);

  Future<void> extendedLockBlock({required Set<Iso15693RequestFlag> requestFlags, required int blockNumber}) =>
      iosApi.iso15693ExtendedLockBlock(_handle, _flags(requestFlags), blockNumber);

  Future<List<Uint8List>> extendedReadMultipleBlocks({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required int numberOfBlocks,
  }) => iosApi.iso15693ExtendedReadMultipleBlocks(_handle, _flags(requestFlags), blockNumber, numberOfBlocks);

  Future<Iso15693SystemInfo> getSystemInfo({required Set<Iso15693RequestFlag> requestFlags}) async {
    final info = await iosApi.iso15693GetSystemInfo(_handle, _flags(requestFlags));
    return Iso15693SystemInfo(
      applicationFamilyIdentifier: info.applicationFamilyIdentifier,
      blockSize: info.blockSize,
      dataStorageFormatIdentifier: info.dataStorageFormatIdentifier,
      icReference: info.icReference,
      totalBlocks: info.totalBlocks,
    );
  }

  Future<Uint8List> customCommand({
    required Set<Iso15693RequestFlag> requestFlags,
    required int customCommandCode,
    required Uint8List customRequestParameters,
  }) => iosApi.iso15693CustomCommand(_handle, _flags(requestFlags), customCommandCode, customRequestParameters);

  static List<Iso15693RequestFlagPigeon> _flags(Set<Iso15693RequestFlag> flags) => [
    for (final flag in flags)
      switch (flag) {
        Iso15693RequestFlag.address => Iso15693RequestFlagPigeon.address,
        Iso15693RequestFlag.dualSubCarriers => Iso15693RequestFlagPigeon.dualSubCarriers,
        Iso15693RequestFlag.highDataRate => Iso15693RequestFlagPigeon.highDataRate,
        Iso15693RequestFlag.option => Iso15693RequestFlagPigeon.option,
        Iso15693RequestFlag.protocolExtension => Iso15693RequestFlagPigeon.protocolExtension,
        Iso15693RequestFlag.select => Iso15693RequestFlagPigeon.select,
      },
  ];
}

/// ISO 7816, as CoreNFC exposes it. iOS only; Android reaches the same cards through
/// [IsoDep].
class Iso7816 {
  const Iso7816._(
    this._handle, {
    required this.initialSelectedAID,
    required this.historicalBytes,
    required this.applicationData,
    required this.proprietaryApplicationDataCoding,
  });

  /// Returns an instance for [tag], or null when the tag is not an ISO 7816 card.
  static Iso7816? from(NfcTag tag) {
    final data = tag.data.iso7816;
    if (data == null) return null;
    return Iso7816._(
      tag.data.handle,
      initialSelectedAID: data.initialSelectedAID,
      historicalBytes: data.historicalBytes,
      applicationData: data.applicationData,
      proprietaryApplicationDataCoding: data.proprietaryApplicationDataCoding,
    );
  }

  final String _handle;

  /// The application CoreNFC selected while discovering the card, as hex.
  final String initialSelectedAID;

  final Uint8List? historicalBytes;
  final Uint8List? applicationData;
  final bool proprietaryApplicationDataCoding;

  /// Sends a command APDU assembled from its fields.
  Future<Iso7816ResponseApdu> sendCommand({
    required int instructionClass,
    required int instructionCode,
    required int p1Parameter,
    required int p2Parameter,
    required Uint8List data,
    required int expectedResponseLength,
  }) async {
    final response = await iosApi.iso7816SendCommand(
      _handle,
      instructionClass,
      instructionCode,
      p1Parameter,
      p2Parameter,
      data,
      expectedResponseLength,
    );
    return _toApdu(response);
  }

  /// Sends an already-encoded command APDU.
  Future<Iso7816ResponseApdu> sendCommandRaw(Uint8List data) async =>
      _toApdu(await iosApi.iso7816SendCommandRaw(_handle, data));
}

/// Mifare, as CoreNFC exposes it. iOS only.
///
/// Mifare Classic is absent on purpose: Apple does not let any app talk to those tags, so
/// there is no iOS counterpart to [MifareClassic].
class MiFare {
  const MiFare._(this._handle, {required this.family, required this.historicalBytes});

  /// Returns an instance for [tag], or null when the tag is not a Mifare card.
  static MiFare? from(NfcTag tag) {
    final data = tag.data.mifare;
    if (data == null) return null;
    return MiFare._(
      tag.data.handle,
      family: switch (data.family) {
        MiFareFamilyPigeon.unknown => MiFareFamily.unknown,
        MiFareFamilyPigeon.ultralight => MiFareFamily.ultralight,
        MiFareFamilyPigeon.plus => MiFareFamily.plus,
        MiFareFamilyPigeon.desfire => MiFareFamily.desfire,
      },
      historicalBytes: data.historicalBytes,
    );
  }

  final String _handle;

  final MiFareFamily family;
  final Uint8List? historicalBytes;

  /// Sends a native Mifare command.
  Future<Uint8List> sendMiFareCommand(Uint8List commandPacket) => iosApi.mifareSendCommand(_handle, commandPacket);

  /// Sends an ISO 7816 command APDU assembled from its fields.
  Future<Iso7816ResponseApdu> sendMiFareIso7816Command({
    required int instructionClass,
    required int instructionCode,
    required int p1Parameter,
    required int p2Parameter,
    required Uint8List data,
    required int expectedResponseLength,
  }) async {
    final response = await iosApi.mifareSendIso7816Command(
      _handle,
      instructionClass,
      instructionCode,
      p1Parameter,
      p2Parameter,
      data,
      expectedResponseLength,
    );
    return _toApdu(response);
  }

  /// Sends an already-encoded ISO 7816 command APDU.
  Future<Iso7816ResponseApdu> sendMiFareIso7816CommandRaw(Uint8List data) async =>
      _toApdu(await iosApi.mifareSendIso7816CommandRaw(_handle, data));
}

/// What CoreNFC reports about a tag's NDEF support beyond what the cross-platform `Ndef`
/// exposes.
///
/// Use `Ndef.from(tag)` for reading and writing; this adds the live status query, which
/// Android has no equivalent for.
class NdefIos {
  const NdefIos._(this._handle, {required this.status, required this.capacity});

  /// Returns an instance for [tag], or null when the tag does not hold NDEF.
  static NdefIos? from(NfcTag tag) {
    final data = tag.data.ndefIos;
    if (data == null) return null;
    return NdefIos._(tag.data.handle, status: ndefStatusFromWire(data.status), capacity: data.capacity);
  }

  final String _handle;

  /// The status captured at discovery.
  final NdefStatus status;

  /// The largest message the tag can hold, in bytes, as captured at discovery.
  final int capacity;

  /// Re-reads the status and capacity from the tag.
  ///
  /// [status] and [capacity] are a snapshot taken at discovery; this is the live pair, and
  /// the way to confirm a tag actually locked after `Ndef.writeLock()`.
  Future<QueryNdefStatusResponse> queryStatus() async {
    final response = await iosApi.ndefQueryStatus(_handle);
    return QueryNdefStatusResponse(status: ndefStatusFromWire(response.status), capacity: response.capacity);
  }
}

Iso7816ResponseApdu _toApdu(Iso7816ResponseApduPigeon response) => Iso7816ResponseApdu(
  payload: response.payload,
  statusWord1: response.statusWord1,
  statusWord2: response.statusWord2,
);

/// Maps the wire NDEF status onto the public enum. Used by both the iOS platform object and
/// the cross-platform `Ndef`.
NdefStatus ndefStatusFromWire(NdefStatusPigeon value) => switch (value) {
  NdefStatusPigeon.notSupported => NdefStatus.notSupported,
  NdefStatusPigeon.readOnly => NdefStatus.readOnly,
  NdefStatusPigeon.readWrite => NdefStatus.readWrite,
};
