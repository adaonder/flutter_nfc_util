import 'dart:typed_data';

import '../apdu/response_apdu.dart';
import '../api.dart';
import '../common.dart';
import '../pigeon.g.dart';

/// An ISO 15693 request flag.
enum Iso15693RequestFlag { address, dualSubCarriers, highDataRate, option, protocolExtension, select }

/// A bit of the 8-bit response flag an ISO 15693-3 tag answers with.
///
/// Only the commands that report one hand it back: [Iso15693.authenticate],
/// [Iso15693.keyUpdate], [Iso15693.readBuffer] and [Iso15693.sendRequest]. Everywhere else
/// CoreNFC reads the flag itself, raises an error when it says so, and passes on the data
/// alone -- so by the time that answer reaches Dart there is nothing left to report.
enum Iso15693ResponseFlag {
  /// The tag rejected the request, and the data alongside is an ISO 15693-3 error code
  /// rather than a payload. Nothing else in the flag is worth reading once this is set.
  error,

  /// The tag has an answer waiting in its buffer, which [Iso15693.readBuffer] collects.
  responseBufferValid,

  /// The exchange is over. Clear means the tag expects another round -- a multi-step
  /// authentication that is not finished yet.
  finalResponse,

  /// The response is in the extended format, the one that addresses more than 256 blocks.
  protocolExtension,

  /// Half of the block security status the tag reported. What the pair says is defined by
  /// the command that provoked the response, not by the flag byte.
  blockSecurityStatusBit5,

  /// The other half; see [blockSecurityStatusBit5].
  blockSecurityStatusBit6,

  /// The tag asked for more time than the default frame timeout allows.
  waitTimeExtension,
}

/// A FeliCa polling request code.
enum FeliCaPollingRequestCode { noRequest, systemCode, communicationPerformance }

/// How many time slots a FeliCa polling command offers for answers.
enum FeliCaPollingTimeSlot { max1, max2, max4, max8, max16 }

/// The Mifare product family a tag belongs to.
enum MiFareFamily { unknown, ultralight, plus, desfire }

/// Whether a tag holds NDEF, and whether it can still be written.
enum NdefStatus { notSupported, readOnly, readWrite }

/// The two status bytes a FeliCa card answers with.
class FeliCaStatusFlag {
  const FeliCaStatusFlag({required this.statusFlag1, required this.statusFlag2});

  /// Status flag 1. Zero means the command succeeded.
  final int statusFlag1;

  /// Status flag 2. Meaningful only when [statusFlag1] is non-zero, where it says why.
  final int statusFlag2;

  /// Whether the card reported success. FeliCa signals that with a zero first flag.
  bool get isSuccess => statusFlag1 == 0x00;
}

/// The answer to a FeliCa polling command.
class FeliCaPollingResponse {
  const FeliCaPollingResponse({required this.manufacturerParameter, required this.requestData});

  /// The card's manufacture parameter, PMm.
  final Uint8List manufacturerParameter;

  /// The data the request code asked for. Empty when the polling used
  /// [FeliCaPollingRequestCode.noRequest].
  final Uint8List requestData;
}

/// The answer to a FeliCa read-without-encryption command.
class FeliCaReadWithoutEncryptionResponse {
  const FeliCaReadWithoutEncryptionResponse({
    required this.statusFlag1,
    required this.statusFlag2,
    required this.blockData,
  });

  /// Status flag 1. Zero means the read succeeded.
  final int statusFlag1;

  /// Status flag 2, which says why when [statusFlag1] is non-zero.
  final int statusFlag2;

  /// One entry per requested block, in the order they were asked for. Empty on failure.
  final List<Uint8List> blockData;

  /// Whether the card reported success.
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

  /// Status flag 1. Zero means the command succeeded.
  final int statusFlag1;

  /// Status flag 2, which says why when [statusFlag1] is non-zero.
  final int statusFlag2;

  /// Which encryption the node uses: AES, DES, or both.
  final int encryptionIdentifier;

