import 'api.dart';
import 'callbacks.dart';
import 'common.dart';
import 'mapping.dart';
import 'pigeon.g.dart';

/// The cross-platform entry point.
///
/// This is a thin adapter over the raw platform surfaces in
/// `package:nfc_util/android.dart` and `package:nfc_util/ios.dart`. Nothing is hidden
/// behind it: anything it does not express is reachable by dropping to `NfcUtilAndroid` or
/// `NfcUtilIos` directly.
///
/// ```dart
/// if (await NfcUtil.instance.checkAvailability() != NfcAvailability.enabled) return;
///
/// await NfcUtil.instance.startSession(
///   onDiscovered: (tag) async {
///     final ndef = Ndef.from(tag);
///     if (ndef != null) print(await ndef.read());
///     await NfcUtil.instance.stopSession();
///   },
///   onError: (error) async => print(error),
/// );
/// ```
class NfcUtil {
  NfcUtil._();

  static NfcUtil? _instance;

  /// The process-wide instance. There is one NFC radio, so there is one of these.
  static NfcUtil get instance => _instance ??= NfcUtil._();

  /// Whether NFC can be used right now, and if not, why not.
  ///
  /// Separating [NfcAvailability.unsupported] from [NfcAvailability.disabled] is what lets
  /// an app offer "open settings" only when that would actually help.
  ///
  /// Never throws: a platform that cannot answer reports [NfcAvailability.unsupported], so
  /// this can be used directly as a feature gate.
  Future<NfcAvailability> checkAvailability() async {
    try {
      return availabilityFromWire(await nfcApi.checkAvailability());
    } on Object {
      return NfcAvailability.unsupported;
    }
  }

  /// Starts a reader session and registers the callbacks.
  ///
  /// `onDiscovered` is awaited before the platform touches the tag again, so tag I/O can be
  /// done inside it without racing the session.
  ///
  /// `onError` reports a session that ended without being asked to -- a timeout, the user
  /// dismissing the sheet, the tag going out of range. Both platforms raise it.
  ///
  /// Parameters carrying a platform suffix are ignored on the other platform.
  ///
  /// `skipNdefCheck` skips the NDEF probe at discovery: the platform's own probe on
  /// Android, and the `queryNDEFStatus` plus `readNDEF` round trips on iOS. Discovery gets
  /// measurably faster, at the cost of `Ndef.from(tag)` returning null. Use it when the
  /// tag's NDEF content does not interest you.
  ///
  /// Throws a `PlatformException` when the session cannot start, including
  /// `session_already_exists` when one is still running. Unlike 2.x, both platforms report
  /// that the same way; Android used to replace the running session in silence.
  Future<void> startSession({
    required Future<void> Function(NfcTag tag) onDiscovered,
    Future<void> Function(NfcError error)? onError,
    Set<NfcPollingOption>? pollingOptions,
    bool skipNdefCheck = false,

    /// iOS. Text shown on the system reader sheet.
    String? alertMessageIos,

    /// iOS. When false the session keeps polling after each tag, so one session reads many.
    bool invalidateAfterFirstReadIos = true,

    /// iOS. Called once the reader sheet is up and polling.
    void Function()? onBecameActiveIos,

    /// Android. Suppresses the system's tag-discovery sound.
    bool noPlatformSoundsAndroid = true,

    /// Android. Barcode (Kovio) tags are only discovered when this is set.
    bool discoverNfcBarcodeAndroid = false,

    /// Android. How long the platform waits between presence checks. 2.x hardcoded 250 ms.
    Duration presenceCheckDelayAndroid = const Duration(milliseconds: 250),
  }) async {
    // Armed before the call, not after it: Android brings reader mode up before its reply
    // reaches Dart, so a tag can be discovered while the handler would still be null.
    final restore = NfcCallbacks.instance.armSession(
      tag: onDiscovered,
      error: onError,
      active: onBecameActiveIos,
    );

    try {
      await nfcApi.startSession(
        SessionConfigPigeon(
          pollingOptions: (pollingOptions ?? NfcPollingOption.values.toSet()).map(pollingOptionToWire).toList(),
          alertMessage: alertMessageIos,
          invalidateAfterFirstRead: invalidateAfterFirstReadIos,
          noPlatformSounds: noPlatformSoundsAndroid,
          skipNdefCheck: skipNdefCheck,
          discoverNfcBarcode: discoverNfcBarcodeAndroid,
          presenceCheckDelayMillis: presenceCheckDelayAndroid.inMilliseconds,
        ),
      );
    } on Object {
      // Put back whatever was armed before. A failed start must not leave callbacks armed
      // for a session that never began -- and, when the refusal was `session_already_exists`,
      // must not leave the session that *is* running deaf to its own tags and errors.
      restore();
      rethrow;
    }
  }

  /// Stops the session and unregisters the callbacks.
  ///
  /// On iOS `errorMessageIos` wins over `alertMessageIos` when both are given: the sheet
  /// shows one or the other.
  ///
  /// This is a cleanup call and never throws. The callbacks are unregistered even when the
  /// platform reports a failure, because by then the session is gone either way.
  Future<void> stopSession({String? alertMessageIos, String? errorMessageIos}) async {
    NfcCallbacks.instance.clearSession();
    try {
      await nfcApi.stopSession(alertMessageIos, errorMessageIos);
    } on Object {
      // The session may already be gone: timed out, cancelled, or the engine detached.
    }
  }
}
