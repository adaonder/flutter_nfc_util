# nfc_util

A Flutter plugin providing access to NFC features on Android and iOS.

## Setup

### Android

* Add [android.permission.NFC](https://developer.android.com/reference/android/Manifest.permission.html#NFC) to your AndroidManifest.xml.


### iOS

* Add [Near Field Communication Tag Reader Session Formats Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_developer_nfc_readersession_formats) to your entitlements.
* Add NFCReaderUsageDescription to your Info.plist.
* Add com.apple.developer.nfc.readersession.iso7816.select-identifiers to your Info.plist as needed.
* Add com.apple.developer.nfc.readersession.felica.systemcodes to your Info.plist if you specify NfcPollingOption.iso18092 in startSession, otherwise an error will occur.