  /// Key versions for the AES nodes. Null when the card reported none.
  final List<Uint8List>? nodeKeyVersionListAes;

  /// Key versions for the DES nodes. Null when the card reported none.
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

  /// Status flag 1. Zero means the command succeeded.
  final int statusFlag1;

  /// Status flag 2, which says why when [statusFlag1] is non-zero.
  final int statusFlag2;

  /// The version of the card's basic specification. Null when it reported none.
  final Uint8List? basicVersion;

  /// The version of the card's optional specification. Null when it implements none.
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
    this.uid,
  });

  /// The AFI, which groups tags by application. 0 means the tag is in every group.
  final int applicationFamilyIdentifier;

  /// The size of one block, in bytes.
  final int blockSize;

  /// The DSFID, an application-defined byte describing how the data is laid out.
  final int dataStorageFormatIdentifier;

  /// The manufacturer's IC reference.
  final int icReference;

  /// How many blocks the tag holds. Note this can exceed 255, in which case the block number
  /// arguments below cannot address them all -- the extended commands exist for that.
  final int totalBlocks;

  /// The tag's 64-bit UID, in the little-endian order it arrived in -- the reverse of
  /// [Iso15693.icSerialNumber], so the two do not compare byte for byte.
  ///
  /// Only [Iso15693.getSystemInfoAndUid] fills this in; the deprecated
  /// [Iso15693.getSystemInfo] calls a selector that never reported one. Null too when the
  /// tag answered without it.
  final Uint8List? uid;
}

/// The answer to a command that reports the tag's response flag as well as its data.
class Iso15693Response {
  const Iso15693Response({required this.flags, required this.data});

  /// The bits the tag set in its response flag.
  ///
  /// [Iso15693ResponseFlag.error] means [data] carries an ISO 15693-3 error code rather than
  /// a payload -- a rejection [Iso15693.sendRequest] reports here instead of throwing.
  final Set<Iso15693ResponseFlag> flags;

  /// The response with its flag byte stripped off. Empty when the tag answered with the flag
  /// alone.
  final Uint8List data;
}

/// How stubbornly CoreNFC should chase a command the tag did not answer.
///
/// Only [Iso15693.readMultipleBlocksWithConfiguration] and
/// [Iso15693.customCommandWithConfiguration] accept one; there is no general form. It buys
/// retries that stay inside the reader session, where the alternative -- retrying from Dart
/// -- pays a platform round trip per attempt, and a tag held against a phone by hand is
/// often gone before the second one lands.
class Iso15693CommandConfiguration {
  const Iso15693CommandConfiguration({required this.maximumRetries, this.retryInterval = Duration.zero});

  /// How many times to resend before giving up. Zero sends the command once.
  ///
  /// Apple documents the valid range as 0 to 256, on the configuration base class rather than
  /// on the commands themselves. Anything outside it throws
  /// `PlatformException(code: 'invalidParameter')` rather than reaching CoreNFC, which takes
  /// this as an unsigned count -- so a negative one would not arrive there small.
  final int maximumRetries;

  /// How long to wait between attempts. Fractions of a second survive the trip: CoreNFC
  /// counts this in seconds and takes them as a double.
  ///
  /// Must not be negative, for the same reason as [maximumRetries].
  final Duration retryInterval;

  Iso15693CommandConfigurationPigeon _toWire() => Iso15693CommandConfigurationPigeon(
    maximumRetries: maximumRetries,
    retryIntervalSeconds: retryInterval.inMicroseconds / Duration.microsecondsPerSecond,
  );
}

/// A tag's live NDEF status and capacity.
class QueryNdefStatusResponse {
  const QueryNdefStatusResponse({required this.status, required this.capacity});

  /// Whether the tag holds NDEF at all, and whether it can still be written.
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

  /// The system code the card is currently addressing.
  final Uint8List currentSystemCode;

  /// The card's manufacture identifier, IDm -- its UID for this session.
  final Uint8List currentIDm;

  /// Selects a system on the card and reads what [requestCode] asks for.
  ///
  /// [timeSlot] is how many slots the card may answer in; more slots reduce collisions when
  /// several cards are present, at the cost of time.
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

