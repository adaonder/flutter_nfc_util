/// The Android surface: everything `android.nfc` offers and this package exposes.
///
/// Every symbol here throws on iOS. Import it with a prefix when you also import
/// `package:nfc_util/ios.dart`.
///
/// ```dart
/// import 'package:nfc_util/android.dart' as android;
///
/// final classic = android.MifareClassic.from(tag);
/// if (classic != null && await classic.authenticateSectorWithKeyA(sectorIndex: 1, key: key)) {
///   print(await classic.readBlock(blockIndex: 4));
/// }
/// ```
library;

export 'src/android/hce.dart' show HostCardEmulation, PollingFrame, PollingFrameType;
export 'src/android/platform.dart'
    show
        NfcAntennaInfo,
        NfcAntennaLocation,
        NfcEvent,
        NfcEventKind,
        NfcInternalError,
        NfcListenTech,
        NfcPollTech,
        NfcReaderFlag,
        NfcUtilAndroid,
        TagIntentSetup;
export 'src/android/tags.dart'
    show
        IsoDep,
        MifareClassic,
        MifareClassicType,
        MifareUltralight,
        MifareUltralightType,
        NdefAndroid,
        NdefFormatable,
        NfcA,
        NfcB,
        NfcBarcode,
        NfcBarcodeType,
        NfcF,
        NfcV;
