import '../api.dart';
import '../callbacks.dart';
import '../common.dart';
import '../mapping.dart';
import '../pigeon.g.dart';

/// An `NfcAdapter.FLAG_READER_*` value.
///
/// Used with [NfcUtilAndroid.enableReaderMode] when the cross-platform
/// `NfcUtil.startSession` does not express the combination you need.
enum NfcReaderFlag {
  nfcA,
  nfcB,
  nfcF,
  nfcV,

  /// Barcode tags are never discovered without this.
  nfcBarcode,

  /// Suppresses the system's tag-discovery sound.
  noPlatformSounds,

  /// Skips the platform's NDEF probe, making discovery measurably faster.
  skipNdefCheck,
}

/// A technology [NfcUtilAndroid.setDiscoveryTechnology] can poll for.
///
/// [disable] and [keep] are not technologies and do not combine with one: the platform
/// spells them as "no bits at all" and "leave whatever is already set", so a set holding
/// either alongside a technology has no reading the controller could act on. [keep] wins
/// over everything else; a set that is empty, or holds only [disable], turns polling off.
enum NfcPollTech { nfcA, nfcB, nfcF, nfcV, disable, keep }

/// A technology [NfcUtilAndroid.setDiscoveryTechnology] can listen as.
///
/// There is no NFC-V entry: Android offers passive listening for A, B and F only. See
/// [NfcPollTech] for [disable] and [keep].
enum NfcListenTech { nfcA, nfcB, nfcF, disable, keep }

/// Where one antenna sits, in millimetres from the top-left corner of the *back* of the
/// device, held face up in its natural orientation.
class NfcAntennaLocation {
  const NfcAntennaLocation({required this.x, required this.y});

  final int x;
  final int y;

  @override
  String toString() => 'NfcAntennaLocation($x, $y)';
}

/// Where this device's NFC antennas are, for an app that wants to show the user where to
/// hold the tag.
///
/// API 34 and above; [NfcUtilAndroid.getAntennaInfo] returns null below that, and on a
/// device that reports no geometry.
class NfcAntennaInfo {
  const NfcAntennaInfo({
    required this.deviceWidth,
    required this.deviceHeight,
    required this.deviceFoldable,
    required this.antennas,
  });

  /// Device width in millimetres, unfolded for a foldable.
  final int deviceWidth;

  /// Device height in millimetres, unfolded for a foldable.
  final int deviceHeight;

  /// True for a foldable, where [antennas] describes the device unfolded and an antenna can
  /// therefore be on either half.
  final bool deviceFoldable;

  /// Usually one; a foldable can report several.
  final List<NfcAntennaLocation> antennas;

  @override
  String toString() => 'NfcAntennaInfo(${deviceWidth}x$deviceHeight mm, $antennas)';
}

/// What a [NfcEvent] is about.
enum NfcEventKind {
  /// Whether this app is now the preferred card-emulation service.
  preferredServiceChanged,

  /// Observe mode was switched on or off, by this app or by another.
  observeModeStateChanged,

  /// A reader selected an AID that more than one installed app claims.
  aidConflictOccurred,

  /// A reader selected an AID that no installed app claims.
  aidNotRouted,

  /// The NFC adapter was switched on or off.
  nfcStateChanged,

  /// A reader's field came up or went away.
  remoteFieldChanged,

  /// The NFC stack reported a problem with itself.
  internalError,
}

/// What went wrong inside the NFC stack, for [NfcEventKind.internalError].
enum NfcInternalError { unknown, nfcCrashRestart, nfcHardwareError, commandTimeout }

/// One card-emulation event from [NfcUtilAndroid.onNfcEvent].
///
/// Which fields are set follows from [kind]; the rest are null.
class NfcEvent {
  const NfcEvent._(this._data);

  final NfcEventPigeon _data;

  NfcEventKind get kind => switch (_data.kind) {
    NfcEventKindPigeon.preferredServiceChanged => NfcEventKind.preferredServiceChanged,
    NfcEventKindPigeon.observeModeStateChanged => NfcEventKind.observeModeStateChanged,
    NfcEventKindPigeon.aidConflictOccurred => NfcEventKind.aidConflictOccurred,
    NfcEventKindPigeon.aidNotRouted => NfcEventKind.aidNotRouted,
    NfcEventKindPigeon.nfcStateChanged => NfcEventKind.nfcStateChanged,
    NfcEventKindPigeon.remoteFieldChanged => NfcEventKind.remoteFieldChanged,
    NfcEventKindPigeon.internalError => NfcEventKind.internalError,
  };

  /// Set for [NfcEventKind.preferredServiceChanged] (is this app preferred),
  /// [NfcEventKind.observeModeStateChanged] (is observe mode on) and
  /// [NfcEventKind.remoteFieldChanged] (is a reader's field present).
  bool? get enabled => _data.enabled;

