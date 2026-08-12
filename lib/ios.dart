/// The iOS surface: everything CoreNFC offers and this package exposes.
///
/// Every symbol here throws on Android. Import it with a prefix when you also import
/// `package:nfc_util/android.dart`.
///
/// ```dart
/// import 'package:nfc_util/ios.dart' as ios;
///
/// final card = ios.Iso7816.from(tag);
/// final response = await card?.sendCommandRaw(selectApdu);
/// if (response != null && response.isSuccess) print(response.payload);
/// ```
library;

export 'src/ios/platform.dart'
    show NfcUtilIos, VasCommandConfiguration, VasMode, VasResponse, VasResponseErrorCode;
export 'src/ios/tags.dart'
    show
        FeliCa,
        FeliCaPollingRequestCode,
        FeliCaPollingResponse,
        FeliCaPollingTimeSlot,
        FeliCaReadWithoutEncryptionResponse,
        FeliCaRequestServiceV2Response,
        FeliCaRequestSpecificationVersionResponse,
        FeliCaStatusFlag,
        Iso15693,
        Iso15693RequestFlag,
        Iso15693SystemInfo,
        Iso7816,
        Iso7816ResponseApdu,
        MiFare,
        MiFareFamily,
        NdefIos,
        NdefStatus,
        QueryNdefStatusResponse;
