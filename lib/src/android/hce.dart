import 'dart:typed_data';

import '../api.dart';
import '../callbacks.dart';

/// Host card emulation: the phone answers a reader as if it were a contactless card.
///
/// Android only. Apple's equivalent is gated behind an entitlement that is not generally
/// available, so there is no iOS counterpart and these calls throw there.
///
/// ```dart
/// HostCardEmulation.instance.onApduReceived = (apdu) {
///   // Answer a SELECT with 9000, anything else with 6D00.
///   final isSelect = apdu.length > 1 && apdu[1] == 0xA4;
///   HostCardEmulation.instance.respond(
///     Uint8List.fromList(isSelect ? [0x90, 0x00] : [0x6D, 0x00]),
///   );
/// };
/// await HostCardEmulation.instance.registerAids(['F0010203040506']);
/// ```
///
/// ## What "foreground" means here
///
/// The Android service that receives APDUs can be started while the app's Flutter engine
/// is not running. This release bridges APDUs only while the engine is alive; a tap with
/// the app fully stopped is answered with a "not supported" status word rather than being
/// queued. An app that must work while closed needs the background engine, which is not in
/// this release.
///
/// Call [setPreferredService] with true while your app is on screen, or a tap can be
/// routed to the user's default wallet instead.
class HostCardEmulation {
  HostCardEmulation._();

  static HostCardEmulation? _instance;

  static HostCardEmulation get instance => _instance ??= HostCardEmulation._();

  /// Whether the device supports host card emulation at all.
  ///
  /// Checks `FEATURE_NFC_HOST_CARD_EMULATION`. A device can have NFC without it.
  Future<bool> isSupported() => androidApi.hceIsSupported();

  /// A reader sent a command APDU. Answer it with [respond].
  ///
  /// The reader is waiting, so answer promptly; a slow answer looks to the reader like a
  /// card that left the field.
  set onApduReceived(void Function(Uint8List apdu)? handler) {
    NfcCallbacks.instance.apduHandler = handler;
  }

  /// The link to the reader ended.
  ///
  /// The reason is Android's `HostApduService` constant: 0 when the link was lost, 1 when
  /// the reader selected a different application.
  set onDeactivated(void Function(int reason)? handler) {
    NfcCallbacks.instance.hceDeactivatedHandler = handler;
  }

  /// Registers the application identifiers this app answers for, as uppercase hex.
  ///
  /// Registered at run time against the plugin's own service, so an app does not have to
  /// ship a fixed AID list in its manifest and can change the set without a release.
  ///
  /// Returns false when Android refuses the set -- most often because another app already
  /// holds one of the AIDs in a category it owns.
  Future<bool> registerAids(List<String> aids) => androidApi.hceRegisterAids(aids);

  /// Drops every AID registered by [registerAids].
  Future<bool> unregisterAids() => androidApi.hceUnregisterAids();

  /// Answers the APDU most recently delivered to [onApduReceived].
  ///
  /// The bytes are sent as-is, so include the status word: `9000` for success, `6D00` for
  /// an instruction the card does not support.
  Future<void> respond(Uint8List response) => androidApi.hceRespond(response);

  /// Makes this app the preferred handler while it is in the foreground.
  ///
  /// Without it a tap can go to whichever app owns the AID by default, which for payment
  /// AIDs is the user's wallet. Pair it with the app's lifecycle: true on resume, false on
  /// pause.
  Future<void> setPreferredService(bool preferred) => androidApi.hceSetPreferredService(preferred);
}
