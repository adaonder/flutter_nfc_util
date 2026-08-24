import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_util/android.dart';
import 'package:nfc_util/src/api.dart';
import 'package:nfc_util/src/pigeon.g.dart';

/// A stand-in Android host for the emulation paths.
class _FakeAndroidHost extends NfcAndroidHostApi {
  bool observeModeAccepted = true;
  bool? lastObserveModeRequest;
  bool? lastShouldDefault;

  bool prefixRegistration = false;
  bool foregroundPreference = false;
  bool defaultForCategory = false;
  bool defaultForAid = false;
  AidSelectionModePigeon selectionMode = AidSelectionModePigeon.preferDefault;
  List<String> registeredAids = const [];

  /// Every category a query was asked about, in the order it was asked.
  final categories = <CardEmulationCategoryPigeon>[];
  String? lastAid;

  String? lastFilter;
  String? lastPattern;
  bool? lastAutoTransact;
  final removed = <String>[];
  final removedPatterns = <String>[];

  @override
  Future<bool> hceSupportsAidPrefixRegistration() async => prefixRegistration;

  @override
  Future<bool> hceCategoryAllowsForegroundPreference(CardEmulationCategoryPigeon category) async {
    categories.add(category);
    return foregroundPreference;
  }

  @override
  Future<AidSelectionModePigeon> hceSelectionModeForCategory(CardEmulationCategoryPigeon category) async {
    categories.add(category);
    return selectionMode;
  }

  @override
  Future<bool> hceIsDefaultServiceForCategory(CardEmulationCategoryPigeon category) async {
    categories.add(category);
    return defaultForCategory;
  }

  @override
  Future<bool> hceIsDefaultServiceForAid(String aid) async {
    lastAid = aid;
    return defaultForAid;
  }

  @override
  Future<List<String>> hceAidsForService(CardEmulationCategoryPigeon category) async {
    categories.add(category);
    return registeredAids;
  }

  @override
  Future<bool> hceSetObserveModeEnabled(bool enabled) async {
    lastObserveModeRequest = enabled;
    return observeModeAccepted;
  }

  @override
  Future<bool> hceSetDefaultToObserveMode(bool shouldDefault) async {
    lastShouldDefault = shouldDefault;
    return true;
  }

  @override
  Future<bool> hceRegisterPollingLoopFilter(String filter, bool autoTransact) async {
    lastFilter = filter;
    lastAutoTransact = autoTransact;
    return true;
  }

  @override
  Future<bool> hceRegisterPollingLoopPatternFilter(String pattern, bool autoTransact) async {
    lastPattern = pattern;
    lastAutoTransact = autoTransact;
    return true;
  }

  @override
  Future<bool> hceRemovePollingLoopFilter(String filter) async {
    removed.add(filter);
    return true;
  }

  @override
  Future<bool> hceRemovePollingLoopPatternFilter(String pattern) async {
    removedPatterns.add(pattern);
    return true;
  }
}

Future<void> _deliver(String method, Object? argument) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    'dev.flutter.pigeon.nfc_util.NfcFlutterApi.$method',
    NfcHostApi.pigeonChannelCodec.encodeMessage(<Object?>[argument]),
    (_) {},
  );
}

