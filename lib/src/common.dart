import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'pigeon.g.dart';

/// One tag, discovered by a reader session or delivered by an intent.
///
/// **A tag is addressable only inside the callback that delivered it** -- `onDiscovered`, or
/// Android's `onTagFromIntent`. The native handle is released as soon as that callback's
/// future completes, so do the tag I/O inside it. The callback is awaited before the
/// platform touches the tag again, so there is no rush; but a tag stored for a later screen
/// fails with `invalidParameter` even though the session is still open.
///
/// What was copied at discovery stays readable afterwards -- [id], [techList] and
/// `Ndef.from(tag)?.cachedMessage` -- so keeping the tag as a record of the scan is fine.
///
/// Reach the technology-specific operations through the `from` constructors in
/// `package:nfc_util/android.dart` and `package:nfc_util/ios.dart`:
///
/// ```dart
/// final ndef = Ndef.from(tag);
/// if (ndef == null) return; // not an NDEF tag
/// final message = await ndef.read();
/// ```
class NfcTag {
  /// Wraps platform data.
  ///
  /// Only an instance delivered by the platform addresses a tag that is actually in the field;
  /// one built here is inert, which is exactly what makes it useful for exercising the
  /// `from` constructors in tests.
  const NfcTag(this.data);

  /// The raw platform payload.
  ///
  /// Public so the technology classes in the platform libraries can read it; not part of
  /// the supported surface, and its shape changes without a major version.
  @internal
  final TagPigeon data;

  /// The plugin's identifier for this tag, used internally to address it.
  String get handle => data.handle;

  /// The tag UID, when it reports one.
  ///
  /// On Android this is `Tag.getId()`, which every technology on the tag shares. On iOS it
  /// is the identifier of whichever protocol matched.
  Uint8List? get id => data.id;

  /// The `android.nfc.tech` classes this tag answers to, as short names such as `NfcA` or
  /// `MifareClassic`. Empty on iOS, which has no equivalent listing.
  List<String> get techList => data.techList ?? const [];

  @override
  String toString() => 'NfcTag(${id == null ? 'no id' : _hex(id!)}${techList.isEmpty ? '' : ', $techList'})';
}

/// The `code` on a `PlatformException` from a call that never reached a tag.
///
/// Every *tag operation* fails with a code that spells an [NfcAndroidErrorCode] or an
/// [NfcReaderErrorCode] value, so `NfcAndroidErrorCode.values.byName(e.code)` resolves it.
/// These three describe the session itself and name no enum value, so they are given here
/// rather than left as literals for callers to retype.
abstract final class NfcErrorCodes {
  /// The device has no NFC adapter, the radio is unusable, or the platform refused to start
  /// the session at all.
  static const String unavailable = 'unavailable';

  /// A session is already running. Stop it before starting another; both platforms refuse
  /// rather than replacing it.
  static const String sessionAlreadyExists = 'session_already_exists';

  /// Android only. The plugin is attached to an engine but not to an activity, which is the
  /// window between a configuration change tearing one down and the next being attached.
  static const String noActivity = 'no_activity';
}

/// Whether NFC can be used on this device right now.
enum NfcAvailability {
  /// NFC is present and switched on.
  enabled,

  /// The device has NFC but the user has switched it off.
  ///
  /// Android only. iOS exposes no such state, and reports [unsupported] instead.
  disabled,

  /// This device cannot do NFC.
  unsupported,
}

/// The kind of tag a session polls for.
enum NfcPollingOption {
  /// `iso14443` on iOS; `FLAG_READER_NFC_A` and `FLAG_READER_NFC_B` on Android.
  iso14443,

  /// `iso15693` on iOS; `FLAG_READER_NFC_V` on Android.
  iso15693,

  /// `iso18092` on iOS; `FLAG_READER_NFC_F` on Android.
  ///
  /// On iOS this option makes CoreNFC demand the
  /// `com.apple.developer.nfc.readersession.felica.systemcodes` entitlement. Without it the
  /// reader sheet never appears and the session fails asynchronously.
  iso18092,
}

/// The NFC adapter's power state. Android only.
enum NfcAdapterState {
  /// NFC is off.
  off,

  /// NFC is switching on. The adapter refuses work until it reaches [on].
  turningOn,

  /// NFC is on and ready.
  on,

  /// NFC is switching off.
  turningOff,
}

/// Which platform raised an [NfcError].
enum NfcErrorSource { android, ios }

/// A typed Android failure.
///
/// Every throwable the Android side can see maps to one of these, so a caller can tell a
/// tag that moved out of range from a tag that refused the command.
enum NfcAndroidErrorCode {
  /// The tag left the field mid-operation. Usually means "hold it still and retry".
  tagLost,

  /// The tag rejected the exchange, or the exchange failed at the transport level.
  io,

  /// The operation was refused, typically an unauthenticated Mifare Classic sector.
  security,

  /// The tag does not answer to the technology the call was made against.
  unsupportedTech,

  /// The tag could not be connected to at all.
  notConnected,

  /// The NFC adapter is off or missing.
  adapterDisabled,

  /// The arguments were rejected before reaching the tag.
  invalidParameter,

  /// Something the plugin does not classify. Read [NfcError.message].
  unknown,
}

/// A CoreNFC `NFCReaderError.Code`. iOS only.
enum NfcReaderErrorCode {
  firstNdefTagRead,
  sessionTerminatedUnexpectedly,
  sessionTimeout,
  systemIsBusy,
  userCanceled,
  tagNotWritable,
  tagSizeTooSmall,
  tagUpdateFailure,
  zeroLengthMessage,
  retryExceeded,
  tagConnectionLost,
  tagNotConnected,
  tagResponseError,
  sessionInvalidated,
  packetTooLong,
  invalidParameters,
  unsupportedFeature,
  invalidParameter,
  invalidParameterLength,
  parameterOutOfBound,
  radioDisabled,
  securityViolation,

  /// Requires iOS 26.
  ineligible,

  /// Requires iOS 26.
  accessNotAccepted,

  /// CoreNFC reported a code this version does not name. Read [NfcError.message].
  unknown,
}

/// A session ended for a reason the app did not ask for.
///
/// Both platforms raise this. In 2.x only iOS did, so an Android tag that went out of range
/// mid-read surfaced as a bare exception on the operation and nothing on the session.
class NfcError {
  /// Constructs an error. Sessions deliver these; build one directly in tests.
  const NfcError({
    required this.source,
    required this.message,
    required this.sessionEnded,
    this.iosCode,
    this.androidCode,
  });

  /// Whether the session is over, or merely had one thing go wrong inside it.
  ///
  /// Restart only when this is true. Every CoreNFC failure ends the session, but on Android
  /// a tag that could not be read leaves reader mode polling -- and calling `startSession`
  /// again there is refused with `session_already_exists`, which would leave the app deaf.
  final bool sessionEnded;

  /// Which platform raised it, and therefore which of the two code fields is set.
  final NfcErrorSource source;

  /// The CoreNFC code. Null unless [source] is [NfcErrorSource.ios].
  final NfcReaderErrorCode? iosCode;

  /// The Android code. Null unless [source] is [NfcErrorSource.android].
  final NfcAndroidErrorCode? androidCode;

  /// The platform's description.
  final String message;

  @override
  String toString() =>
      'NfcError(${source.name}, ${iosCode?.name ?? androidCode?.name}, '
      '${sessionEnded ? 'session ended' : 'session alive'}, $message)';
}

String _hex(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
