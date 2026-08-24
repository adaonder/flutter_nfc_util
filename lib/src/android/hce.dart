import 'dart:typed_data';

import '../api.dart';
import '../callbacks.dart';
import '../pigeon.g.dart';

/// What one frame of a reader's polling loop was.
///
/// The values are the reader's own signalling, not the tag's: [on] and [off] bracket the
/// period the field was up, and [a], [b] and [f] are the technology-specific probes the
/// reader sent inside it.
enum PollingFrameType {
  /// An NFC-A probe.
  a,

  /// An NFC-B probe.
  b,

  /// An NFC-F probe.
  f,

  /// The reader's field went away.
  off,

  /// The reader's field came up.
  on,

  /// A frame this release does not recognise. Reported rather than dropped, because a
  /// reader's proprietary probe is often exactly what an app is filtering for.
  unknown,
}

/// One frame of a reader's polling loop, seen while observe mode is on.
///
/// Android only, API 35 and above. See [HostCardEmulation.onPollingFrames].
class PollingFrame {
  const PollingFrame._(this._data);

  final PollingFramePigeon _data;

  PollingFrameType get type => switch (_data.type) {
    PollingFrameTypePigeon.a => PollingFrameType.a,
    PollingFrameTypePigeon.b => PollingFrameType.b,
    PollingFrameTypePigeon.f => PollingFrameType.f,
    PollingFrameTypePigeon.off => PollingFrameType.off,
    PollingFrameTypePigeon.on => PollingFrameType.on,
    PollingFrameTypePigeon.unknown => PollingFrameType.unknown,
  };

  /// The frame bytes. Empty for [PollingFrameType.on] and [PollingFrameType.off], which
  /// carry none.
  Uint8List get data => _data.data;

  /// The controller's measure of field strength in vendor-defined units, or -1 on a device
  /// whose stack does not report it. Only comparable against other frames from the same
  /// device.
  int get vendorSpecificGain => _data.vendorSpecificGain;

  /// When the controller saw the frame, as `SystemClock.uptimeMillis` truncated to 32 bits.
  ///
  /// Wraps roughly every 50 days, so treat it as a value to subtract from its neighbours
  /// rather than as a point in time.
  int get timestamp => _data.timestamp;

  /// Whether this frame matched a filter registered with `autoTransact`, which takes the
  /// device out of observe mode for the exchange that follows it.
  bool get triggeredAutoTransact => _data.triggeredAutoTransact;

  @override
  String toString() => 'PollingFrame(${type.name}, ${data.length} bytes, gain $vendorSpecificGain)';
}

/// One of the two buckets Android sorts card-emulation services into,
/// `CardEmulation.CATEGORY_*`.
///
/// [payment] is the wallet bucket, where the user picks one default app in system settings
/// and the platform treats that choice as theirs to make. Everything else -- transit,
/// loyalty, access control, a private AID of your own -- is [other], where routing is settled
/// per AID instead. This plugin registers what [HostCardEmulation.registerAids] is given
/// under [other].
enum CardEmulationCategory { payment, other }

/// How the platform picks between apps that claim the same AID,
/// `CardEmulation.SELECTION_MODE_*`.
///
/// This is what decides whether an AID conflict is something an app can settle by making
/// itself preferred, or something only the user can settle.
enum AidSelectionMode {
  /// The category's default service wins outright, and a second claimant is never reached.
  preferDefault,

  /// The user is asked, but only when the claim is actually contested.
  askIfConflict,

  /// The user is asked every time, contested or not.
  alwaysAsk,

