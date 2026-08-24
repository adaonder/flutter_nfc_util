import 'dart:typed_data';

import '../pigeon.g.dart';

/// The cross-platform half of the platform side, answering without a channel.
///
/// What it stands in for is a device with NFC switched on and a tag with nothing written on
/// it: availability reads enabled, the session calls succeed quietly, and a read comes back
/// null.
///
/// Subclass it and override only the calls a test asserts on -- the generated class is
/// concrete and its methods are overridable, which is what makes this possible at all. The
/// rest keep answering, so a test about session lifecycle never has to describe NDEF, and one
/// about NDEF never has to describe a session.
class FakeNfcHostApi extends NfcHostApi {
  @override
  Future<AvailabilityPigeon> checkAvailability() async => AvailabilityPigeon.enabled;

  @override
  Future<void> startSession(SessionConfigPigeon config) async {}

  @override
  Future<void> stopSession(String? alertMessage, String? errorMessage) async {}

  @override
  Future<void> disposeTag(String handle) async {}

  // Null is how both platforms report a tag with nothing written on it, so this is an
  // answer rather than a hole: a caller that treats it as a failure is the bug.
  @override
  Future<NdefMessagePigeon?> ndefRead(String handle) async => null;

  @override
  Future<void> ndefWrite(String handle, NdefMessagePigeon message) async {}

  @override
  Future<void> ndefWriteLock(String handle) async {}
}

/// The Android half of the platform side, answering without a channel.
///
/// It stands in for the oldest phone this package runs on: an API 24 device with NFC switched
/// on. Every capability that arrived later answers false, and the two switches that do not
/// exist on such a phone -- the reader option and the tag intent preference -- answer true,
/// because that is what their own accessors report when the platform has no such switch.
/// False there would tell a test the user had turned something off.
///
/// It is a phone rather than a tag, though: the calls that address a tag succeed and hand
/// back an answer of the right shape and no content.
class FakeNfcAndroidHostApi extends NfcAndroidHostApi {
  @override
  Future<bool> isEnabled() async => true;

  @override
  Future<bool> isSecureNfcSupported() async => false;

  @override
  Future<bool> isSecureNfcEnabled() async => false;

  @override
  Future<bool> isReaderOptionSupported() async => false;

  @override
  Future<bool> isReaderOptionEnabled() async => true;

  // Nothing was opened, and saying otherwise would let a test pass while asserting that
  // the user had been sent somewhere.
  @override
  Future<bool> openNfcSettings() async => false;

  @override
  Future<void> enableReaderMode(List<ReaderFlagPigeon> flags, int presenceCheckDelayMillis) async {}

  @override
  Future<void> disableReaderMode() async {}

  @override
  Future<void> enableForegroundDispatch() async {}

  @override
  Future<void> disableForegroundDispatch() async {}

  @override
  Future<TagPigeon?> takeInitialTag() async => null;

  @override
  Future<void> setDiscoveryTechnology(List<PollTechPigeon> poll, List<ListenTechPigeon> listen) async {}

  @override
  Future<void> resetDiscoveryTechnology() async {}

  @override
  Future<NfcAntennaInfoPigeon?> getAntennaInfo() async => null;

  @override
  Future<bool> isTagIntentAppPreferenceSupported() async => false;

  @override
  Future<bool> isTagIntentAllowed() async => true;

  @override
  Future<bool> openTagIntentPreferenceSettings() async => false;

  @override
  Future<TagIntentSetupPigeon> checkTagIntentSetup() async => TagIntentSetupPigeon(
    dispatchPermissionRequired: false,
    unguardedActivities: const [],
    tagIntentAllowed: true,
    tagIntentPreferenceSupported: false,
  );

  @override
  Future<Uint8List> transceive(String handle, AndroidTechPigeon tech, Uint8List data) async => Uint8List(0);