  /// The AID, for [NfcEventKind.aidConflictOccurred] and [NfcEventKind.aidNotRouted].
  String? get aid => _data.aid;

  /// The new adapter state, for [NfcEventKind.nfcStateChanged].
  NfcAdapterState? get adapterState => _data.adapterState == null ? null : adapterStateFromWire(_data.adapterState!);

  /// What went wrong, for [NfcEventKind.internalError].
  NfcInternalError? get internalError => switch (_data.internalError) {
    null => null,
    NfcInternalErrorPigeon.unknown => NfcInternalError.unknown,
    NfcInternalErrorPigeon.nfcCrashRestart => NfcInternalError.nfcCrashRestart,
    NfcInternalErrorPigeon.nfcHardwareError => NfcInternalError.nfcHardwareError,
    NfcInternalErrorPigeon.commandTimeout => NfcInternalError.commandTimeout,
  };

  @override
  String toString() =>
      'NfcEvent(${kind.name}${enabled == null ? '' : ', $enabled'}${aid == null ? '' : ', $aid'}'
      '${adapterState == null ? '' : ', ${adapterState!.name}'}'
      '${internalError == null ? '' : ', ${internalError!.name}'})';
}

/// Whether a tag *intent* can actually reach this app, as
/// [NfcUtilAndroid.checkTagIntentSetup] found it.
///
/// Both of the ways this can be wrong fail silently -- the tap does nothing, and nothing is
/// logged -- so this exists to turn them into something an app can show or assert on.
class TagIntentSetup {
  const TagIntentSetup._(this._data);

  final TagIntentSetupPigeon _data;

  /// True on Android 17 and above, where an activity with an NFC intent filter is only
  /// dispatched to when it declares `android.permission.DISPATCH_NFC_MESSAGE`.
  bool get dispatchPermissionRequired => _data.dispatchPermissionRequired;

  /// Activities in this app that answer an NFC intent without that permission, and so will
  /// never be dispatched to. Always empty when [dispatchPermissionRequired] is false.
  ///
  /// Found by probing, because Android exposes no way to read an activity's intent filters:
  /// the probes cover a filter with no data, one with any MIME type, and the `http` and
  /// `https` schemes. A filter that declares only some other scheme is not seen.
  List<String> get unguardedActivities => _data.unguardedActivities;

  /// Whether the user has this app on Android 16's tag-scan allowlist. True on a device with
  /// no such allowlist, so that "false" always means the user actually said no.
  bool get tagIntentAllowed => _data.tagIntentAllowed;

  /// Whether the device implements that allowlist at all.
  bool get tagIntentPreferenceSupported => _data.tagIntentPreferenceSupported;

  /// True when nothing found here would stop a tap from reaching the app.
  bool get isHealthy => tagIntentAllowed && unguardedActivities.isEmpty;

  @override
  String toString() =>
      'TagIntentSetup(allowed: $tagIntentAllowed, permissionRequired: $dispatchPermissionRequired, '
      'unguarded: $unguardedActivities)';
}

/// The raw Android surface.
///
/// Everything here is Android-only; on iOS these calls throw. The cross-platform
/// [NfcUtil] covers the common path, and this covers what it deliberately does not
/// express.
class NfcUtilAndroid {
  NfcUtilAndroid._();

  static NfcUtilAndroid? _instance;

  static NfcUtilAndroid get instance => _instance ??= NfcUtilAndroid._();

  /// Emits when the user switches NFC on or off in system settings.
  ///
  /// Events start arriving once the plugin is attached to an activity. The stream does not
  /// replay the current state -- pair it with `NfcUtil.checkAvailability` for that.
  Stream<NfcAdapterState> get onAdapterStateChanged => NfcCallbacks.instance.adapterState.stream;

  /// Whether the adapter is switched on.
  Future<bool> isEnabled() => androidApi.isEnabled();

  /// Whether the device supports secure NFC. API 29 and above; false below.
  Future<bool> isSecureNfcSupported() => androidApi.isSecureNfcSupported();

  /// Whether secure NFC is on, restricting tag reading to an unlocked device.
  Future<bool> isSecureNfcEnabled() => androidApi.isSecureNfcEnabled();