  /// A constant this release does not name. Reported rather than folded into one of the
  /// others, because guessing here means quietly mispredicting where a tap goes.
  unknown,
}

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
  /// **This changes persistent device state.** The emulation service ships disabled, and a
  /// successful call enables it as a package component and stores the AID group with the
  /// Android framework. Both survive the process being killed, the phone rebooting and the
  /// app being updated: from here on the device answers readers for these AIDs whenever the
  /// app is installed, whether or not it is running. [unregisterAids] is the only way back
  /// short of uninstalling. Pair the two, and do not call this speculatively.
  ///
  /// Returns false when Android refuses the set -- most often because another app already
  /// holds one of the AIDs in a category it owns. A call that returns false or throws leaves
  /// nothing behind; the component is put back the way it was.
  Future<bool> registerAids(List<String> aids) => androidApi.hceRegisterAids(aids);

  /// Drops every AID registered by [registerAids] and disables the emulation service again,
  /// taking the app back out of the system's card-emulation registry.
  ///
  /// This is the counterpart to [registerAids] and the only way to undo it. An app that
  /// never calls it stays enrolled after it is closed.
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

  // -------------------------------------------------------------------------------------
  // What the platform will actually do with a registration. API 19 and 21 throughout, so
  // below this package's minSdk 24: none of it is version-gated.
  // -------------------------------------------------------------------------------------

  /// Whether the controller can route an AID *prefix* at all.
  ///
  /// Worth asking before registering one, because the failure is otherwise unreadable: on
  /// hardware that cannot route prefixes, [registerAids] just returns false, with nothing to
  /// tell that apart from an AID the platform considers malformed. When this is false,
  /// enumerate the full AIDs instead.
  Future<bool> supportsAidPrefixRegistration() => androidApi.hceSupportsAidPrefixRegistration();

  /// Whether [setPreferredService] changes anything for [category].
  ///
  /// False for [CardEmulationCategory.payment] on a device where the user's wallet choice is
  /// final. The call still succeeds there and simply has no effect, so an app that assumed
  /// otherwise sits waiting for a tap that is being routed elsewhere.
  Future<bool> categoryAllowsForegroundPreference(CardEmulationCategory category) =>
      androidApi.hceCategoryAllowsForegroundPreference(_categoryToWire(category));

  /// How the platform picks between apps that claim the same AID in [category].
  ///
  /// Tells an app whether a conflict is worth trying to win with [setPreferredService] or
  /// whether the user decides -- see [AidSelectionMode].
  Future<AidSelectionMode> selectionModeForCategory(CardEmulationCategory category) async =>
      _selectionModeFromWire(await androidApi.hceSelectionModeForCategory(_categoryToWire(category)));

  /// Whether this app's emulation service is the user's default for [category].
  Future<bool> isDefaultServiceForCategory(CardEmulationCategory category) =>
      androidApi.hceIsDefaultServiceForCategory(_categoryToWire(category));

  /// Whether a reader selecting [aid], as uppercase hex, reaches this app's service.
  ///
  /// The per-AID answer, and the one that decides a tap: an app can hold an AID without being
  /// the category default, and be the category default without holding a given AID.
  Future<bool> isDefaultServiceForAid(String aid) => androidApi.hceIsDefaultServiceForAid(aid);

  /// The AIDs registered against this app's emulation service in [category], as uppercase hex.
  ///
  /// The readback for [registerAids] -- pass [CardEmulationCategory.other], which is the
  /// category this plugin registers under. It reports the AIDs declared in the manifest and
  /// the ones registered at run time together, because together is what the framework routes
  /// on; there is no way to ask for one without the other.
  Future<List<String>> aidsForService(CardEmulationCategory category) =>
      androidApi.hceAidsForService(_categoryToWire(category));

  // -------------------------------------------------------------------------------------
  // Observe mode. Android 15 (API 35) and above.
  // -------------------------------------------------------------------------------------

  /// Whether this device can observe a reader's polling loop.
  ///
  /// False below API 35, and on hardware whose controller cannot report polling frames.
  /// Every other call in this section is only meaningful when this is true.
  Future<bool> isObserveModeSupported() => androidApi.hceIsObserveModeSupported();

  /// Whether observe mode is on right now.
  Future<bool> isObserveModeEnabled() => androidApi.hceIsObserveModeEnabled();

  /// Stops the device answering readers, and starts reporting their polling frames to
  /// [onPollingFrames] instead.
  ///
  /// This is how an app sees a reader *before* deciding to be a card for it: nothing is
  /// transacted while observe mode is on, so the app can inspect the loop, show a prompt, or
  /// pick which credential to present, and only then let the exchange happen -- with
  /// [setObserveModeEnabled] false, or automatically through a filter registered with
  /// `autoTransact`.
  ///
  /// **Call [setPreferredService] with true first.** Only the preferred service may change
  /// observe mode; a call from an app that is not it returns false rather than throwing,
  /// because that is an ordinary state to be in and not a defect.
  ///
  /// [registerAids] is *not* a prerequisite -- an app can watch readers without offering to
  /// be a card. This call enables the plugin's emulation service by itself, because the
  /// platform will not make a disabled service the preferred one. That enablement is the same
  /// persistent component state [registerAids] describes, and [unregisterAids] is the way
  /// back from it either way; it returns false when there were no AIDs to remove, which is
  /// not a failure.
  ///
  /// Throws a `PlatformException` with code `unsupported_api_level` below API 35.
  Future<bool> setObserveModeEnabled(bool enabled) => androidApi.hceSetObserveModeEnabled(enabled);

  /// Whether the emulation service should come up in observe mode whenever it becomes the
  /// preferred service, instead of needing [setObserveModeEnabled] on every foreground.
  ///
  /// Persistent, like [registerAids]: it is stored against the service by the framework.
  Future<bool> setDefaultToObserveMode(bool shouldDefault) => androidApi.hceSetDefaultToObserveMode(shouldDefault);

  /// Frames from the reader's polling loop, while observe mode is on.
  ///
  /// Delivered in batches -- one call can carry a whole loop -- and only for frames that
  /// match a filter registered with [registerPollingLoopFilter] or
  /// [registerPollingLoopPatternFilter].
  set onPollingFrames(void Function(List<PollingFrame> frames)? handler) {
    NfcCallbacks.instance.pollingFramesHandler = handler == null
        ? null
        : (frames) => handler([for (final frame in frames) PollingFrame._(frame)]);
  }

  /// Delivers polling frames whose bytes are exactly [filter], as uppercase hex.
  ///
  /// With [autoTransact] the platform leaves observe mode by itself the moment a frame
  /// matches, so the exchange that follows is answered rather than merely watched. That is
  /// the low-latency path: a reader will not wait for a round trip to Dart and back.
  ///
  /// Registration is persistent, like [registerAids], and scoped to this plugin's emulation
  /// service.
  Future<bool> registerPollingLoopFilter({required String filter, bool autoTransact = false}) =>
      androidApi.hceRegisterPollingLoopFilter(filter, autoTransact);

  /// As [registerPollingLoopFilter], but [pattern] matches a family of frames.
  ///
  /// **Not a regular expression**, despite the name, and the platform is strict about it:
  /// measured on Android 17, a pattern must *begin* with hex digits and may then use `*` and
  /// `?`. `6A*` and `6A01` are accepted; `.*`, a bare `*`, `????` and `*6A*` are all rejected
  /// with `PlatformException('unavailable', 'Polling loop pattern filters may only contain
  /// hexadecimal numbers, ?s and *s')`. Case does not matter.
  Future<bool> registerPollingLoopPatternFilter({required String pattern, bool autoTransact = false}) =>
      androidApi.hceRegisterPollingLoopPatternFilter(pattern, autoTransact);

  /// Removes a filter added by [registerPollingLoopFilter].
  Future<bool> removePollingLoopFilter(String filter) => androidApi.hceRemovePollingLoopFilter(filter);

  /// Removes a filter added by [registerPollingLoopPatternFilter].
  Future<bool> removePollingLoopPatternFilter(String pattern) => androidApi.hceRemovePollingLoopPatternFilter(pattern);

  static CardEmulationCategoryPigeon _categoryToWire(CardEmulationCategory category) => switch (category) {
    CardEmulationCategory.payment => CardEmulationCategoryPigeon.payment,
    CardEmulationCategory.other => CardEmulationCategoryPigeon.other,
  };

  static AidSelectionMode _selectionModeFromWire(AidSelectionModePigeon mode) => switch (mode) {
    AidSelectionModePigeon.preferDefault => AidSelectionMode.preferDefault,
    AidSelectionModePigeon.askIfConflict => AidSelectionMode.askIfConflict,
    AidSelectionModePigeon.alwaysAsk => AidSelectionMode.alwaysAsk,
    AidSelectionModePigeon.unknown => AidSelectionMode.unknown,
  };
}