  // Non-zero on purpose. A zero maximum turns a caller's chunking loop into an endless
  // one, which is a baffling way to discover that a call was never overridden.
  @override
  Future<int> getMaxTransceiveLength(String handle, AndroidTechPigeon tech) async => 253;

  @override
  Future<int> getTimeout(String handle, AndroidTechPigeon tech) async => 618;

  @override
  Future<void> setTimeout(String handle, AndroidTechPigeon tech, int timeout) async {}

  @override
  Future<void> resetTech(String handle, AndroidTechPigeon tech) async {}

  // The fake holds no keys, so it cannot honestly say one is wrong. A test about a wrong
  // key -- which is the interesting case, since it is what `reset` exists for -- says so
  // by overriding this.
  @override
  Future<bool> mifareClassicAuthenticateSector(String handle, int sectorIndex, Uint8List key, bool useKeyA) async =>
      true;

  // A block is sixteen bytes. The content is nothing, but the length is what code that slices
  // the answer up needs, and a zero-length one would have it read past the end instead.
  @override
  Future<Uint8List> mifareClassicReadBlock(String handle, int blockIndex) async => Uint8List(16);

  @override
  Future<void> mifareClassicWriteBlock(String handle, int blockIndex, Uint8List data) async {}

  @override
  Future<void> mifareClassicIncrement(String handle, int blockIndex, int value) async {}

  @override
  Future<void> mifareClassicDecrement(String handle, int blockIndex, int value) async {}

  @override
  Future<void> mifareClassicRestore(String handle, int blockIndex) async {}

  @override
  Future<void> mifareClassicTransfer(String handle, int blockIndex) async {}

  // The geometry of a 1K card, four blocks to a sector, which is what `FakeTech.mifareClassic`
  // describes by default. The two agree so a test does not have to reconcile them.
  @override
  Future<int> mifareClassicBlockToSector(String handle, int blockIndex) async => blockIndex ~/ 4;

  @override
  Future<int> mifareClassicSectorToBlock(String handle, int sectorIndex) async => sectorIndex * 4;

  @override
  Future<int> mifareClassicBlockCountInSector(String handle, int sectorIndex) async => 4;

  // Four pages of four bytes, which is what one read of an Ultralight hands back.
  @override
  Future<Uint8List> mifareUltralightReadPages(String handle, int pageOffset) async => Uint8List(16);

  @override
  Future<void> mifareUltralightWritePage(String handle, int pageOffset, Uint8List data) async {}

  @override
  Future<void> ndefFormat(String handle, NdefMessagePigeon firstMessage, bool readOnly) async {}

  // Host card emulation is API 19, so the phone this stands in for has it. The observe-mode
  // and polling-loop calls further down are API 35 and answer accordingly.
  @override
  Future<bool> hceIsSupported() async => true;

  @override
  Future<bool> hceRegisterAids(List<String> aids) async => true;

  @override
  Future<bool> hceUnregisterAids() async => true;

  @override
  Future<void> hceRespond(Uint8List response) async {}

  @override
  Future<void> hceSetPreferredService(bool preferred) async {}

  @override
  Future<bool> hceSupportsAidPrefixRegistration() async => false;

  @override
  Future<bool> hceCategoryAllowsForegroundPreference(CardEmulationCategoryPigeon category) async => false;

  @override
  Future<AidSelectionModePigeon> hceSelectionModeForCategory(CardEmulationCategoryPigeon category) async =>
      AidSelectionModePigeon.preferDefault;

  @override
  Future<bool> hceIsDefaultServiceForCategory(CardEmulationCategoryPigeon category) async => false;

  @override
  Future<bool> hceIsDefaultServiceForAid(String aid) async => false;

  @override
  Future<List<String>> hceAidsForService(CardEmulationCategoryPigeon category) async => const [];

  @override
  Future<bool> hceIsObserveModeSupported() async => false;

  @override
  Future<bool> hceIsObserveModeEnabled() async => false;

  @override
  Future<bool> hceSetObserveModeEnabled(bool enabled) async => false;