  /// Starts reader mode with exactly [flags], bypassing the cross-platform mapping.
  ///
  /// The tag and error callbacks are the session's, so register them the same way
  /// `NfcUtil.startSession` does.
  ///
  /// Throws an `ArgumentError`, before the platform is touched, for an empty [flags] or a
  /// [presenceCheckDelay] outside zero to `0x7fffffff` milliseconds.
  Future<void> enableReaderMode({
    required Set<NfcReaderFlag> flags,
    required Future<void> Function(NfcTag tag) onDiscovered,
    Future<void> Function(NfcError error)? onError,
    Duration presenceCheckDelay = const Duration(milliseconds: 250),
  }) async {
    // Unlike the cross-platform config, the raw flag list has no fallback on the Android
    // side: an empty set is passed through as flags `0`, which starts reader mode polling
    // for nothing at all. This stays a raw escape hatch, so only emptiness is rejected --
    // which flags make sense together is the caller's business.
    if (flags.isEmpty) {
      throw ArgumentError.value(flags, 'flags', 'is empty; reader mode would poll for nothing');
    }
    final presenceCheckDelayMillis = presenceCheckDelayToWire(presenceCheckDelay, 'presenceCheckDelay');

    final restore = NfcCallbacks.instance.armSession(tag: onDiscovered, error: onError);

    try {
      await androidApi.enableReaderMode(flags.map(_flagToWire).toList(), presenceCheckDelayMillis);
    } on Object {
      // Restores rather than clears, so a refused start leaves a session that is still
      // running exactly as it was.
      restore();
      rethrow;
    }
  }

  /// Stops reader mode.
  Future<void> disableReaderMode() async {
    NfcCallbacks.instance.clearSession();
    try {
      await androidApi.disableReaderMode();
    } on Object {
      // Cleanup call: reader mode may already be down.
    }
  }

  /// Claims tag delivery while the activity is in the foreground.
  ///
  /// Without this a tag matching another app's intent filter can be handed to that app
  /// instead, even while yours is on screen. Independent of reader mode, and of the
  /// manifest intent filters that make [onTagFromIntent] fire.
  Future<void> enableForegroundDispatch() => androidApi.enableForegroundDispatch();

  /// Releases the claim made by [enableForegroundDispatch].
  Future<void> disableForegroundDispatch() => androidApi.disableForegroundDispatch();

  /// Tags delivered by an intent filter rather than by a reader session.
  ///
  /// Requires intent filters in the *application's* manifest -- they name the app's own
  /// launcher activity, so the plugin cannot declare them. See the README.
  set onTagFromIntent(Future<void> Function(NfcTag tag)? handler) {
    NfcCallbacks.instance.intentTagHandler = handler;
  }

  /// The tag whose intent launched the app, if the app was launched by a tap.
  ///
  /// Consumed by the first call: a second call returns null, so a widget rebuild cannot
  /// process the same tag twice. Set [onTagFromIntent] before calling this to catch tags
  /// that arrive while the app is already running.
  ///
  /// **Android 17 stopped dispatching NFC intents to a stopped app**, so this returns null
  /// after a force-stop, and on a fresh install, until the user has opened the app once. The
  /// receiving activity also has to declare `android.permission.DISPATCH_NFC_MESSAGE` from
  /// API 37, and the user can switch the app off the tag-scan allowlist from API 36 --
  /// [checkTagIntentSetup] reports both, and neither raises an error on its own.
  Future<NfcTag?> takeInitialTag() async {
    final tag = await androidApi.takeInitialTag();
    return tag == null ? null : NfcTag(tag);
  }

  // -------------------------------------------------------------------------------------
  // Discovery technology. Android 15 (API 35) and above.
  // -------------------------------------------------------------------------------------

  /// Restricts what the controller polls for, and what it answers as, while this activity is
  /// in the foreground.
  ///
  /// Narrower than reader mode and independent of it: this reaches the controller's own
  /// discovery loop, so it also governs tags delivered by intent and by other apps' sessions
  /// while the app is on screen. Use it to keep the phone from waking on card types the app
  /// has no use for -- and, with an empty [listen], to stop it answering readers at all.
  ///
  /// Reset it with [resetDiscoveryTechnology]; the platform also resets on its own when the
  /// activity leaves the foreground.
  ///
  /// Throws a `PlatformException` with code `unsupported_api_level` below API 35.
  Future<void> setDiscoveryTechnology({required Set<NfcPollTech> poll, required Set<NfcListenTech> listen}) =>
      androidApi.setDiscoveryTechnology(poll.map(_pollTechToWire).toList(), listen.map(_listenTechToWire).toList());

  /// Puts discovery back to the system default.
  Future<void> resetDiscoveryTechnology() => androidApi.resetDiscoveryTechnology();

  /// Where this device's NFC antennas are, or null when the platform does not say.
  ///
  /// Null below API 34, and on a device that reports no geometry -- which is most of them.
  /// Treat a non-null answer as a bonus for the "hold your tag here" hint, not something to
  /// build a screen around.
  Future<NfcAntennaInfo?> getAntennaInfo() async {
    final info = await androidApi.getAntennaInfo();
    if (info == null) return null;
    return NfcAntennaInfo(
      deviceWidth: info.deviceWidth,
      deviceHeight: info.deviceHeight,
      deviceFoldable: info.deviceFoldable,
      antennas: [
        for (final antenna in info.availableNfcAntennas) NfcAntennaLocation(x: antenna.locationX, y: antenna.locationY),
      ],
    );
  }

