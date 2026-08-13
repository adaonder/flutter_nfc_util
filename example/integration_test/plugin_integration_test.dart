import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nfc_util/android.dart' as android;
import 'package:nfc_util/ios.dart' as ios;
import 'package:nfc_util/nfc_util.dart';

/// Tests that need a real device and a real platform implementation.
///
/// Run with `flutter test integration_test -d <device>` from the example directory. These
/// deliberately do not need a tag in the field: everything here is reachable without one,
/// which is what makes it automatable. Anything that needs a tag, a reader or a Wallet pass
/// is covered by review instead.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('checkAvailability reaches the platform and answers', () async {
    final availability = await NfcUtil.instance.checkAvailability();
    // Both test devices have NFC; the point is that the call resolves at all, which is what
    // never happens when the channel is misregistered.
    expect(availability, isNot(NfcAvailability.unsupported));
  });

  test('a session starts and stops', () async {
    await NfcUtil.instance.startSession(onDiscovered: (_) async {});
    await NfcUtil.instance.stopSession();
  }, skip: Platform.isIOS ? 'iOS puts a modal reader sheet up, which blocks the run' : false);

  test(
    'a second startSession is refused rather than replacing the first',
    () async {
      await NfcUtil.instance.startSession(onDiscovered: (_) async {});
      try {
        await expectLater(
          NfcUtil.instance.startSession(onDiscovered: (_) async {}),
          throwsA(isA<Exception>()),
        );
      } finally {
        await NfcUtil.instance.stopSession();
      }
    },
    skip: Platform.isIOS ? 'iOS puts a modal reader sheet up, which blocks the run' : false,
  );

  group('Android', () {
    test('reports the adapter state', () async {
      expect(await android.NfcUtilAndroid.instance.isEnabled(), isA<bool>());
      expect(await android.NfcUtilAndroid.instance.isSecureNfcSupported(), isA<bool>());
    });

    test('registering AIDs makes the app a card, and unregistering takes it back', () async {
      final hce = android.HostCardEmulation.instance;
      if (!await hce.isSupported()) return;

      // The emulation service ships disabled so a reader-only app never appears in the
      // system's card-emulation registry. registerAids is what turns it on; this is the only
      // way to prove that round trip, since enabling a component is something only the app
      // itself may do.
      expect(await hce.registerAids(['F0010203040506']), isTrue);
      expect(await hce.unregisterAids(), isTrue);
    });
  }, skip: !Platform.isAndroid);

  group('iOS', () {
    test('reports what the device can do', () async {
      expect(await ios.NfcUtilIos.instance.tagSessionReadingAvailable(), isA<bool>());
      expect(await ios.NfcUtilIos.instance.vasSessionReadingAvailable(), isA<bool>());
    });

    test('takeInitialNdefMessage is empty when the app was not launched by a tag', () async {
      expect(await ios.NfcUtilIos.instance.takeInitialNdefMessage(), isNull);
    });
  }, skip: !Platform.isIOS);
}