  @override
  Future<bool> hceSetDefaultToObserveMode(bool shouldDefault) async => false;

  @override
  Future<bool> hceRegisterPollingLoopFilter(String filter, bool autoTransact) async => false;

  @override
  Future<bool> hceRegisterPollingLoopPatternFilter(String pattern, bool autoTransact) async => false;

  @override
  Future<bool> hceRemovePollingLoopFilter(String filter) async => false;

  @override
  Future<bool> hceRemovePollingLoopPatternFilter(String pattern) async => false;

  @override
  Future<bool> enableNfcEvents() async => false;

  @override
  Future<void> disableNfcEvents() async {}
}

/// The iOS half of the platform side, answering without a channel.
///
/// It stands in for an iPhone that can read tags, holding a tag that accepts every command
/// and reports nothing of its own: status words are `9000`, FeliCa status flags are zero, and
/// the block reads hand back as many empty blocks as were asked for.
///
/// That last part is the one worth knowing. A caller that pairs the answer up with the block
/// numbers it requested gets a list of the length it expects, so the loop under test runs the
/// number of times the test intended rather than none.
class FakeNfcIosHostApi extends NfcIosHostApi {
  @override
  Future<bool> tagSessionReadingAvailable() async => true;

  @override
  Future<bool> tagIsAvailable(String handle) async => true;

  @override
  Future<void> tagSessionSetAlertMessage(String alertMessage) async {}

  @override
  Future<void> tagSessionRestartPolling() async {}

  @override
  Future<bool> vasSessionReadingAvailable() async => true;

  @override
  Future<void> vasSessionBegin(List<VasCommandConfigurationPigeon> configurations, String? alertMessage) async {}

  @override
  Future<void> vasSessionInvalidate(String? alertMessage, String? errorMessage) async {}

  @override
  Future<void> vasSessionSetAlertMessage(String alertMessage) async {}

  // A capacity a real tag might have, rather than zero, which would make every write the
  // caller attempts look too large for the tag.
  @override
  Future<QueryNdefStatusResponsePigeon> ndefQueryStatus(String handle) async =>
      QueryNdefStatusResponsePigeon(status: NdefStatusPigeon.readWrite, capacity: 492);

  @override
  Future<NdefMessagePigeon?> takeInitialNdefMessage() async => null;

  @override
  Future<FeliCaPollingResponsePigeon> felicaPolling(
    String handle,
    Uint8List systemCode,
    FeliCaPollingRequestCodePigeon requestCode,
    FeliCaPollingTimeSlotPigeon timeSlot,
  ) async => FeliCaPollingResponsePigeon(manufacturerParameter: Uint8List(0), requestData: Uint8List(0));

  @override
  Future<int> felicaRequestResponse(String handle) async => 0;

  @override
  Future<List<Uint8List>> felicaRequestSystemCode(String handle) async => const [];

  @override
  Future<List<Uint8List>> felicaRequestService(String handle, List<Uint8List> nodeCodeList) async => const [];

  @override
  Future<FeliCaRequestServiceV2ResponsePigeon> felicaRequestServiceV2(
    String handle,
    List<Uint8List> nodeCodeList,
  ) async => FeliCaRequestServiceV2ResponsePigeon(statusFlag1: 0, statusFlag2: 0, encryptionIdentifier: 0);

  @override
  Future<FeliCaReadWithoutEncryptionResponsePigeon> felicaReadWithoutEncryption(
    String handle,
    List<Uint8List> serviceCodeList,
    List<Uint8List> blockList,
  ) async => FeliCaReadWithoutEncryptionResponsePigeon(
    statusFlag1: 0,
    statusFlag2: 0,
    blockData: List.generate(blockList.length, (_) => Uint8List(16)),
  );

  @override
  Future<FeliCaStatusFlagPigeon> felicaWriteWithoutEncryption(
    String handle,
    List<Uint8List> serviceCodeList,
    List<Uint8List> blockList,
    List<Uint8List> blockData,
  ) async => FeliCaStatusFlagPigeon(statusFlag1: 0, statusFlag2: 0);

