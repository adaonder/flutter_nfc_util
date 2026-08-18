import 'dart:io';

import 'package:flutter/services.dart';
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

    test('every capability probe answers rather than throwing', () async {
      // The point of a probe is that it is safe to ask on any device: an app decides what to
      // offer from these before it offers it. A probe that threw on an older phone would put
      // a try/catch around every feature check.
      final nfc = android.NfcUtilAndroid.instance;
      final hce = android.HostCardEmulation.instance;

      expect(await hce.isObserveModeSupported(), isA<bool>());
      expect(await hce.isObserveModeEnabled(), isA<bool>());
      expect(await nfc.isTagIntentAppPreferenceSupported(), isA<bool>());
      expect(await nfc.isTagIntentAllowed(), isA<bool>());
      // Null on most devices, which is a valid answer and not a failure.
      expect(await nfc.getAntennaInfo(), anyOf(isNull, isA<android.NfcAntennaInfo>()));
    });

    test('checkTagIntentSetup describes this device without an error', () async {
      final setup = await android.NfcUtilAndroid.instance.checkTagIntentSetup();

      // Below API 37 there is no permission to be missing, so the list has to be empty --
      // reporting activities as unguarded on an OS that does not check would send an app
      // chasing a problem it does not have.
      if (!setup.dispatchPermissionRequired) expect(setup.unguardedActivities, isEmpty);
      expect(setup.tagIntentAllowed, isA<bool>());
    });

    test('discovery technology round trips, or refuses on a device too old', () async {
      final nfc = android.NfcUtilAndroid.instance;

      try {
        await nfc.setDiscoveryTechnology(poll: {android.NfcPollTech.nfcA}, listen: {android.NfcListenTech.keep});
        // Left as we found it: this outlives the test otherwise, and the next one polls.
        await nfc.resetDiscoveryTechnology();
      } on PlatformException catch (e) {
        // The one refusal that is expected, on anything below Android 15.
        expect(e.code, 'unsupported_api_level');
      }
    });

    test('observe mode engages without registering AIDs first', () async {
      // The regression this exists for: the plugin used to claim its emulation service only
      // inside registerAids, so the documented sequence below turned observe mode on into
      // nothing at all -- setObserveModeEnabled returned false, isObserveModeEnabled stayed
      // false, and no polling frame could reach Dart because processPollingFrames drops the
      // batch when no engine has claimed the bridge. Nothing threw, so only a device could
      // catch it.
      final hce = android.HostCardEmulation.instance;
      if (!await hce.isObserveModeSupported()) return;

      // '6A*' rather than a regular expression: the platform takes hex digits first, then
      // `*` and `?`, and rejects '.*' outright.
      expect(await hce.registerPollingLoopFilter(filter: '6A01'), isTrue);
      await hce.setPreferredService(true);

      try {
        expect(await hce.setObserveModeEnabled(true), isTrue, reason: 'observe mode was refused');
        expect(await hce.isObserveModeEnabled(), isTrue);
      } finally {
        await hce.setObserveModeEnabled(false);
        await hce.removePollingLoopFilter('6A01');
        await hce.setPreferredService(false);
        // Also the release path for the component enablement the calls above performed. It
        // reports false because no AIDs were registered, which is not a failure.
        await hce.unregisterAids();
      }
    });

    test('the polling-loop pattern filter is not a regular expression', () async {
      final hce = android.HostCardEmulation.instance;
      if (!await hce.isObserveModeSupported()) return;

      // Pinned because the package's own README and example both used '.*' and it threw every
      // time: the platform accepts hex digits followed by `*` or `?`, and nothing else.
      expect(await hce.registerPollingLoopPatternFilter(pattern: '6A*'), isTrue);
      await hce.removePollingLoopPatternFilter('6A*');

      await expectLater(
        hce.registerPollingLoopPatternFilter(pattern: '.*'),
        throwsA(isA<PlatformException>()),
      );
      await hce.unregisterAids();
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
