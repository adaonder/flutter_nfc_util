import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_util/android.dart';
import 'package:nfc_util/nfc_util.dart';
import 'package:nfc_util/src/api.dart';
import 'package:nfc_util/src/pigeon.g.dart';

/// A stand-in Android host, so the capability surface can be exercised without a device.
///
/// Every method here answers the way a device that is *too old* would, unless a test says
/// otherwise. That is the case worth defaulting to: the plugin supports API 24 upwards,
/// and most of what this file covers arrived in API 34 or later, so "the phone cannot do
/// this" is the common answer rather than the exceptional one.
class _FakeAndroidHost extends NfcAndroidHostApi {
  NfcAntennaInfoPigeon? antennaInfo;
  TagIntentSetupPigeon setup = TagIntentSetupPigeon(
    dispatchPermissionRequired: false,
    unguardedActivities: const [],
    tagIntentAllowed: true,
    tagIntentPreferenceSupported: false,
  );

  bool observeModeSupported = false;
  bool observeModeEnabled = false;
  bool observeModeAccepted = false;
  bool? lastObserveModeRequest;

  bool tagIntentSupported = false;
  bool tagIntentAllowed = true;
  bool settingsOpened = false;

  bool readerOptionSupported = false;
  bool readerOptionEnabled = true;
  bool nfcSettingsScreenExists = true;
  bool nfcSettingsOpened = false;

  bool eventsEnabled = false;
  int enableEventsCount = 0;
  int disableEventsCount = 0;

  List<PollTechPigeon>? lastPoll;
  List<ListenTechPigeon>? lastListen;
  int resetDiscoveryCount = 0;

  String? lastFilter;
  bool? lastAutoTransact;
  String? lastRemovedFilter;

  /// Thrown by every version-gated call when set, standing in for a device below the
  /// minimum API level.
  Object? tooOld;

  @override
  Future<void> setDiscoveryTechnology(List<PollTechPigeon> poll, List<ListenTechPigeon> listen) async {
    if (tooOld != null) throw tooOld!;
    lastPoll = poll;
    lastListen = listen;
  }

  @override
  Future<void> resetDiscoveryTechnology() async {
    if (tooOld != null) throw tooOld!;
    resetDiscoveryCount++;
  }

  @override
  Future<NfcAntennaInfoPigeon?> getAntennaInfo() async => antennaInfo;

  @override
  Future<bool> isTagIntentAppPreferenceSupported() async => tagIntentSupported;

  @override
  Future<bool> isTagIntentAllowed() async => tagIntentAllowed;

  @override
  Future<bool> openTagIntentPreferenceSettings() async {
    settingsOpened = true;
    return tagIntentSupported;
  }

  @override
  Future<bool> isReaderOptionSupported() async => readerOptionSupported;

  @override
  Future<bool> isReaderOptionEnabled() async => readerOptionEnabled;

  @override
  Future<bool> openNfcSettings() async {
    nfcSettingsOpened = true;
    return nfcSettingsScreenExists;
  }

  @override
  Future<TagIntentSetupPigeon> checkTagIntentSetup() async => setup;

  @override
  Future<bool> hceIsObserveModeSupported() async => observeModeSupported;

  @override
  Future<bool> hceIsObserveModeEnabled() async => observeModeEnabled;

  @override
  Future<bool> hceSetObserveModeEnabled(bool enabled) async {
    if (tooOld != null) throw tooOld!;
    lastObserveModeRequest = enabled;
    if (!observeModeAccepted) return false;
    observeModeEnabled = enabled;
    return true;
  }

  @override
  Future<bool> hceRegisterPollingLoopFilter(String filter, bool autoTransact) async {
    if (tooOld != null) throw tooOld!;
    lastFilter = filter;
    lastAutoTransact = autoTransact;
    return true;
  }

  @override
  Future<bool> hceRemovePollingLoopFilter(String filter) async {
    lastRemovedFilter = filter;
    return true;
  }

  @override
  Future<bool> enableNfcEvents() async {
    enableEventsCount++;
    return eventsEnabled;
  }

  @override
  Future<void> disableNfcEvents() async => disableEventsCount++;
}

/// Delivers a platform-to-Dart event the way the native side would, through the same codec
/// the real channel uses.
Future<void> _deliver(String method, Object? argument) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    'dev.flutter.pigeon.nfc_util.NfcFlutterApi.$method',
    NfcHostApi.pigeonChannelCodec.encodeMessage(<Object?>[argument]),
    (_) {},
  );
}