PollingFramePigeon frame(PollingFrameTypePigeon type, {List<int> data = const [], bool auto = false}) =>
    PollingFramePigeon(
      type: type,
      data: Uint8List.fromList(data),
      vendorSpecificGain: -1,
      timestamp: 1234,
      triggeredAutoTransact: auto,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAndroidHost host;
  late void Function() restore;

  setUp(() {
    host = _FakeAndroidHost();
    restore = debugReplaceApis(android: host);
  });

  tearDown(() {
    HostCardEmulation.instance.onPollingFrames = null;
    restore();
  });

  group('what the platform will do with a registration', () {
    test('each category goes out as its own constant', () async {
      // Two values, and asking about the wrong one answers something true about a category
      // the app never registered under -- which reads exactly like the right answer.
      await HostCardEmulation.instance.categoryAllowsForegroundPreference(CardEmulationCategory.payment);
      await HostCardEmulation.instance.isDefaultServiceForCategory(CardEmulationCategory.other);

      expect(host.categories, [CardEmulationCategoryPigeon.payment, CardEmulationCategoryPigeon.other]);
    });

    test('every selection mode the platform names has a name here', () async {
      const pairs = <(AidSelectionModePigeon, AidSelectionMode)>[
        (AidSelectionModePigeon.preferDefault, AidSelectionMode.preferDefault),
        (AidSelectionModePigeon.askIfConflict, AidSelectionMode.askIfConflict),
        (AidSelectionModePigeon.alwaysAsk, AidSelectionMode.alwaysAsk),
        (AidSelectionModePigeon.unknown, AidSelectionMode.unknown),
      ];

      // Worth spelling out because the platform's own constants are not in this order --
      // SELECTION_MODE_ALWAYS_ASK is 1 and SELECTION_MODE_ASK_IF_CONFLICT is 2, the reverse
      // of the wire enum -- so anything ordinal-based reports the opposite of what the
      // device said, and both answers are plausible.
      expect(pairs.map((pair) => pair.$1), unorderedEquals(AidSelectionModePigeon.values));

      for (final (wire, expected) in pairs) {
        host.selectionMode = wire;
        expect(
          await HostCardEmulation.instance.selectionModeForCategory(CardEmulationCategory.other),
          expected,
          reason: wire.name,
        );
      }
    });

    test('a constant this release does not name is reported rather than guessed at', () async {
      // Folding it into preferDefault would quietly mispredict where a tap goes.
      host.selectionMode = AidSelectionModePigeon.unknown;

      expect(
        await HostCardEmulation.instance.selectionModeForCategory(CardEmulationCategory.payment),
        AidSelectionMode.unknown,
      );
    });

    test('a service nobody registered under reports no AIDs, not a failure', () async {
      // The framework answers null there, meaning "no AIDs routed here" rather than "the
      // question failed", and an app reading the registration back has to be able to tell.
      expect(await HostCardEmulation.instance.aidsForService(CardEmulationCategory.other), isEmpty);
      expect(host.categories, [CardEmulationCategoryPigeon.other]);
    });

    test('the readback lists what is registered, manifest and run time together', () async {
      host.registeredAids = const ['F0010203040506', 'A0000002471001'];

      expect(await HostCardEmulation.instance.aidsForService(CardEmulationCategory.other), [
        'F0010203040506',
        'A0000002471001',
      ]);
    });

    test('the per-AID question is asked about the AID, not the category', () async {
      // An app can hold an AID without being the category default, and be the category
      // default without holding a given AID, so these are two different answers.
      host.defaultForAid = true;

      expect(await HostCardEmulation.instance.isDefaultServiceForAid('F0010203040506'), isTrue);
      expect(host.lastAid, 'F0010203040506');
      expect(host.categories, isEmpty);
    });

    test('prefix routing is a capability of the controller, asked before it is used', () async {
      // Registering a prefix on hardware that cannot route one just returns false, with
      // nothing to tell it apart from an AID the platform considers malformed.
      expect(await HostCardEmulation.instance.supportsAidPrefixRegistration(), isFalse);

      host.prefixRegistration = true;
      expect(await HostCardEmulation.instance.supportsAidPrefixRegistration(), isTrue);
    });
  });

  group('observe mode', () {
    test('a refusal is a value, not a throw', () async {
      // Only the preferred service may change observe mode, and an app that is not it yet is
      // in an ordinary state rather than a broken one. Throwing here would push every caller
      // into a try/catch around something it is expected to be told "no" about.
      host.observeModeAccepted = false;

      expect(await HostCardEmulation.instance.setObserveModeEnabled(true), isFalse);
      expect(host.lastObserveModeRequest, isTrue);
    });

    test('the accepted case reports true', () async {
      expect(await HostCardEmulation.instance.setObserveModeEnabled(true), isTrue);
    });

    test('the persistent default is a separate call', () async {
      await HostCardEmulation.instance.setDefaultToObserveMode(true);
      expect(host.lastShouldDefault, isTrue);
    });
  });

  group('polling loop filters', () {
    test('autoTransact defaults to off', () async {
      // Leaving observe mode automatically is the low-latency path and also the one that
      // gives up the chance to inspect the reader first, so it is opted into.
      await HostCardEmulation.instance.registerPollingLoopFilter(filter: '6A01');

      expect(host.lastFilter, '6A01');
      expect(host.lastAutoTransact, isFalse);
    });

    test('exact and pattern filters are separate registrations', () async {
      await HostCardEmulation.instance.registerPollingLoopFilter(filter: '6A01', autoTransact: true);
      await HostCardEmulation.instance.registerPollingLoopPatternFilter(pattern: '6A.*', autoTransact: true);
      await HostCardEmulation.instance.removePollingLoopFilter('6A01');
      await HostCardEmulation.instance.removePollingLoopPatternFilter('6A.*');

      expect(host.lastFilter, '6A01');
      expect(host.lastPattern, '6A.*');
      expect(host.removed, ['6A01']);
      expect(host.removedPatterns, ['6A.*']);
    });
  });

  group('polling frames', () {
    test('arrive as a batch and keep their order', () async {
      final batches = <List<PollingFrame>>[];
      HostCardEmulation.instance.onPollingFrames = batches.add;

      await _deliver('onPollingFrames', [
        frame(PollingFrameTypePigeon.on),
        frame(PollingFrameTypePigeon.a, data: [0x26]),
        frame(PollingFrameTypePigeon.off),
      ]);

      expect(batches, hasLength(1));
      expect(batches.single.map((f) => f.type), [PollingFrameType.on, PollingFrameType.a, PollingFrameType.off]);
      expect(batches.single[1].data, [0x26]);
      expect(batches.single[1].vendorSpecificGain, -1);
    });

    test('an unrecognised frame type still reaches the app', () async {
      // A reader's proprietary probe is often the thing an app registered a filter for.
      final batches = <List<PollingFrame>>[];
      HostCardEmulation.instance.onPollingFrames = batches.add;

      await _deliver('onPollingFrames', [
        frame(PollingFrameTypePigeon.unknown, data: [0xFF], auto: true),
      ]);

      expect(batches.single.single.type, PollingFrameType.unknown);
      expect(batches.single.single.triggeredAutoTransact, isTrue);
    });

    test('clearing the handler stops delivery without tearing anything down', () async {
      var calls = 0;
      HostCardEmulation.instance.onPollingFrames = (_) => calls++;
      await _deliver('onPollingFrames', [frame(PollingFrameTypePigeon.on)]);

      HostCardEmulation.instance.onPollingFrames = null;
      await _deliver('onPollingFrames', [frame(PollingFrameTypePigeon.on)]);

      expect(calls, 1);
    });
  });
}
