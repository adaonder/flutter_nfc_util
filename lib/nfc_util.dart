/// Cross-platform NFC.
///
/// This library is the common path: check availability, run a reader session, get tags.
/// Anything platform-specific lives one import away and is never hidden behind this one:
///
/// * `package:nfc_util/android.dart` -- reader flags, adapter state, secure NFC,
///   foreground dispatch, tags delivered by intent, host card emulation, and the
///   `android.nfc.tech` classes.
/// * `package:nfc_util/ios.dart` -- alert messages, polling control, Apple Value Added
///   Services, background NDEF delivery, and the CoreNFC tag protocols.
/// * `package:nfc_util/ndef.dart` -- NDEF values, the wire codec, and typed records.
///
/// The two platform libraries can be imported together; give at least one a prefix, since
/// both name a handful of the same concepts.
///
/// ```dart
/// import 'package:nfc_util/nfc_util.dart';
/// import 'package:nfc_util/ndef.dart';
/// import 'package:nfc_util/android.dart' as android;
///
/// await NfcUtil.instance.startSession(
///   onDiscovered: (tag) async {
///     final classic = android.MifareClassic.from(tag);
///     if (classic != null) {
///       await classic.authenticateSectorWithKeyA(sectorIndex: 0, key: key);
///     }
///     await NfcUtil.instance.stopSession();
///   },
/// );
/// ```
library;

export 'src/common.dart'
    show
        NfcAdapterState,
        NfcAndroidErrorCode,
        NfcAvailability,
        NfcErrorCodes,
        NfcError,
        NfcErrorSource,
        NfcPollingOption,
        NfcReaderErrorCode,
        NfcTag;
export 'src/session.dart' show NfcUtil;