  @override
  Future<FeliCaRequestSpecificationVersionResponsePigeon> felicaRequestSpecificationVersion(String handle) async =>
      FeliCaRequestSpecificationVersionResponsePigeon(statusFlag1: 0, statusFlag2: 0);

  @override
  Future<FeliCaStatusFlagPigeon> felicaResetMode(String handle) async =>
      FeliCaStatusFlagPigeon(statusFlag1: 0, statusFlag2: 0);

  @override
  Future<Uint8List> felicaSendCommand(String handle, Uint8List commandPacket) async => Uint8List(0);

  @override
  Future<Uint8List> iso15693ReadSingleBlock(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
  ) async => Uint8List(4);

  @override
  Future<void> iso15693WriteSingleBlock(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    Uint8List dataBlock,
  ) async {}

  @override
  Future<void> iso15693LockBlock(String handle, List<Iso15693RequestFlagPigeon> flags, int blockNumber) async {}

  @override
  Future<List<Uint8List>> iso15693ReadMultipleBlocks(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
  ) async => _blocks(numberOfBlocks);

  @override
  Future<void> iso15693WriteMultipleBlocks(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
    List<Uint8List> dataBlocks,
  ) async {}

  @override
  Future<List<int>> iso15693GetMultipleBlockSecurityStatus(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
  ) async => List.filled(numberOfBlocks, 0);

  @override
  Future<void> iso15693WriteAfi(String handle, List<Iso15693RequestFlagPigeon> flags, int afi) async {}

  @override
  Future<void> iso15693LockAfi(String handle, List<Iso15693RequestFlagPigeon> flags) async {}

  @override
  Future<void> iso15693WriteDsfId(String handle, List<Iso15693RequestFlagPigeon> flags, int dsfId) async {}

  @override
  Future<void> iso15693LockDsfId(String handle, List<Iso15693RequestFlagPigeon> flags) async {}

  @override
  Future<void> iso15693ResetToReady(String handle, List<Iso15693RequestFlagPigeon> flags) async {}

  @override
  Future<void> iso15693Select(String handle, List<Iso15693RequestFlagPigeon> flags) async {}

  @override
  Future<void> iso15693StayQuiet(String handle) async {}

  @override
  Future<Uint8List> iso15693ExtendedReadSingleBlock(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
  ) async => Uint8List(4);

  @override
  Future<void> iso15693ExtendedWriteSingleBlock(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    Uint8List dataBlock,
  ) async {}

  @override
  Future<void> iso15693ExtendedLockBlock(String handle, List<Iso15693RequestFlagPigeon> flags, int blockNumber) async {}

  @override
  Future<List<Uint8List>> iso15693ExtendedReadMultipleBlocks(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
  ) async => _blocks(numberOfBlocks);

  @override
  Future<Iso15693SystemInfoPigeon> iso15693GetSystemInfo(String handle, List<Iso15693RequestFlagPigeon> flags) async =>
      _systemInfo(null);

  @override
  Future<Uint8List> iso15693CustomCommand(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int customCommandCode,
    Uint8List customRequestParameters,
  ) async => Uint8List(0);

  @override
  Future<Iso15693ResponsePigeon> iso15693SendRequest(
    String handle,
    int flags,
    int commandCode,
    Uint8List? data,
  ) async => _response();

  @override
  Future<List<Uint8List>> iso15693FastReadMultipleBlocks(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
  ) async => _blocks(numberOfBlocks);

  @override
  Future<List<Uint8List>> iso15693ExtendedFastReadMultipleBlocks(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
  ) async => _blocks(numberOfBlocks);

  @override
  Future<void> iso15693ExtendedWriteMultipleBlocks(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
    List<Uint8List> dataBlocks,
  ) async {}

