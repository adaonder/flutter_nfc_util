import 'dart:typed_data';

import '../api.dart';
import '../callbacks.dart';
import '../common.dart';
import '../mapping.dart';
import '../ndef/message.dart';
import '../pigeon.g.dart';
import 'tags.dart';

/// How a VAS command asks for a pass.
enum VasMode {
  /// Ask for the pass payload.
  normal,

  /// Ask only for the URL, without the pass data.
  urlOnly,
}

/// Why a VAS command did not return a pass.
enum VasResponseErrorCode {
  /// The pass was returned.
  success,

  /// The user has to act on the device before the pass can be read.
  userIntervention,

  /// The pass exists but is not active.
  dataNotActivated,

  /// No matching pass is installed.
  dataNotFound,

  incorrectData,
  unsupportedApplicationVersion,
  wrongLcField,
  wrongParameters,
}

/// One pass to ask the wallet for.
class VasCommandConfiguration {
  const VasCommandConfiguration({required this.passTypeIdentifier, this.mode = VasMode.normal, this.url});

  /// The pass type identifier, as registered with Apple.
  final String passTypeIdentifier;

  /// Whether to ask for the payload or only the URL.
  final VasMode mode;

  /// The URL handed to the wallet when no matching pass is installed, so the user can be
  /// offered one.
  final String? url;
}

/// One wallet pass, or the reason there was none.
class VasResponse {
  const VasResponse({required this.status, required this.vasData, required this.mobileToken});

  /// Whether the pass was returned, and if not, why not.
  final VasResponseErrorCode status;

  /// The pass payload. Empty unless [status] is [VasResponseErrorCode.success].
  final Uint8List vasData;

  /// The token identifying the device that answered.
  final Uint8List mobileToken;
}

/// The raw iOS surface.
///
/// Everything here is iOS-only; on Android these calls throw. The cross-platform
/// [NfcUtil] covers the common path, and this covers what it deliberately does not
/// express -- above all Apple Value Added Services, which has no Android counterpart.
class NfcUtilIos {
  NfcUtilIos._();

  static NfcUtilIos? _instance;

  static NfcUtilIos get instance => _instance ??= NfcUtilIos._();

  /// Whether this device can run a tag reader session at all.
  ///
  /// False on an iPhone older than the 7, and in the Simulator.
  Future<bool> tagSessionReadingAvailable() => iosApi.tagSessionReadingAvailable();

  /// Changes the text on the reader sheet while the session is running.
  ///
  /// Useful for narrating a multi-step exchange: "hold still", then "writing".
  Future<void> tagSessionSetAlertMessage(String alertMessage) => iosApi.tagSessionSetAlertMessage(alertMessage);

  /// Drops the current tag and starts polling again, without taking the reader sheet down.
  ///
  /// A session started with `invalidateAfterFirstReadIos: false` already does this after
  /// each tag; call it directly to move on from a tag early.
  Future<void> tagSessionRestartPolling() => iosApi.tagSessionRestartPolling();

  /// Whether this device can run a VAS session.
  Future<bool> vasSessionReadingAvailable() => iosApi.vasSessionReadingAvailable();

