import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_util/android.dart' as android;
import 'package:nfc_util/ios.dart' as ios;
import 'package:nfc_util/ndef.dart';
import 'package:nfc_util/nfc_util.dart';
import 'package:nfc_util/src/api.dart';
import 'package:nfc_util/src/pigeon.g.dart';

/// A stand-in platform, so the session logic can be exercised without a device.
///
/// The generated host API is a concrete class whose methods are overridable, so a subclass
/// that answers without touching a channel is all a test needs.
class _FakeHost extends NfcHostApi {
  AvailabilityPigeon availability = AvailabilityPigeon.enabled;
  Object? availabilityError;
  Object? startError;
  Object? stopError;

  SessionConfigPigeon? lastConfig;
  int startCount = 0;
  int stopCount = 0;
  final disposed = <String>[];

  String? lastStopAlertMessage;
  String? lastStopErrorMessage;

  NdefMessagePigeon? tagMessage;
  NdefMessagePigeon? written;
  int writeLockCount = 0;

  @override
  Future<AvailabilityPigeon> checkAvailability() async {
    if (availabilityError != null) throw availabilityError!;
    return availability;
  }

  @override
  Future<void> startSession(SessionConfigPigeon config) async {
    startCount++;
    lastConfig = config;
    if (startError != null) throw startError!;
  }

  @override
  Future<void> stopSession(String? alertMessage, String? errorMessage) async {
    stopCount++;
    lastStopAlertMessage = alertMessage;
    lastStopErrorMessage = errorMessage;
    if (stopError != null) throw stopError!;
  }

  @override
  Future<void> disposeTag(String handle) async => disposed.add(handle);

  @override
  Future<NdefMessagePigeon?> ndefRead(String handle) async => tagMessage;

  @override
  Future<void> ndefWrite(String handle, NdefMessagePigeon message) async => written = message;

  @override
  Future<void> ndefWriteLock(String handle) async => writeLockCount++;
}

/// Delivers a platform-to-Dart event the way the native side would.
///
/// The generated host API exposes the same codec the real channels use, which is what lets
/// a test drive the callback path end to end rather than poking at internals.
Future<void> _deliver(String method, Object? argument) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    'dev.flutter.pigeon.nfc_util.NfcFlutterApi.$method',
    NfcHostApi.pigeonChannelCodec.encodeMessage(<Object?>[argument]),
    (_) {},
  );
}

Future<void> deliverTag(TagPigeon tag) => _deliver('onDiscovered', tag);

Future<void> deliverError(NfcErrorPigeon error, {SessionKindPigeon kind = SessionKindPigeon.tag}) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    'dev.flutter.pigeon.nfc_util.NfcFlutterApi.onError',
    NfcHostApi.pigeonChannelCodec.encodeMessage(<Object?>[kind, error]),
    (_) {},
  );
}

Future<void> deliverAdapterState(AdapterStatePigeon state) => _deliver('onAdapterStateChanged', state);

Future<void> deliverBecameActive(SessionKindPigeon kind) => _deliver('onSessionBecameActive', kind);

/// A stand-in for the iOS-only host, so the VAS paths can be driven without a device.
class _FakeIosHost extends NfcIosHostApi {
  Object? vasBeginError;
  int vasBeginCount = 0;
  int vasInvalidateCount = 0;

  @override
  Future<void> vasSessionBegin(List<VasCommandConfigurationPigeon> configurations, String? alertMessage) async {
    vasBeginCount++;
    if (vasBeginError != null) throw vasBeginError!;
  }

  @override
  Future<void> vasSessionInvalidate(String? alertMessage, String? errorMessage) async => vasInvalidateCount++;
}