  @override
  Future<List<int>> iso15693ExtendedGetMultipleBlockSecurityStatus(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
  ) async => List.filled(numberOfBlocks, 0);

  @override
  Future<Iso15693ResponsePigeon> iso15693Authenticate(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int cryptoSuiteIdentifier,
    Uint8List message,
  ) async => _response();

  @override
  Future<Iso15693ResponsePigeon> iso15693KeyUpdate(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int keyIdentifier,
    Uint8List message,
  ) async => _response();

  @override
  Future<void> iso15693Challenge(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int cryptoSuiteIdentifier,
    Uint8List message,
  ) async {}

  @override
  Future<Iso15693ResponsePigeon> iso15693ReadBuffer(String handle, List<Iso15693RequestFlagPigeon> flags) async =>
      _response();

  // With a UID, since that is the whole reason this call exists beside `iso15693GetSystemInfo`;
  // answering null here would defeat the only test worth writing against it.
  @override
  Future<Iso15693SystemInfoPigeon> iso15693GetSystemInfoAndUid(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
  ) async => _systemInfo(Uint8List(8));

  @override
  Future<List<Uint8List>> iso15693ReadMultipleBlocksWithConfiguration(
    String handle,
    int blockNumber,
    int numberOfBlocks,
    int chunkSize,
    Iso15693CommandConfigurationPigeon configuration,
  ) async => _blocks(numberOfBlocks);

  @override
  Future<Uint8List> iso15693CustomCommandWithConfiguration(
    String handle,
    int manufacturerCode,
    int customCommandCode,
    Uint8List customRequestParameters,
    Iso15693CommandConfigurationPigeon configuration,
  ) async => Uint8List(0);

  @override
  Future<Iso7816ResponseApduPigeon> iso7816SendCommand(
    String handle,
    int instructionClass,
    int instructionCode,
    int p1Parameter,
    int p2Parameter,
    Uint8List data,
    int expectedResponseLength,
  ) async => _apdu();

  @override
  Future<Iso7816ResponseApduPigeon> iso7816SendCommandRaw(String handle, Uint8List data) async => _apdu();

  @override
  Future<Uint8List> mifareSendCommand(String handle, Uint8List commandPacket) async => Uint8List(0);

  @override
  Future<Iso7816ResponseApduPigeon> mifareSendIso7816Command(
    String handle,
    int instructionClass,
    int instructionCode,
    int p1Parameter,
    int p2Parameter,
    Uint8List data,
    int expectedResponseLength,
  ) async => _apdu();

  @override
  Future<Iso7816ResponseApduPigeon> mifareSendIso7816CommandRaw(String handle, Uint8List data) async => _apdu();
}

// A read of `count` blocks, each an ISO 15693 block of four bytes. Generated rather than
// filled, so a test that mutates one block does not quietly change all of them.
List<Uint8List> _blocks(int count) => List.generate(count, (_) => Uint8List(4));

// `9000`, so `Iso7816ResponseApdu.isSuccess` and a `StatusWord` check both pass. A test about
// a card that refuses says which status word it refuses with.
Iso7816ResponseApduPigeon _apdu() =>
    Iso7816ResponseApduPigeon(payload: Uint8List(0), statusWord1: 0x90, statusWord2: 0x00);

// No response flags at all, which is a tag reporting that nothing went wrong -- the error bit
// is the one that would matter, and it is clear.
Iso15693ResponsePigeon _response() => Iso15693ResponsePigeon(flags: const [], data: Uint8List(0));

// A 64-block tag with four-byte blocks, the size `_blocks` hands back, so a caller that sizes
// its read from the system information gets blocks of the size it was promised.
Iso15693SystemInfoPigeon _systemInfo(Uint8List? uid) => Iso15693SystemInfoPigeon(
  applicationFamilyIdentifier: 0,
  blockSize: 4,
  dataStorageFormatIdentifier: 0,
  icReference: 0,
  totalBlocks: 64,
  uid: uid,
);