  /// Asks the card for its current mode. Chiefly a liveness check.
  Future<int> requestResponse() => iosApi.felicaRequestResponse(_handle);

  /// Lists every system code the card carries, not just the one currently selected.
  Future<List<Uint8List>> requestSystemCode() => iosApi.felicaRequestSystemCode(_handle);

  /// Reads the key version of each node in [nodeCodeList].
  ///
  /// A key version of `FFFF` means the node does not exist on this card.
  Future<List<Uint8List>> requestService({required List<Uint8List> nodeCodeList}) =>
      iosApi.felicaRequestService(_handle, nodeCodeList);

  /// As [requestService], but also reports which encryption each node uses.
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

  /// Reads blocks from services that need no authentication.
  ///
  /// [blockList] entries are block list elements, not plain block numbers: the first byte
  /// carries the access mode and the service index, so build them per the FeliCa
  /// specification rather than passing bare indices.
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

  /// Writes blocks to services that need no authentication.
  ///
  /// [blockData] must hold one 16-byte block per entry in [blockList], in the same order.
  Future<FeliCaStatusFlag> writeWithoutEncryption({
    required List<Uint8List> serviceCodeList,
    required List<Uint8List> blockList,
    required List<Uint8List> blockData,
  }) async {
    final response = await iosApi.felicaWriteWithoutEncryption(_handle, serviceCodeList, blockList, blockData);
    return FeliCaStatusFlag(statusFlag1: response.statusFlag1, statusFlag2: response.statusFlag2);
  }

  /// Reads which version of the FeliCa specification the card implements.
  Future<FeliCaRequestSpecificationVersionResponse> requestSpecificationVersion() async {
    final response = await iosApi.felicaRequestSpecificationVersion(_handle);
    return FeliCaRequestSpecificationVersionResponse(
      statusFlag1: response.statusFlag1,
      statusFlag2: response.statusFlag2,
      basicVersion: response.basicVersion,
      optionVersion: response.optionVersion,
    );
  }

