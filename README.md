# nfc_util

A Flutter plugin providing access to NFC features on Android and iOS.

## Setup

### Android

* Add [android.permission.NFC](https://developer.android.com/reference/android/Manifest.permission.html#NFC) to your AndroidManifest.xml.


### iOS

* Add [Near Field Communication Tag Reader Session Formats Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_developer_nfc_readersession_formats) to your entitlements.
* Add [NFCReaderUsageDescription](https://developer.apple.com/documentation/bundleresources/information_property_list/nfcreaderusagedescription) to your `Info.plist`.
* Add com.apple.developer.nfc.readersession.iso7816.select-identifiers to your Info.plist as needed.
* Add [com.apple.developer.nfc.readersession.felica.systemcodes](https://developer.apple.com/documentation/bundleresources/information_property_list/systemcodes) and [com.apple.developer.nfc.readersession.iso7816.select-identifiers](https://developer.apple.com/documentation/bundleresources/information_property_list/select-identifiers) to your `Info.plist` as needed.


## Usage

**Handling Session**

```dart
// Check availability
bool isAvailable = await NfcManager.instance.isAvailable();

// Start Session
NfcManager.instance.startSession(
  onDiscovered: (NfcTag tag) async {
    // Do something with an NfcTag instance.
  },
);

// Stop Session
NfcManager.instance.stopSession();
```

**Handling Platform Tag**

The following platform-tag-classes are available:

* Ndef
* FeliCa (iOS only)
* Iso7816 (iOS only)
* Iso15693 (iOS only)
* MiFare (iOS only)
* NfcA (Android only)
* NfcB (Android only)
* NfcF (Android only)
* NfcV (Android only)
* IsoDep (Android only)
* MifareClassic (Android only)
* MifareUtralight (Android only)
* NdefFormatable (Android only)

Obtain an instance by calling the factory constructor `from` on the class. For example:

```dart
Ndef? ndef = Ndef.from(tag);

if (ndef == null) {
  print('Tag is not compatible with NDEF');
  return;
}

// Do something with an Ndef instance
```



## ✨ Overview

This plugin was created to:

- Provide an **actively maintained** alternative NFC plugin
- Support newer Flutter, Android, and iOS versions
- Allow independent updates without relying on the original package
- Keep the API familiar for developers already using `nfc_manager`

Android and iOS implementations are included as **separate, fully integrated platform modules** within this plugin.

---

## ✨ What’s New Compared to nfc_manager v3.5.0

- Updated Android and iOS platform implementations
- Improved NFC session handling and lifecycle management
- Better compatibility with recent Flutter and SDK versions
- Codebase cleanup and structural improvements

See **CHANGELOG.md** for detailed changes.

---
