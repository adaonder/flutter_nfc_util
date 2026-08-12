import '../api.dart';
import '../callbacks.dart';
import '../common.dart';
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
  Future<void> enableReaderMode({
    required Set<NfcReaderFlag> flags,
    required Future<void> Function(NfcTag tag) onDiscovered,
    Future<void> Function(NfcError error)? onError,
    Duration presenceCheckDelay = const Duration(milliseconds: 250),
  }) async {
    final restore = NfcCallbacks.instance.armSession(tag: onDiscovered, error: onError);

    try {
      await androidApi.enableReaderMode(
        flags.map(_flagToWire).toList(),
        presenceCheckDelay.inMilliseconds,
      );
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
  Future<NfcTag?> takeInitialTag() async {
    final tag = await androidApi.takeInitialTag();
    return tag == null ? null : NfcTag(tag);
  }

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