/// The refusal every capability added after API 24 raises on a device that is too old.
PlatformException get _unsupported =>
    PlatformException(code: 'unsupported_api_level', message: 'needs Android API 35; this device is 30.');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAndroidHost host;
  late void Function() restore;

  setUp(() {
    host = _FakeAndroidHost();
    restore = debugReplaceApis(android: host);
  });

  tearDown(() => restore());

  group('capability probes', () {
    test('answer false on a device too old to have the capability at all', () async {
      // The whole contract in one test: a probe never throws, so an app can ask before it
      // decides what UI to show. Only the *actions* refuse.
      expect(await HostCardEmulation.instance.isObserveModeSupported(), isFalse);
      expect(await HostCardEmulation.instance.isObserveModeEnabled(), isFalse);
      expect(await NfcUtilAndroid.instance.isTagIntentAppPreferenceSupported(), isFalse);
      expect(await NfcUtilAndroid.instance.getAntennaInfo(), isNull);
    });

    test('tag intent scanning reads as allowed where there is no allowlist to be off', () async {
      // False has to mean "the user said no". A device with no allowlist reporting false
      // would send an app to a settings screen that does not exist.
      expect(await NfcUtilAndroid.instance.isTagIntentAllowed(), isTrue);
    });
  });

  group('the reader option', () {
    test('reads as on where there is no such switch to be off', () async {
      // The same shape as the tag intent allowlist, and for the same reason: false has to
      // mean the user turned reading off. A phone below API 35 reporting false would send an
      // app to a switch that is not on it.
      expect(await NfcUtilAndroid.instance.isReaderOptionSupported(), isFalse);
      expect(await NfcUtilAndroid.instance.isReaderOptionEnabled(), isTrue);
    });

    test('false is the user having turned tag reading off', () async {
      // The failure this exists to explain: the adapter is on, startSession succeeds, and no
      // tag is ever discovered. Nothing else in the capability surface answers that.
      host.readerOptionSupported = true;
      host.readerOptionEnabled = false;

      expect(await NfcUtilAndroid.instance.isReaderOptionSupported(), isTrue);
      expect(await NfcUtilAndroid.instance.isReaderOptionEnabled(), isFalse);
    });

    test('the settings screen is opened, not the switch flipped', () async {
      // Nothing here can turn the option back on; all an app can do is take the user to it.
      expect(await NfcUtilAndroid.instance.openNfcSettings(), isTrue);
      expect(host.nfcSettingsOpened, isTrue);
    });

    test('a device with no such screen says so rather than throwing', () async {
      host.nfcSettingsScreenExists = false;

      expect(await NfcUtilAndroid.instance.openNfcSettings(), isFalse);
    });
  });

  group('actions on a device that is too old', () {
    test('surface unsupported_api_level rather than doing nothing', () async {
      host.tooOld = _unsupported;

      // A silent no-op is what turns this into "the feature does nothing on my phone",
      // reported months later by someone else's user.
      await expectLater(
        HostCardEmulation.instance.setObserveModeEnabled(true),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'unsupported_api_level')),
      );
      await expectLater(
        NfcUtilAndroid.instance.setDiscoveryTechnology(poll: {NfcPollTech.nfcA}, listen: {NfcListenTech.disable}),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'unsupported_api_level')),
      );
      await expectLater(
        NfcUtilAndroid.instance.resetDiscoveryTechnology(),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'unsupported_api_level')),
      );
    });
  });

  group('discovery technology', () {
    test('passes both technology sets through', () async {
      await NfcUtilAndroid.instance.setDiscoveryTechnology(
        poll: {NfcPollTech.nfcA, NfcPollTech.nfcV},
        listen: {NfcListenTech.nfcF},
      );

      expect(host.lastPoll, containsAll([PollTechPigeon.nfcA, PollTechPigeon.nfcV]));
      expect(host.lastListen, [ListenTechPigeon.nfcF]);
    });

    test('an empty listen set is passed through rather than rejected', () async {
      // Unlike enableReaderMode, empty is meaningful here: it is how an app stops the phone
      // answering readers while it is on screen.
      await NfcUtilAndroid.instance.setDiscoveryTechnology(poll: {NfcPollTech.keep}, listen: {});

      expect(host.lastPoll, [PollTechPigeon.keep]);
      expect(host.lastListen, isEmpty);
    });

    test('reset reaches the platform', () async {
      await NfcUtilAndroid.instance.resetDiscoveryTechnology();
      expect(host.resetDiscoveryCount, 1);
    });
  });

  group('antenna info', () {
    test('maps the geometry the platform reports', () async {
      host.antennaInfo = NfcAntennaInfoPigeon(
        deviceWidth: 71,
        deviceHeight: 147,
        deviceFoldable: false,
        availableNfcAntennas: [AvailableNfcAntennaPigeon(locationX: 35, locationY: 40)],
      );

      final info = await NfcUtilAndroid.instance.getAntennaInfo();

      expect(info, isNotNull);
      expect(info!.deviceWidth, 71);
      expect(info.deviceHeight, 147);
      expect(info.deviceFoldable, isFalse);
      expect(info.antennas.single.x, 35);
      expect(info.antennas.single.y, 40);
    });
  });

  group('tag intent setup', () {
    test('reports a healthy setup as healthy', () async {
      final setup = await NfcUtilAndroid.instance.checkTagIntentSetup();

      expect(setup.isHealthy, isTrue);
      expect(setup.dispatchPermissionRequired, isFalse);
      expect(setup.unguardedActivities, isEmpty);
    });

    test('an activity missing DISPATCH_NFC_MESSAGE is not healthy', () async {
      host.setup = TagIntentSetupPigeon(
        dispatchPermissionRequired: true,
        unguardedActivities: const ['.MainActivity'],
        tagIntentAllowed: true,
        tagIntentPreferenceSupported: true,
      );

      final setup = await NfcUtilAndroid.instance.checkTagIntentSetup();

      expect(setup.isHealthy, isFalse);
      expect(setup.unguardedActivities, ['.MainActivity']);
    });

    test('a user who switched the app off the allowlist is not healthy either', () async {
      host.setup = TagIntentSetupPigeon(
        dispatchPermissionRequired: false,
        unguardedActivities: const [],
        tagIntentAllowed: false,
        tagIntentPreferenceSupported: true,
      );

      expect((await NfcUtilAndroid.instance.checkTagIntentSetup()).isHealthy, isFalse);
    });
  });

  group('card-emulation events', () {
    test('the stream is broadcast, so a second listener is not refused', () async {
      final first = NfcUtilAndroid.instance.onNfcEvent.listen((_) {});
      final second = NfcUtilAndroid.instance.onNfcEvent.listen((_) {});

      addTearDown(first.cancel);
      addTearDown(second.cancel);
    });

    test('registration is explicit and reports what the device can do', () async {
      expect(await NfcUtilAndroid.instance.enableNfcEvents(), isFalse);

      host.eventsEnabled = true;
      expect(await NfcUtilAndroid.instance.enableNfcEvents(), isTrue);
      expect(host.enableEventsCount, 2);

      await NfcUtilAndroid.instance.disableNfcEvents();
      expect(host.disableEventsCount, 1);
    });

    test('events arrive with the fields their kind implies', () async {
      final received = <NfcEvent>[];
      final subscription = NfcUtilAndroid.instance.onNfcEvent.listen(received.add);
      addTearDown(subscription.cancel);

      await _deliver('onNfcEvent', NfcEventPigeon(kind: NfcEventKindPigeon.aidNotRouted, aid: 'F0010203040506'));
      await _deliver(
        'onNfcEvent',
        NfcEventPigeon(kind: NfcEventKindPigeon.nfcStateChanged, adapterState: AdapterStatePigeon.turningOff),
      );
      await _deliver(
        'onNfcEvent',
        NfcEventPigeon(kind: NfcEventKindPigeon.internalError, internalError: NfcInternalErrorPigeon.commandTimeout),
      );

      expect(received, hasLength(3));
      expect(received[0].kind, NfcEventKind.aidNotRouted);
      expect(received[0].aid, 'F0010203040506');
      expect(received[0].adapterState, isNull);
      expect(received[1].kind, NfcEventKind.nfcStateChanged);
      expect(received[1].adapterState, NfcAdapterState.turningOff);
      expect(received[2].internalError, NfcInternalError.commandTimeout);
    });
  });
}
