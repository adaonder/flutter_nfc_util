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

  String? lastFilter;
  String? lastPattern;
  bool? lastAutoTransact;
  final removed = <String>[];
  final removedPatterns = <String>[];

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