TagPigeon plainTag(String handle) => TagPigeon(handle: handle, id: Uint8List.fromList([1, 2, 3]));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeHost host;
  late void Function() restoreApis;

  setUp(() {
    host = _FakeHost();
    restoreApis = debugReplaceApis(nfc: host);
  });

  tearDown(() => restoreApis());

  group('checkAvailability', () {
    test('passes the platform answer through', () async {
      for (final (wire, expected) in [
        (AvailabilityPigeon.enabled, NfcAvailability.enabled),
        (AvailabilityPigeon.disabled, NfcAvailability.disabled),
        (AvailabilityPigeon.unsupported, NfcAvailability.unsupported),
      ]) {
        host.availability = wire;
        expect(await NfcUtil.instance.checkAvailability(), expected);
      }
    });

    test('degrades to unsupported rather than throwing, so it can gate a feature', () async {
      host.availabilityError = PlatformException(code: 'unavailable');
      expect(await NfcUtil.instance.checkAvailability(), NfcAvailability.unsupported);
    });
  });

  group('startSession', () {
    test('polls for everything by default', () async {
      await NfcUtil.instance.startSession(onDiscovered: (_) async {});
      expect(host.lastConfig!.pollingOptions, hasLength(3));
    });

    test('passes the options through, including the presence-check delay 2.x hardcoded', () async {
      await NfcUtil.instance.startSession(
        onDiscovered: (_) async {},
        pollingOptions: {NfcPollingOption.iso14443},
        skipNdefCheck: true,
        alertMessageIos: 'hold still',
        invalidateAfterFirstReadIos: false,
        noPlatformSoundsAndroid: false,
        discoverNfcBarcodeAndroid: true,
        presenceCheckDelayAndroid: const Duration(milliseconds: 500),
      );

      final config = host.lastConfig!;
      expect(config.pollingOptions, [PollingOptionPigeon.iso14443]);
      expect(config.skipNdefCheck, isTrue);
      expect(config.alertMessage, 'hold still');
      expect(config.invalidateAfterFirstRead, isFalse);
      expect(config.noPlatformSounds, isFalse);
      expect(config.discoverNfcBarcode, isTrue);
      expect(config.presenceCheckDelayMillis, 500);
    });

    test('rethrows a refused start', () async {
      host.startError = PlatformException(code: 'session_already_exists');
      expect(
        () => NfcUtil.instance.startSession(onDiscovered: (_) async {}),
        throwsA(isA<PlatformException>()),
      );
    });

    test('does not leave the callback armed when the start was refused', () async {
      host.startError = PlatformException(code: 'unavailable');
      var called = false;
      await expectLater(
        NfcUtil.instance.startSession(onDiscovered: (_) async => called = true),
        throwsA(isA<PlatformException>()),
      );

      await deliverTag(plainTag('ghost'));
      expect(called, isFalse, reason: 'a session that never began must not deliver tags');
    });
  });

  group('tag delivery', () {
    test('hands the tag to the callback and then releases the native handle', () async {
      NfcTag? received;
      await NfcUtil.instance.startSession(onDiscovered: (tag) async => received = tag);

      await deliverTag(plainTag('handle-1'));

      expect(received?.handle, 'handle-1');
      expect(received?.id, Uint8List.fromList([1, 2, 3]));
      expect(host.disposed, ['handle-1']);
    });

    test('releases the handle even when the callback throws', () async {
      await NfcUtil.instance.startSession(onDiscovered: (_) async => throw StateError('boom'));

      await deliverTag(plainTag('handle-2'));

      // A callback that throws must still release the handle, or the tag stays in the
      // platform's map for the life of the process.
      expect(host.disposed, ['handle-2']);
    });

    test('waits for the callback before releasing, so tag I/O inside it is safe', () async {
      var releasedBeforeCallbackFinished = false;
      await NfcUtil.instance.startSession(
        onDiscovered: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          releasedBeforeCallbackFinished = host.disposed.isNotEmpty;
        },
      );

      await deliverTag(plainTag('handle-3'));
      expect(releasedBeforeCallbackFinished, isFalse);
      expect(host.disposed, ['handle-3']);
    });

    test('stops delivering after stopSession', () async {
      var count = 0;
      await NfcUtil.instance.startSession(onDiscovered: (_) async => count++);
      await deliverTag(plainTag('a'));
      await NfcUtil.instance.stopSession();
      await deliverTag(plainTag('b'));

      expect(count, 1);
    });
  });

  group('errors', () {
    test('reports an iOS failure with its CoreNFC code', () async {
      NfcError? received;
      await NfcUtil.instance.startSession(onDiscovered: (_) async {}, onError: (e) async => received = e);

      await deliverError(NfcErrorPigeon(
        source: ErrorSourcePigeon.ios,
        iosCode: ReaderErrorCodePigeon.tagConnectionLost,
        message: 'Tag connection lost',
        sessionEnded: true,
      ));

      expect(received?.source, NfcErrorSource.ios);
      expect(received?.iosCode, NfcReaderErrorCode.tagConnectionLost);
      expect(received?.androidCode, isNull);
    });

    test('reports an Android failure with its typed code', () async {
      // 2.x could not do this at all: the Kotlin side never invoked the error callback.
      NfcError? received;
      await NfcUtil.instance.startSession(onDiscovered: (_) async {}, onError: (e) async => received = e);

      await deliverError(NfcErrorPigeon(
        source: ErrorSourcePigeon.android,
        androidCode: AndroidErrorCodePigeon.tagLost,
        message: 'TagLostException',
        sessionEnded: true,
      ));

      expect(received?.source, NfcErrorSource.android);
      expect(received?.androidCode, NfcAndroidErrorCode.tagLost);
      expect(received?.iosCode, isNull);
    });

    test('carries the iOS 26 codes rather than throwing on them', () async {
      // These two exist only in the iOS 26 SDK, so they are the codes an enum bridge is
      // most likely to have drifted on.
      for (final code in [ReaderErrorCodePigeon.ineligible, ReaderErrorCodePigeon.accessNotAccepted]) {
        NfcError? received;
        await NfcUtil.instance.startSession(onDiscovered: (_) async {}, onError: (e) async => received = e);
        await deliverError(
          NfcErrorPigeon(source: ErrorSourcePigeon.ios, iosCode: code, message: '', sessionEnded: true),
        );
        expect(received?.iosCode, isNotNull);
      }
    });
  });

  group('stopSession', () {
    test('passes the sheet messages through', () async {
      await NfcUtil.instance.stopSession(alertMessageIos: 'done', errorMessageIos: 'failed');
      expect(host.lastStopAlertMessage, 'done');
      expect(host.lastStopErrorMessage, 'failed');
    });

    test('never throws, because the session may already be gone', () async {
      host.stopError = PlatformException(code: 'unavailable');
      await expectLater(NfcUtil.instance.stopSession(), completes);
    });
  });

  group('Ndef', () {
    NfcTag ndefTag() => NfcTag(
      TagPigeon(
        handle: 'ndef-1',
        ndefAndroid: NdefAndroidPigeon(
          type: 'org.nfcforum.ndef.type2',
          maxSize: 137,
          isWritable: true,
          canMakeReadOnly: true,
        ),
      ),
    );

    test('reads a message off the tag', () async {
      host.tagMessage = NdefMessagePigeon(
        records: [
          NdefRecordPigeon(
            typeNameFormat: TypeNameFormatPigeon.wellKnown,
            type: Uint8List.fromList([0x54]),
            identifier: Uint8List(0),
            payload: Uint8List.fromList([0x02, 0x74, 0x72, 0x61, 0x62]),
          ),
        ],
      );

      final message = await Ndef.from(ndefTag())!.read();
      expect(TextRecord.from(message!.records.single)!.text, 'ab');
      expect(TextRecord.from(message.records.single)!.languageCode, 'tr');
    });

    test('reports an empty tag as null rather than an error', () async {
      host.tagMessage = null;
      expect(await Ndef.from(ndefTag())!.read(), isNull);
    });

    test('writes a message through unchanged', () async {
      await Ndef.from(ndefTag())!.write(NdefMessage([UriRecord.create(Uri.parse('https://example.com'))]));

      final record = host.written!.records.single;
      expect(record.typeNameFormat, TypeNameFormatPigeon.wellKnown);
      expect(record.type, Uint8List.fromList([0x55]));
      // Prefix index 4 is 'https://'.
      expect(record.payload[0], 4);
    });

    test('locks the tag', () async {
      await Ndef.from(ndefTag())!.writeLock();
      expect(host.writeLockCount, 1);
    });
  });

  group('a refused start leaves the running session alone', () {
    test('keeps the first session\'s tag handler when the second start is refused', () async {
      // The whole point of making a double start an error rather than 2.x\'s silent
      // replacement. If the guard also unregistered the live session\'s callbacks it would
      // be worse than the behaviour it replaced: the radio stays busy and the app goes deaf.
      final first = <String>[];
      await NfcUtil.instance.startSession(onDiscovered: (tag) async => first.add(tag.handle));

      host.startError = PlatformException(code: 'session_already_exists');
      await NfcUtil.instance.startSession(onDiscovered: (tag) async => fail('never')).catchError((_) {});

      await deliverTag(plainTag('still-mine'));
      expect(first, ['still-mine']);
    });

    test('keeps the first session\'s error handler too', () async {
      NfcError? received;
      await NfcUtil.instance.startSession(onDiscovered: (_) async {}, onError: (e) async => received = e);

      host.startError = PlatformException(code: 'session_already_exists');
      await NfcUtil.instance.startSession(onDiscovered: (_) async {}, onError: (_) async => fail('never'))
          .catchError((_) {});

      await deliverError(NfcErrorPigeon(
        source: ErrorSourcePigeon.android,
        androidCode: AndroidErrorCodePigeon.tagLost,
        message: 'gone',
        sessionEnded: true,
      ));
      expect(received, isNotNull);
    });

    test('still disarms when there was no session to begin with', () async {
      host.startError = PlatformException(code: 'unavailable');
      var called = false;
      await expectLater(
        NfcUtil.instance.startSession(onDiscovered: (_) async => called = true),
        throwsA(isA<PlatformException>()),
      );

      await deliverTag(plainTag('ghost'));
      expect(called, isFalse);
    });
  });

  group('overlapping starts', () {
    test('a start refused while another succeeded in between does not clobber the winner', () async {
      // Two starts in flight. A fails for its own reason, B succeeds. A's teardown must not
      // reach back and unregister B -- the arms are a stack, and A is removed from the
      // middle of it rather than written over the top.
      host.startError = PlatformException(code: 'no_activity');
      final refused = expectLater(
        NfcUtil.instance.startSession(onDiscovered: (_) async => fail('A never began')),
        throwsA(isA<PlatformException>()),
      );

      host.startError = null;
      final winner = <String>[];
      await NfcUtil.instance.startSession(onDiscovered: (tag) async => winner.add(tag.handle));
      await refused;

      await deliverTag(plainTag('to-b'));
      expect(winner, ['to-b']);
    });

    test('a start refused because one is already running restores the live session', () async {
      final live = <String>[];
      await NfcUtil.instance.startSession(onDiscovered: (tag) async => live.add(tag.handle));

      host.startError = PlatformException(code: 'session_already_exists');
      await expectLater(
        NfcUtil.instance.startSession(onDiscovered: (_) async => fail('the refused session must not receive')),
        throwsA(isA<PlatformException>()),
      );

      await deliverTag(plainTag('to-live'));
      expect(live, ['to-live']);
    });

    test('stopSession wins over a start still in flight', () async {
      // The stack is emptied, so the in-flight start's teardown cannot resurrect anything.
      await NfcUtil.instance.startSession(onDiscovered: (_) async => fail('stopped'));
      await NfcUtil.instance.stopSession();

      host.startError = PlatformException(code: 'unavailable');
      await expectLater(
        NfcUtil.instance.startSession(onDiscovered: (_) async => fail('never began')),
        throwsA(isA<PlatformException>()),
      );

      // Reaching this without a fail() is the assertion: neither the stopped session's
      // handler nor the refused start's is armed.
      await deliverTag(plainTag('after-stop'));
      expect(host.disposed, contains('after-stop'), reason: 'an undelivered tag is still released');
    });
  });

  group('VAS and tag sessions keep their own handlers', () {
    late _FakeIosHost iosHost;
    late void Function() restoreIos;

    setUp(() {
      iosHost = _FakeIosHost();
      restoreIos = debugReplaceApis(ios: iosHost);
    });

    tearDown(() => restoreIos());

    test('stopping the tag session does not deafen a running VAS session', () async {
      NfcError? vasError;
      var vasActive = 0;
      await ios.NfcUtilIos.instance.vasSessionBegin(
        configurations: const [ios.VasCommandConfiguration(passTypeIdentifier: 'pass.com.example')],
        onResponse: (_) {},
        onError: (e) async => vasError = e,
        onBecameActive: () => vasActive++,
      );

      // The realistic trigger is programmatic: a shared "stop all NFC" helper, a route
      // teardown, a watchdog timer.
      await NfcUtil.instance.stopSession();

      await deliverBecameActive(SessionKindPigeon.vas);
      await deliverError(
        NfcErrorPigeon(
          source: ErrorSourcePigeon.ios,
          iosCode: ReaderErrorCodePigeon.userCanceled,
          message: 'cancelled',
          sessionEnded: true,
        ),
        kind: SessionKindPigeon.vas,
      );

      expect(vasActive, 1, reason: 'the VAS sheet coming up still has to reach the app');
      expect(vasError, isNotNull, reason: 'the user cancelling the VAS sheet still has to reach the app');
    });

    test('ending the VAS session does not deafen a running tag session', () async {
      NfcError? tagError;
      await NfcUtil.instance.startSession(onDiscovered: (_) async {}, onError: (e) async => tagError = e);

      await ios.NfcUtilIos.instance.vasSessionInvalidate();

      await deliverError(NfcErrorPigeon(
        source: ErrorSourcePigeon.ios,
        iosCode: ReaderErrorCodePigeon.sessionTimeout,
        message: 'timed out',
        sessionEnded: true,
      ));
      expect(tagError, isNotNull);
    });

    test('a VAS start that fails for its own reasons leaves the tag session armed', () async {
      final seen = <String>[];
      await NfcUtil.instance.startSession(onDiscovered: (tag) async => seen.add(tag.handle));

      // An empty configuration list is rejected before any session is touched.
      iosHost.vasBeginError = PlatformException(code: 'invalid_parameter');
      await expectLater(
        ios.NfcUtilIos.instance.vasSessionBegin(configurations: const [], onResponse: (_) {}),
        throwsA(isA<PlatformException>()),
      );

      await deliverTag(plainTag('untouched'));
      expect(seen, ['untouched']);
    });

    test('an error routes to the family it belongs to and no further', () async {
      NfcError? tagError;
      NfcError? vasError;

      await NfcUtil.instance.startSession(onDiscovered: (_) async {}, onError: (e) async => tagError = e);
      await ios.NfcUtilIos.instance.vasSessionBegin(
        configurations: const [ios.VasCommandConfiguration(passTypeIdentifier: 'pass.com.example')],
        onResponse: (_) {},
        onError: (e) async => vasError = e,
      );

      await deliverError(
        NfcErrorPigeon(
          source: ErrorSourcePigeon.ios,
          iosCode: ReaderErrorCodePigeon.userCanceled,
          message: 'vas cancelled',
          sessionEnded: true,
        ),
        kind: SessionKindPigeon.vas,
      );

      expect(vasError?.message, 'vas cancelled');
      expect(tagError, isNull, reason: 'a wallet-pass failure must not be reported as a tag failure');
    });
  });

  group('a session that ends by itself disarms itself', () {
    test('an ended session stops delivering without a stopSession call', () async {
      var delivered = 0;
      await NfcUtil.instance.startSession(onDiscovered: (_) async => delivered++, onError: (_) async {});

      await deliverError(NfcErrorPigeon(
        source: ErrorSourcePigeon.ios,
        iosCode: ReaderErrorCodePigeon.userCanceled,
        message: 'cancelled',
        sessionEnded: true,
      ));

      await deliverTag(plainTag('after-cancel'));
      expect(delivered, 0, reason: 'the handlers go with the session that owned them');
      expect(host.disposed, contains('after-cancel'));
    });

    test('a failure that leaves the session alive keeps the handlers armed', () async {
      var delivered = 0;
      await NfcUtil.instance.startSession(onDiscovered: (_) async => delivered++, onError: (_) async {});

      // Android reports an unreadable tag without ending reader mode.
      await deliverError(NfcErrorPigeon(
        source: ErrorSourcePigeon.android,
        androidCode: AndroidErrorCodePigeon.io,
        message: 'one bad tag',
        sessionEnded: false,
      ));

      await deliverTag(plainTag('next-tag'));
      expect(delivered, 1);
    });

    test('restarting from inside onError is not deafened by the disarm', () async {
      // The handler runs synchronously, so the restart pushes its arm before onError
      // returns. Popping the top afterwards would have killed the session just started.
      var second = 0;
      await NfcUtil.instance.startSession(
        onDiscovered: (_) async {},
        onError: (_) async {
          await NfcUtil.instance.startSession(onDiscovered: (_) async => second++);
        },
      );

      await deliverError(NfcErrorPigeon(
        source: ErrorSourcePigeon.ios,
        iosCode: ReaderErrorCodePigeon.sessionTimeout,
        message: 'timed out',
        sessionEnded: true,
      ));

      await deliverTag(plainTag('to-the-restart'));
      expect(second, 1);
    });
  });

  group('sessionEnded', () {
    test('tells a retryable failure from a dead session', () async {
      final ended = <bool>[];
      await NfcUtil.instance.startSession(onDiscovered: (_) async {}, onError: (e) async => ended.add(e.sessionEnded));

      // Android: one unreadable tag, reader mode still polling.
      await deliverError(NfcErrorPigeon(
        source: ErrorSourcePigeon.android,
        androidCode: AndroidErrorCodePigeon.io,
        message: 'tag could not be read',
        sessionEnded: false,
      ));
      // iOS: the sheet timed out, the session is gone.
      await deliverError(NfcErrorPigeon(
        source: ErrorSourcePigeon.ios,
        iosCode: ReaderErrorCodePigeon.sessionTimeout,
        message: 'timed out',
        sessionEnded: true,
      ));

      expect(ended, [false, true]);
    });
  });

  group('Android adapter state', () {
    test('emits what the platform reports', () async {
      final seen = <NfcAdapterState>[];
      final subscription = android.NfcUtilAndroid.instance.onAdapterStateChanged.listen(seen.add);

      await deliverAdapterState(AdapterStatePigeon.turningOn);
      await deliverAdapterState(AdapterStatePigeon.on);
      await deliverAdapterState(AdapterStatePigeon.off);

      expect(seen, [NfcAdapterState.turningOn, NfcAdapterState.on, NfcAdapterState.off]);
      await subscription.cancel();
    });
  });
}
