import 'dart:async';
import 'dart:typed_data';

import 'api.dart';
import 'common.dart';
import 'mapping.dart';
import 'pigeon.g.dart';

/// The single implementation of the generated platform-to-Dart interface.
///
/// Pigeon allows exactly one registered handler per channel, but the callbacks belong to
/// four different public objects: the cross-platform session, the Android platform object,
/// the iOS platform object, and host card emulation. They all register a handler here
/// instead, and this routes.
///
/// Registration is lazy -- [instance] installs the handler on first touch -- and every
/// public entry point touches it before the platform can call back, so no event can arrive
/// before the router exists.
class NfcCallbacks implements NfcFlutterApi {
  NfcCallbacks._() {
    NfcFlutterApi.setUp(this);
  }

  static NfcCallbacks? _instance;

  static NfcCallbacks get instance => _instance ??= NfcCallbacks._();

  // A reader session and a Value Added Services session are two independent objects on iOS,
  // begun and torn down separately. They therefore get separate slots: sharing them meant
  // stopping one silently unregistered the other's callbacks while it was still running.

  /// The tag callback of whichever reader session is running.
  Future<void> Function(NfcTag tag)? tagHandler;

  /// The error callback of whichever reader session is running.
  Future<void> Function(NfcError error)? errorHandler;

  /// iOS. Called once the reader sheet is up and polling.
  void Function()? sessionActiveHandler;

  /// The error callback of a running VAS session.
  Future<void> Function(NfcError error)? vasErrorHandler;

  /// iOS. Called once the VAS sheet is up.
  void Function()? vasActiveHandler;

  /// iOS. Wallet passes matched by a VAS session.
  void Function(List<VasResponsePigeon> responses)? vasHandler;

  /// Android. An APDU arrived for the emulated card.
  void Function(Uint8List apdu)? apduHandler;

  /// Android. The emulated card was deactivated.
  void Function(int reason)? hceDeactivatedHandler;

  /// Android. A tag arrived by intent rather than by a reader session.
  Future<void> Function(NfcTag tag)? intentTagHandler;

  /// iOS. An NDEF message arrived from background tag reading.
  void Function(NdefMessagePigeon message)? backgroundNdefHandler;

  /// Broadcast, and never closed: the router is process-wide, so closing it would break
  /// every later listener. Fed on Android only; iOS has no NFC toggle to watch.
  final StreamController<NfcAdapterState> adapterState = StreamController<NfcAdapterState>.broadcast();

  @override
  Future<void> onDiscovered(TagPigeon tag) => _deliver(tagHandler, tag);

  @override
  Future<void> onTagFromIntent(TagPigeon tag) => _deliver(intentTagHandler, tag);

  /// Hands [tag] to [handler] and then releases the native handle.
  ///
  /// The platform waits for this future, which is the point: a continuous iOS session must
  /// not restart polling -- and so drop the tag -- while the app is still reading it.
  Future<void> _deliver(Future<void> Function(NfcTag)? handler, TagPigeon tag) async {
    if (handler == null) {
      // Nothing will use it, so release it now rather than leaving it in the platform's map
      // until the session ends.
      await _dispose(tag.handle);
      return;
    }

    try {
      await handler(NfcTag(tag));
    } finally {
      await _dispose(tag.handle);
    }
  }

  /// Best effort: the session may already be gone, and throwing here would mask whatever
  /// the app's own callback threw.
  Future<void> _dispose(String handle) async {
    try {
      await nfcApi.disposeTag(handle);
    } on Object {
      // The tag map is cleared on session teardown regardless.
    }
  }

  @override
  void onError(SessionKindPigeon kind, NfcErrorPigeon error) {
    final handler = kind == SessionKindPigeon.vas ? vasErrorHandler : errorHandler;
    handler?.call(errorFromWire(error));
  }

  @override
  void onSessionBecameActive(SessionKindPigeon kind) {
    (kind == SessionKindPigeon.vas ? vasActiveHandler : sessionActiveHandler)?.call();
  }

  @override
  void onAdapterStateChanged(AdapterStatePigeon state) {
    adapterState.add(adapterStateFromWire(state));
  }

  @override
  void onVasResponse(List<VasResponsePigeon> responses) {
    vasHandler?.call(responses);
  }

  @override
  void onApduReceived(Uint8List apdu) {
    apduHandler?.call(apdu);
  }

  @override
  void onHceDeactivated(int reason) {
    hceDeactivatedHandler?.call(reason);
  }

  @override
  void onNdefFromBackground(NdefMessagePigeon message) {
    backgroundNdefHandler?.call(message);
  }

  /// Arms the reader-session handlers, returning a function that puts back whatever was
  /// there before.
  ///
  /// A start the platform refuses must not leave the session that is *still running* deaf.
  /// Both platforms now reject a second `startSession` outright, and without this the guard
  /// would be worse than the silent replacement it replaced: the old session would keep the
  /// radio and keep delivering, while its callbacks had been overwritten and then cleared.
  void Function() armSession({
    Future<void> Function(NfcTag tag)? tag,
    Future<void> Function(NfcError error)? error,
    void Function()? active,
  }) {
    final previousTag = tagHandler;
    final previousError = errorHandler;
    final previousActive = sessionActiveHandler;

    tagHandler = tag;
    errorHandler = error;
    sessionActiveHandler = active;

    return () {
      tagHandler = previousTag;
      errorHandler = previousError;
      sessionActiveHandler = previousActive;
    };
  }

  /// Arms the VAS handlers, returning a function that puts back whatever was there before.
  void Function() armVasSession({
    void Function(List<VasResponsePigeon> responses)? response,
    Future<void> Function(NfcError error)? error,
    void Function()? active,
  }) {
    final previousResponse = vasHandler;
    final previousError = vasErrorHandler;
    final previousActive = vasActiveHandler;

    vasHandler = response;
    vasErrorHandler = error;
    vasActiveHandler = active;

    return () {
      vasHandler = previousResponse;
      vasErrorHandler = previousError;
      vasActiveHandler = previousActive;
    };
  }

  /// Clears what a reader session owns, leaving the VAS slots and the long-lived handlers --
  /// adapter state, host card emulation, intent delivery -- registered.
  void clearSession() {
    tagHandler = null;
    errorHandler = null;
    sessionActiveHandler = null;
  }

  /// Clears what a VAS session owns.
  void clearVasSession() {
    vasHandler = null;
    vasErrorHandler = null;
    vasActiveHandler = null;
  }
}