  /// Starts a Value Added Services session, which reads Apple Wallet passes -- loyalty
  /// cards, membership cards -- rather than NFC tags.
  ///
  /// Requires `com.apple.developer.nfc.readersession.formats` to include `VAS` in the app's
  /// *entitlements file*, which is not part of Xcode's Near Field Communication Tag Reading
  /// capability -- the App ID has to be provisioned for VAS separately -- plus
  /// `NFCReaderUsageDescription` in `Info.plist`. Nothing else: the pass type identifiers
  /// are supplied per command through [VasCommandConfiguration.passTypeIdentifier], not by
  /// any plist key. A missing entitlement surfaces asynchronously through `onError` as a
  /// security violation. See the README's iOS setup list.
  Future<void> vasSessionBegin({
    required List<VasCommandConfiguration> configurations,
    required void Function(List<VasResponse> responses) onResponse,
    Future<void> Function(NfcError error)? onError,
    void Function()? onBecameActive,
    String? alertMessage,
  }) async {
    // The VAS slots are separate from the reader session's: iOS runs the two as independent
    // session objects, and sharing the slots meant stopping one unregistered the other's
    // callbacks while it was still up.
    final restore = NfcCallbacks.instance.armVasSession(
      response: (responses) => onResponse([
        for (final response in responses)
          VasResponse(
            status: _statusFromWire(response.status),
            vasData: response.vasData,
            mobileToken: response.mobileToken,
          ),
      ]),
      error: onError,
      active: onBecameActive,
    );

    try {
      await iosApi.vasSessionBegin([
        for (final configuration in configurations)
          VasCommandConfigurationPigeon(
            mode: switch (configuration.mode) {
              VasMode.normal => VasModePigeon.normal,
              VasMode.urlOnly => VasModePigeon.urlOnly,
            },
            passTypeIdentifier: configuration.passTypeIdentifier,
            url: configuration.url,
          ),
      ], alertMessage);
    } on Object {
      // Only the VAS slots, and only back to what they were: an empty configuration list or
      // a device without VAS fails here without any session having been disturbed.
      restore();
      rethrow;
    }
  }

  /// Ends a VAS session. Never throws; the session may already be gone.
  Future<void> vasSessionInvalidate({String? alertMessage, String? errorMessage}) async {
    NfcCallbacks.instance.clearVasSession();
    try {
      await iosApi.vasSessionInvalidate(alertMessage, errorMessage);
    } on Object {
      // Cleanup call.
    }
  }

  /// Changes the text on a running VAS session's sheet.
  Future<void> vasSessionSetAlertMessage(String alertMessage) => iosApi.vasSessionSetAlertMessage(alertMessage);

  /// NDEF messages delivered by iOS background tag reading.
  ///
  /// iPhone XS and later read NDEF tags with no app running and no code in the app; the
  /// message arrives as a user activity. This only fires when the tag holds a URL that
  /// matches one of the app's associated domains. See the README.
  set onNdefFromBackground(void Function(NdefMessage message)? handler) {
    NfcCallbacks.instance.backgroundNdefHandler = handler == null
        ? null
        : (message) => handler(ndefMessageFromWire(message));
  }

  /// The NDEF message that launched the app, if it was launched by a background tag read.
  ///
  /// Consumed by the first call, so a widget rebuild cannot process it twice.
  Future<NdefMessage?> takeInitialNdefMessage() async {
    final message = await iosApi.takeInitialNdefMessage();
    return message == null ? null : ndefMessageFromWire(message);
  }

  /// The tag's live NDEF status, as opposed to the copy captured at discovery.
  ///
  /// Prefer `Ndef.from(tag)` unless you specifically need to re-check after writing.
  Future<QueryNdefStatusResponse> ndefQueryStatus(String handle) async {
    final response = await iosApi.ndefQueryStatus(handle);
    return QueryNdefStatusResponse(status: ndefStatusFromWire(response.status), capacity: response.capacity);
  }

  static VasResponseErrorCode _statusFromWire(VasResponseErrorCodePigeon value) => switch (value) {
    VasResponseErrorCodePigeon.success => VasResponseErrorCode.success,
    VasResponseErrorCodePigeon.userIntervention => VasResponseErrorCode.userIntervention,
    VasResponseErrorCodePigeon.dataNotActivated => VasResponseErrorCode.dataNotActivated,
    VasResponseErrorCodePigeon.dataNotFound => VasResponseErrorCode.dataNotFound,
    VasResponseErrorCodePigeon.incorrectData => VasResponseErrorCode.incorrectData,
    VasResponseErrorCodePigeon.unsupportedApplicationVersion => VasResponseErrorCode.unsupportedApplicationVersion,
    VasResponseErrorCodePigeon.wrongLcField => VasResponseErrorCode.wrongLcField,
    VasResponseErrorCodePigeon.wrongParameters => VasResponseErrorCode.wrongParameters,
  };
}
