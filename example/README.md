# nfc_util example

Every feature of the package, one button each, in [lib/main.dart](lib/main.dart). The file
opens with a map from each button to the method it calls.

## What you need to run it

NFC needs hardware, so most of this app does nothing on a simulator or emulator — neither
one has a radio. **"Build & decode NDEF" is the exception**: it builds a message with all
five record types and decodes it again in pure Dart, with no tag, no session and no radio,
so it works everywhere including the widget tests.

For the rest you need a physical phone with NFC switched on, and a tag. Any cheap NTAG213
sticker exercises read, write and the smart poster; Mifare Classic and FeliCa cards light up
the extra rows under "Inspect tag".

Two actions need more than hardware:

| Action | Also needs |
|---|---|
| Wallet pass (iOS) | The pass-reading entitlement, which Apple grants per app. Without it the button reports that VAS is unavailable rather than pretending. |
| Emulate card (Android) | Nothing extra — but it **changes device state that survives a reboot**. The app unregisters on exit; if it is force-killed, run it again and press "Stop emulating". |

## The native setup

The Dart is only half of it. What makes a tag reach the app at all lives in three files,
each commented where it matters:

- `android/app/src/main/AndroidManifest.xml` — the intent filters that let a tag launch the app
- `ios/Runner/Info.plist` — the usage description and the ISO 7816 / FeliCa identifier lists
- `ios/Runner/Runner.entitlements` — the NFC formats the app is allowed to read

The FeliCa system-code list in `Info.plist` is the one most people miss: CoreNFC refuses to
start a session that polls for FeliCa unless it is filled in. That is why "Scan many" names
`pollingOptions` explicitly instead of taking the default.

## Running it

```
flutter run
```

The unit tests that cover the package itself are in the repository root (`flutter test`
there). In this directory `flutter test` runs the widget tests, and
`flutter test integration_test -d <device>` runs the on-device checks.