  // -------------------------------------------------------------------------------------
  // Tag intent delivery. Android 16 (API 36) and 17 (API 37).
  // -------------------------------------------------------------------------------------

  /// Whether the device implements Android 16's per-app "launch via NFC" allowlist.
  Future<bool> isTagIntentAppPreferenceSupported() => androidApi.isTagIntentAppPreferenceSupported();

  /// Whether the user has allowed this app to be launched by a tag.
  ///
  /// True on a device with no allowlist, so false always means the user actually said no --
  /// which they can be asked to undo with [openTagIntentPreferenceSettings].
  Future<bool> isTagIntentAllowed() => androidApi.isTagIntentAllowed();

  /// Opens the system screen where the user changes that -- *Settings > Apps > Special app
  /// access > Launch via NFC*.
  ///
  /// Returns false when there is no such screen, or no activity to start it from. Nothing
  /// can be granted programmatically here; this only takes the user to the switch.
  Future<bool> openTagIntentPreferenceSettings() => androidApi.openTagIntentPreferenceSettings();

  /// Everything that decides whether a tag *intent* can reach this app.
  ///
  /// Worth calling once at startup on a debug build and logging the result: both of the
  /// things it reports -- the Android 16 allowlist and the Android 17 permission on the
  /// receiving activity -- make a tap do nothing at all, with no error anywhere. See
  /// [TagIntentSetup] and the README.
  Future<TagIntentSetup> checkTagIntentSetup() async => TagIntentSetup._(await androidApi.checkTagIntentSetup());

  // -------------------------------------------------------------------------------------
  // Card-emulation events. Android 16 (API 36) and above.
  // -------------------------------------------------------------------------------------

  /// Card-emulation events, once [enableNfcEvents] has been called.
  ///
  /// Broadcast, and never closed. Nothing arrives before [enableNfcEvents] succeeds, and on
  /// a device below API 36 nothing arrives at all.
  Stream<NfcEvent> get onNfcEvent => NfcCallbacks.instance.nfcEvents.stream.map(NfcEvent._);

  /// Starts delivering [onNfcEvent]. Returns false on a device below API 36.
  ///
  /// Registration is explicit rather than implicit in listening to the stream, because it
  /// costs a framework callback that the plugin has to unregister again: leaving one behind
  /// keeps the plugin, and through it the Flutter engine, alive after teardown. Pair it with
  /// [disableNfcEvents], although the plugin also unregisters when the engine detaches.
  Future<bool> enableNfcEvents() => androidApi.enableNfcEvents();

  /// Stops delivering [onNfcEvent].
  Future<void> disableNfcEvents() => androidApi.disableNfcEvents();

  static PollTechPigeon _pollTechToWire(NfcPollTech tech) => switch (tech) {
    NfcPollTech.nfcA => PollTechPigeon.nfcA,
    NfcPollTech.nfcB => PollTechPigeon.nfcB,
    NfcPollTech.nfcF => PollTechPigeon.nfcF,
    NfcPollTech.nfcV => PollTechPigeon.nfcV,
    NfcPollTech.disable => PollTechPigeon.disable,
    NfcPollTech.keep => PollTechPigeon.keep,
  };

  static ListenTechPigeon _listenTechToWire(NfcListenTech tech) => switch (tech) {
    NfcListenTech.nfcA => ListenTechPigeon.nfcA,
    NfcListenTech.nfcB => ListenTechPigeon.nfcB,
    NfcListenTech.nfcF => ListenTechPigeon.nfcF,
    NfcListenTech.disable => ListenTechPigeon.disable,
    NfcListenTech.keep => ListenTechPigeon.keep,
  };

  static ReaderFlagPigeon _flagToWire(NfcReaderFlag flag) => switch (flag) {
    NfcReaderFlag.nfcA => ReaderFlagPigeon.nfcA,
    NfcReaderFlag.nfcB => ReaderFlagPigeon.nfcB,
    NfcReaderFlag.nfcF => ReaderFlagPigeon.nfcF,
    NfcReaderFlag.nfcV => ReaderFlagPigeon.nfcV,
    NfcReaderFlag.nfcBarcode => ReaderFlagPigeon.nfcBarcode,
    NfcReaderFlag.noPlatformSounds => ReaderFlagPigeon.noPlatformSounds,
    NfcReaderFlag.skipNdefCheck => ReaderFlagPigeon.skipNdefCheck,
  };
}