  /// Returns the card to mode 0, undoing whatever mode a previous command left it in.
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
    return Iso15693._(
      tag.data.handle,
      icManufacturerCode: data.icManufacturerCode,
      icSerialNumber: data.icSerialNumber,
    );
  }

  final String _handle;

  /// The IC manufacturer's registration code, as assigned by ISO/IEC 7816-6.
  final int icManufacturerCode;

  /// The manufacturer-assigned serial number, which together with [icManufacturerCode] makes
  /// up the tag's UID.
  final Uint8List icSerialNumber;

  /// Reads one block. [blockNumber] is 0-255; use [extendedReadSingleBlock] beyond that.
  Future<Uint8List> readSingleBlock({required Set<Iso15693RequestFlag> requestFlags, required int blockNumber}) =>
      iosApi.iso15693ReadSingleBlock(_handle, _flags(requestFlags), blockNumber);

  /// Writes one block. [dataBlock] must be exactly the tag's block size.
  Future<void> writeSingleBlock({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required Uint8List dataBlock,
  }) => iosApi.iso15693WriteSingleBlock(_handle, _flags(requestFlags), blockNumber, dataBlock);

  /// Locks one block permanently. It can never be written again.
  Future<void> lockBlock({required Set<Iso15693RequestFlag> requestFlags, required int blockNumber}) =>
      iosApi.iso15693LockBlock(_handle, _flags(requestFlags), blockNumber);

  /// Reads [numberOfBlocks] consecutive blocks starting at [blockNumber], one entry each.
  Future<List<Uint8List>> readMultipleBlocks({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required int numberOfBlocks,
  }) => iosApi.iso15693ReadMultipleBlocks(_handle, _flags(requestFlags), blockNumber, numberOfBlocks);

  /// Writes consecutive blocks. [dataBlocks] must hold [numberOfBlocks] entries.
  Future<void> writeMultipleBlocks({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required int numberOfBlocks,
    required List<Uint8List> dataBlocks,
  }) => iosApi.iso15693WriteMultipleBlocks(_handle, _flags(requestFlags), blockNumber, numberOfBlocks, dataBlocks);

  /// Reports the lock state of each block in the range, one entry per block.
  Future<List<int>> getMultipleBlockSecurityStatus({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required int numberOfBlocks,
  }) => iosApi.iso15693GetMultipleBlockSecurityStatus(_handle, _flags(requestFlags), blockNumber, numberOfBlocks);

  /// Sets the application family identifier, 0-255.
  Future<void> writeAfi({required Set<Iso15693RequestFlag> requestFlags, required int afi}) =>
      iosApi.iso15693WriteAfi(_handle, _flags(requestFlags), afi);

  /// Locks the AFI permanently.
  Future<void> lockAfi({required Set<Iso15693RequestFlag> requestFlags}) =>
      iosApi.iso15693LockAfi(_handle, _flags(requestFlags));

  /// Sets the data storage format identifier, 0-255.
  Future<void> writeDsfId({required Set<Iso15693RequestFlag> requestFlags, required int dsfId}) =>
      iosApi.iso15693WriteDsfId(_handle, _flags(requestFlags), dsfId);

  /// Locks the DSFID permanently.
  Future<void> lockDsfId({required Set<Iso15693RequestFlag> requestFlags}) =>
      iosApi.iso15693LockDsfId(_handle, _flags(requestFlags));

  /// Moves the tag back to the ready state, undoing [select] or [stayQuiet].
  Future<void> resetToReady({required Set<Iso15693RequestFlag> requestFlags}) =>
      iosApi.iso15693ResetToReady(_handle, _flags(requestFlags));

  /// Puts the tag in the selected state, so later commands need not carry its UID.
  Future<void> select({required Set<Iso15693RequestFlag> requestFlags}) =>
      iosApi.iso15693Select(_handle, _flags(requestFlags));

  /// Silences the tag until it leaves the field, so other tags can be reached.
  Future<void> stayQuiet() => iosApi.iso15693StayQuiet(_handle);

  /// As [readSingleBlock], for tags with more than 256 blocks.
  ///
  /// [blockNumber] is a two-byte address, 0-65535. Outside that it throws
  /// `PlatformException(code: 'invalidParameter')` without reaching the tag, as it does on
  /// [extendedWriteSingleBlock] and [extendedLockBlock].
  Future<Uint8List> extendedReadSingleBlock({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
  }) => iosApi.iso15693ExtendedReadSingleBlock(_handle, _flags(requestFlags), blockNumber);

  /// As [writeSingleBlock], for tags with more than 256 blocks. [blockNumber] is 0-65535.
  Future<void> extendedWriteSingleBlock({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required Uint8List dataBlock,
  }) => iosApi.iso15693ExtendedWriteSingleBlock(_handle, _flags(requestFlags), blockNumber, dataBlock);

  /// As [lockBlock], for tags with more than 256 blocks. [blockNumber] is 0-65535.
  Future<void> extendedLockBlock({required Set<Iso15693RequestFlag> requestFlags, required int blockNumber}) =>
      iosApi.iso15693ExtendedLockBlock(_handle, _flags(requestFlags), blockNumber);

  /// As [readMultipleBlocks], for tags with more than 256 blocks.
  Future<List<Uint8List>> extendedReadMultipleBlocks({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required int numberOfBlocks,
  }) => iosApi.iso15693ExtendedReadMultipleBlocks(_handle, _flags(requestFlags), blockNumber, numberOfBlocks);

  /// Reads the tag's own description: block size, block count, AFI and DSFID.
  ///
  /// Apple deprecated the selector behind this in iOS 14 and it reports no UID.
  @Deprecated(
    'Apple deprecated the underlying selector in iOS 14; use getSystemInfoAndUid, which also reports the UID.',
  )
  Future<Iso15693SystemInfo> getSystemInfo({required Set<Iso15693RequestFlag> requestFlags}) async =>
      _systemInfo(await iosApi.iso15693GetSystemInfo(_handle, _flags(requestFlags)));

  /// Sends a manufacturer-defined command. [customCommandCode] is 0xA0-0xDF.
  ///
  /// A code that is not a byte at all throws `PlatformException(code: 'invalidParameter')`
  /// without reaching the tag. Anything narrower is left to the tag: a code inside a byte but
  /// outside 0xA0-0xDF is not refused here, it is simply one no tag answers as a custom
  /// command -- [sendRequest] is the way to send those.
  Future<Uint8List> customCommand({
    required Set<Iso15693RequestFlag> requestFlags,
    required int customCommandCode,
    required Uint8List customRequestParameters,
  }) => iosApi.iso15693CustomCommand(_handle, _flags(requestFlags), customCommandCode, customRequestParameters);

  /// Sends any ISO 15693-3 request: the 8-bit request flag, an 8-bit command code, and the
  /// data the command takes, if it takes any.
  ///
  /// This is here because [customCommand] cannot reach a command code outside 0xA0-0xDF, and
  /// outside that window sits every ISO 15693-3 security command -- authenticate 0x35, key
  /// update 0x36, challenge 0x39, read buffer 0x3A -- along with the fast reads 0x2D and
  /// 0x3D. Until this existed those commands could not be sent from iOS through this package
  /// at all, while Android reached the same tag with them through `NfcV.transceive`. Reach
  /// for a typed method when there is one; this is for the commands that have none.
  ///
  /// [requestFlags] is the flag byte itself rather than a [Iso15693RequestFlag] set, because
  /// that is what CoreNFC takes here and the set cannot express bit 8, which each command
  /// defines for itself.
  ///
  /// The whole frame -- flag, command code and [data] together -- has to fit in 256 bytes.
  /// [requestFlags] and [commandCode] are each one byte, so a value outside 0-255 throws
  /// `PlatformException(code: 'invalidParameter')`. Raw does not mean unbounded: this call
  /// declines to interpret the two bytes, not to check that they are bytes.
  Future<Iso15693Response> sendRequest({required int requestFlags, required int commandCode, Uint8List? data}) async =>
      _response(await iosApi.iso15693SendRequest(_handle, requestFlags, commandCode, data));

  /// As [readMultipleBlocks], with the fast read command (0x2D), which the tag answers at
  /// double the data rate. Not every tag implements it.
  Future<List<Uint8List>> fastReadMultipleBlocks({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required int numberOfBlocks,
  }) => iosApi.iso15693FastReadMultipleBlocks(_handle, _flags(requestFlags), blockNumber, numberOfBlocks);

  /// As [fastReadMultipleBlocks] (0x3D), for tags with more than 256 blocks.
  Future<List<Uint8List>> extendedFastReadMultipleBlocks({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required int numberOfBlocks,
  }) => iosApi.iso15693ExtendedFastReadMultipleBlocks(_handle, _flags(requestFlags), blockNumber, numberOfBlocks);

  /// As [writeMultipleBlocks], for tags with more than 256 blocks. [dataBlocks] must hold
  /// [numberOfBlocks] entries, each one exactly the tag's block size.
  Future<void> extendedWriteMultipleBlocks({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required int numberOfBlocks,
    required List<Uint8List> dataBlocks,
  }) => iosApi.iso15693ExtendedWriteMultipleBlocks(
    _handle,
    _flags(requestFlags),
    blockNumber,
    numberOfBlocks,
    dataBlocks,
  );

  /// As [getMultipleBlockSecurityStatus], for tags with more than 256 blocks.
  Future<List<int>> extendedGetMultipleBlockSecurityStatus({
    required Set<Iso15693RequestFlag> requestFlags,
    required int blockNumber,
    required int numberOfBlocks,
  }) => iosApi.iso15693ExtendedGetMultipleBlockSecurityStatus(
    _handle,
    _flags(requestFlags),
    blockNumber,
    numberOfBlocks,
  );

  /// Authenticates against the tag (0x35), per ISO/IEC 29167.
  ///
  /// [cryptoSuiteIdentifier] picks the crypto suite, and the suite dictates what [message]
  /// has to contain; both go out untouched. The reply comes back untouched too, in-process
  /// replies included, which is what makes the response flag worth reading:
  /// [Iso15693ResponseFlag.finalResponse] is how a finished exchange is told apart from one
  /// still waiting for another round.
  ///
  /// [cryptoSuiteIdentifier] is one byte; outside 0-255 it throws
  /// `PlatformException(code: 'invalidParameter')`.
  Future<Iso15693Response> authenticate({
    required Set<Iso15693RequestFlag> requestFlags,
    required int cryptoSuiteIdentifier,
    required Uint8List message,
  }) async =>
      _response(await iosApi.iso15693Authenticate(_handle, _flags(requestFlags), cryptoSuiteIdentifier, message));

  /// Replaces the key [keyIdentifier] names (0x36).
  ///
  /// [message] follows the crypto suite the preceding [authenticate] agreed on, so this only
  /// means anything after one. [keyIdentifier] is one byte, refused outside 0-255 the way
  /// [authenticate] refuses a crypto suite that is not one.
  Future<Iso15693Response> keyUpdate({
    required Set<Iso15693RequestFlag> requestFlags,
    required int keyIdentifier,
    required Uint8List message,
  }) async => _response(await iosApi.iso15693KeyUpdate(_handle, _flags(requestFlags), keyIdentifier, message));

  /// Poses a challenge (0x39), which answers nothing on its own: the tag computes into its
  /// response buffer, and [readBuffer] is what collects the result.
  ///
  /// [cryptoSuiteIdentifier] is one byte, as in [authenticate].
  Future<void> challenge({
    required Set<Iso15693RequestFlag> requestFlags,
    required int cryptoSuiteIdentifier,
    required Uint8List message,
  }) => iosApi.iso15693Challenge(_handle, _flags(requestFlags), cryptoSuiteIdentifier, message);

  /// Reads whatever the tag left in its response buffer (0x3A), which is where [challenge]
  /// puts its answer.
  Future<Iso15693Response> readBuffer({required Set<Iso15693RequestFlag> requestFlags}) async =>
      _response(await iosApi.iso15693ReadBuffer(_handle, _flags(requestFlags)));

  /// Reads the tag's own description, [Iso15693SystemInfo.uid] included.
  ///
  /// This is `getSystemInfoAndUIDWithRequestFlag:`, which Apple added in iOS 14 to replace
  /// the selector [getSystemInfo] calls. Same command on the wire (0x2B); the difference is
  /// that this one hands back the UID the tag sent with the rest.
  Future<Iso15693SystemInfo> getSystemInfoAndUid({required Set<Iso15693RequestFlag> requestFlags}) async =>
      _systemInfo(await iosApi.iso15693GetSystemInfoAndUid(_handle, _flags(requestFlags)));

  /// As [readMultipleBlocks], except CoreNFC cuts the range into requests of [chunkSize]
  /// blocks and retries each one per [configuration] without coming back to Dart in between.
  /// The tag's hardware caps how large a chunk it will answer.
  ///
  /// [chunkSize] is a number of blocks and has to be at least one; so does [numberOfBlocks],
  /// and [blockNumber] cannot be negative. A range or a chunk outside that throws
  /// `PlatformException(code: 'invalidParameter')` without reaching the tag.
  ///
  /// CoreNFC files this among its legacy ISO 15693 calls, which want the
  /// `com.apple.developer.nfc.readersession.iso15693.tag-identifiers` entitlement -- Apple
  /// grants it on request only -- and Apple's own header says a tag delivered by an
  /// `NFCTagReaderSession`, which is the session this package starts, answers
  /// `unsupportedFeature`. Expect that unless your app is provisioned for the legacy reader
  /// session; [readMultipleBlocks] is the route that always works.
  Future<List<Uint8List>> readMultipleBlocksWithConfiguration({
    required int blockNumber,
    required int numberOfBlocks,
    required int chunkSize,
    required Iso15693CommandConfiguration configuration,
  }) => iosApi.iso15693ReadMultipleBlocksWithConfiguration(
    _handle,
    blockNumber,
    numberOfBlocks,
    chunkSize,
    configuration._toWire(),
  );

  /// As [customCommand], with the retries [configuration] asks for and an explicit
  /// [manufacturerCode] in place of the tag's own [icManufacturerCode].
  ///
  /// Carries the same legacy-entitlement caveat as [readMultipleBlocksWithConfiguration], so
  /// [customCommand] is the route that always works.
  ///
  /// [manufacturerCode] and [customCommandCode] must each fit a byte -- Apple documents them
  /// as 0x00-0xFF and 0xA0-0xDF -- and are refused the same way [customCommand] refuses a
  /// code that is not one.
  Future<Uint8List> customCommandWithConfiguration({
    required int manufacturerCode,
    required int customCommandCode,
    required Uint8List customRequestParameters,
    required Iso15693CommandConfiguration configuration,
  }) => iosApi.iso15693CustomCommandWithConfiguration(
    _handle,
    manufacturerCode,
    customCommandCode,
    customRequestParameters,
    configuration._toWire(),
  );

  static Iso15693SystemInfo _systemInfo(Iso15693SystemInfoPigeon info) => Iso15693SystemInfo(
    applicationFamilyIdentifier: info.applicationFamilyIdentifier,
    blockSize: info.blockSize,
    dataStorageFormatIdentifier: info.dataStorageFormatIdentifier,
    icReference: info.icReference,
    totalBlocks: info.totalBlocks,
    uid: info.uid,
  );

  static Iso15693Response _response(Iso15693ResponsePigeon response) => Iso15693Response(
    flags: {
      for (final flag in response.flags)
        switch (flag) {
          Iso15693ResponseFlagPigeon.error => Iso15693ResponseFlag.error,
          Iso15693ResponseFlagPigeon.responseBufferValid => Iso15693ResponseFlag.responseBufferValid,
          Iso15693ResponseFlagPigeon.finalResponse => Iso15693ResponseFlag.finalResponse,
          Iso15693ResponseFlagPigeon.protocolExtension => Iso15693ResponseFlag.protocolExtension,
          Iso15693ResponseFlagPigeon.blockSecurityStatusBit5 => Iso15693ResponseFlag.blockSecurityStatusBit5,
          Iso15693ResponseFlagPigeon.blockSecurityStatusBit6 => Iso15693ResponseFlag.blockSecurityStatusBit6,
          Iso15693ResponseFlagPigeon.waitTimeExtension => Iso15693ResponseFlag.waitTimeExtension,
        },
    },
    data: response.data,
  );

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

  /// The card's historical bytes, when it reported any.
  final Uint8List? historicalBytes;

  /// The application data from the FCI template, when the card reported any.
  final Uint8List? applicationData;

  /// Whether [applicationData] is encoded proprietarily rather than per ISO 7816-4.
  final bool proprietaryApplicationDataCoding;

  /// Sends a command APDU assembled from its fields.
  ///
  /// The four header fields are each one byte. [expectedResponseLength] is the Le field:
  /// 1-65536, or -1 for a command that expects no response data. Zero is not a way to say
  /// that, and anything else throws `PlatformException(code: 'invalidParameter')`.
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

  /// Which Mifare product this is, as far as CoreNFC could tell.
  final MiFareFamily family;

  /// The historical bytes, for a DESFire card that reported any. Null otherwise.
  final Uint8List? historicalBytes;

  /// Sends a native Mifare command.
  Future<Uint8List> sendMiFareCommand(Uint8List commandPacket) => iosApi.mifareSendCommand(_handle, commandPacket);

  /// Sends an ISO 7816 command APDU assembled from its fields.
  ///
  /// The fields are bounded as on [Iso7816.sendCommand]: four one-byte header fields, and an
  /// [expectedResponseLength] of 1-65536 or -1 for a command that expects no response data.
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
