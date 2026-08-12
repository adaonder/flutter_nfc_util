# nfc_util

NFC for Flutter on Android and iOS: reader sessions, every tag technology both platforms
expose, a real NDEF layer, background tag reading, host card emulation, and Apple Wallet
passes.

```dart
await NfcUtil.instance.startSession(
  onDiscovered: (tag) async {
    final message = await Ndef.from(tag)?.read();
    for (final record in message?.records ?? const []) {
      print(TextRecord.from(record)?.text);
    }
    await NfcUtil.instance.stopSession();
  },
);
```

## What it does

| | Android | iOS |
|---|---|---|
| Reader sessions | `enableReaderMode` | `NFCTagReaderSession` |
| NDEF read / write / lock | ✅ | ✅ |
| NDEF format (unformatted tag) | ✅ | — CoreNFC has no equivalent |
| NDEF wire codec, typed records | ✅ pure Dart, works with no tag | ✅ |
| NfcA / NfcB / NfcF / NfcV / IsoDep | ✅ | — reachable as the CoreNFC protocols |
| Mifare Classic | ✅ auth, blocks, value ops, geometry | — Apple does not allow it |
| Mifare Ultralight | ✅ | ✅ via `MiFare` |
| FeliCa | ✅ via `NfcF` | ✅ 10 typed commands |
| ISO 15693 | ✅ via `NfcV` | ✅ 19 typed commands |
| ISO 7816 | ✅ via `IsoDep` | ✅ |
| Barcode (Kovio) tags | ✅ | — |
| Background / launch-on-tag reading | ✅ intent filters | ✅ NDEF user activity |
| Host card emulation | ✅ runtime AID registration | — not available to third-party apps |
| Apple Value Added Services | — | ✅ Wallet passes |
| Adapter state stream, secure NFC | ✅ | — no such state on iOS |
| Typed errors | ✅ 8 codes | ✅ 24 CoreNFC codes |

## Install

```yaml
dependencies:
  nfc_util: ^3.0.0
```

Requires Flutter 3.44, Android API 24, iOS 15.6.

## Setup

### Android

The plugin declares `android.permission.NFC` and its card emulation service itself, so a
reader-only app needs nothing. Two features need app-side declarations:

**Background tag reading** — the intent filters name *your* activity, so only your manifest
can declare them. Add to the launcher activity, which must be `android:launchMode="singleTop"`
or a tap starts a second copy instead of delivering to the running one:

```xml
<intent-filter>
    <action android:name="android.nfc.action.NDEF_DISCOVERED"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <data android:mimeType="text/plain"/>
</intent-filter>
<intent-filter>
    <action android:name="android.nfc.action.TECH_DISCOVERED"/>
</intent-filter>
<meta-data
    android:name="android.nfc.action.TECH_DISCOVERED"
    android:resource="@xml/nfc_tech_filter"/>
```

with `res/xml/nfc_tech_filter.xml` listing the technologies you handle — see
[the example](example/android/app/src/main/res/xml/nfc_tech_filter.xml). Trim it: every
technology you list makes your app an option on every matching tap.

**Card emulation description** — the string shown in the system's "Tap and pay" settings
defaults to "NFC card emulation". Override it by declaring `nfc_util_hce_description` in
your own `strings.xml`.

### iOS

1. Turn on the **Near Field Communication Tag Reading** capability in Xcode.
2. `Info.plist` needs `NFCReaderUsageDescription`.
3. Polling `iso18092` — which `startSession` does by default — makes CoreNFC demand
   `com.apple.developer.nfc.readersession.felica.systemcodes` in `Info.plist`. **Without
   it the reader sheet simply never appears**, `startSession` still returns normally, and
   the failure arrives asynchronously. Either add the key or drop `iso18092` from
   `pollingOptions`. This is the single most common iOS setup mistake.
4. ISO 7816 tags additionally need
   `com.apple.developer.nfc.readersession.iso7816.select-identifiers`.
5. Wallet passes need `VAS` in `com.apple.developer.nfc.readersession.formats`, enabled on
   the App ID in the developer portal too.

## The four libraries

Portability is told by the import path rather than by a suffix on every class name.

```dart
import 'package:nfc_util/nfc_util.dart';          // NfcUtil, NfcTag, NfcError
import 'package:nfc_util/ndef.dart';              // Ndef, NdefMessage, typed records
import 'package:nfc_util/android.dart' as android; // android.nfc
import 'package:nfc_util/ios.dart' as ios;         // CoreNFC
```

Nothing is hidden behind the cross-platform façade: `NfcUtil` is a thin adapter, and
`NfcUtilAndroid` / `NfcUtilIos` are always reachable for what it does not express.

## Sessions

```dart
if (await NfcUtil.instance.checkAvailability() != NfcAvailability.enabled) return;

await NfcUtil.instance.startSession(
  onDiscovered: (tag) async { /* awaited before the platform touches the tag again */ },
  onError: (error) async => print(error),   // both platforms raise this
  pollingOptions: {NfcPollingOption.iso14443},
  skipNdefCheck: true,                      // faster discovery when NDEF does not interest you
  alertMessageIos: 'Hold your phone near the tag',
);
```

`checkAvailability` separates "no NFC hardware" from "the user switched NFC off", so an app
can offer *open settings* only when that would help. It never throws.

Parameters carrying a platform suffix are ignored on the other platform. A session already
running is rejected with `session_already_exists` on **both** platforms.

**One session, many tags:** pass `invalidateAfterFirstReadIos: false`. iOS restarts polling
only after your `onDiscovered` returns, so the tag is never pulled out from under an app
that is still reading it.

## NDEF

The record types both build and parse, and the codec is pure Dart — a message can be
assembled or decoded with no tag in range, which is what host card emulation and intent
payloads need.

```dart
final message = NdefMessage([
  TextRecord.create('merhaba', languageCode: 'tr'),
  UriRecord.create(Uri.parse('https://example.com')),
  SmartPosterRecord.create(uri: uri, title: 'Kampanya', action: SmartPosterAction.execute),
]);

final ndef = Ndef.from(tag);
if (ndef != null && ndef.isWritable && message.byteLength <= ndef.maxSize) {
  await ndef.write(message);
}

for (final record in (await ndef!.read())?.records ?? const []) {
  final text = TextRecord.from(record);
  if (text != null) print('${text.languageCode}: ${text.text}');
}

final bytes = message.toBytes();               // NFC Forum wire format
final decoded = NdefMessage.fromBytes(bytes);  // chunked records are reassembled
```

`TextRecord`, `UriRecord`, `SmartPosterRecord`, `MimeRecord` and `ExternalRecord` each have
a `create` and a `from`, and `from` returns null rather than throwing on a record of another
kind.

## Tag technologies

```dart
final classic = android.MifareClassic.from(tag);
if (classic != null && await classic.authenticateSectorWithKeyA(sectorIndex: 1, key: key)) {
  final block = await classic.sectorToBlock(sectorIndex: 1);
  print(await classic.readBlock(blockIndex: block));
}

final card = ios.Iso7816.from(tag);
final response = await card?.sendCommandRaw(apdu);
if (response?.isSuccess ?? false) print(response!.payload);
```

Every class has `from(tag)`, returning null when the tag does not answer to it. Fields are
captured at discovery; anything needing a round trip is a `Future` method.

The Android connection is opened once and held for the session, so a Mifare Classic sector
authentication still applies to the reads that follow it.

## Background tag reading

```dart
// Android: the tag that launched the app, consumed by the first call.
final tag = await android.NfcUtilAndroid.instance.takeInitialTag();

// Android: tags arriving while the app runs.
android.NfcUtilAndroid.instance.onTagFromIntent = (tag) async { /* ... */ };

// Android: claim tags while your app is on screen, so another app cannot take them.
await android.NfcUtilAndroid.instance.enableForegroundDispatch();

// iOS: iPhone XS and later read NDEF tags with no app running. Needs associated domains
// and a tag holding a matching URL.
ios.NfcUtilIos.instance.onNdefFromBackground = (message) { /* ... */ };
final launched = await ios.NfcUtilIos.instance.takeInitialNdefMessage();
```

## Host card emulation

The phone answers a reader as if it were a card. Android only — Apple's equivalent is behind
an entitlement that is not generally available.

```dart
final hce = android.HostCardEmulation.instance;
if (!await hce.isSupported()) return;

hce.onApduReceived = (apdu) {
  final isSelect = apdu.length > 1 && apdu[1] == 0xA4;
  hce.respond(Uint8List.fromList(isSelect ? [0x90, 0x00] : [0x6D, 0x00]));
};

await hce.registerAids(['F0010203040506']);
await hce.setPreferredService(true);   // while your app is in the foreground
```

AIDs are registered at run time, so the set can change without a release.

**This release bridges APDUs only while the Flutter engine is alive.** A tap with the app
fully stopped is answered with `6D00` rather than queued. Emulating a card while the app is
closed needs a background engine, which is not in 3.0.0.

## Apple Wallet passes

```dart
await ios.NfcUtilIos.instance.vasSessionBegin(
  configurations: [ios.VasCommandConfiguration(passTypeIdentifier: 'pass.com.example.loyalty')],
  onResponse: (responses) {
    for (final r in responses) {
      if (r.status == ios.VasResponseErrorCode.success) print(r.vasData);
    }
  },
);
```

## Errors

`onError` reports something going wrong with a session, on both platforms.

```dart
onError: (error) async {
  switch (error.source) {
    case NfcErrorSource.ios when error.iosCode == NfcReaderErrorCode.userCanceled:
      break;                                    // the user dismissed the sheet
    case NfcErrorSource.android when error.androidCode == NfcAndroidErrorCode.tagLost:
      showMessage('Hold the tag still');
    default:
      report(error.message);
  }

  // Only restart when the session is actually gone. Every CoreNFC failure ends it, but on
  // Android a tag that could not be read leaves reader mode polling -- and starting again
  // there is refused with `session_already_exists`, which would leave the app deaf.
  if (error.sessionEnded) await restart();
}
```

Tag operations throw `PlatformException` with the same codes. An error code this version
does not recognise degrades to `unknown` rather than throwing.

A reader session and a VAS session have separate callbacks: stopping one leaves the other's
`onError` and `onBecameActive` registered, and a start that the platform refuses puts back
whatever was armed before rather than clearing it.

## Testing

The NDEF layer is pure Dart and fully testable. For session logic, put a fake in place of
the generated host API — see [`test/session_test.dart`](test/session_test.dart).

In a widget test with no mock registered, a channel call never completes, so an app should
treat "availability unknown" as "not ready" rather than assuming a failure will arrive.

**What no test can cover, and what a physical device is needed for:** host card emulation
needs a reader and a second device; background reading needs the app closed; Wallet passes
need a real pass; `NFCTagReaderSession` will not start in the Simulator, and no emulator has
an NFC radio.

## Upgrading from 2.2.0

3.0.0 is a rewrite. Every import and most names changed, starting with the entry point.

| 2.2.0 | 3.0.0 |
|---|---|
| `NfcManager.instance` | `NfcUtil.instance` |
| `package:nfc_util/platform_tags.dart` | `package:nfc_util/android.dart`, `package:nfc_util/ios.dart` |
| `Ndef`, `NdefMessage`, `NdefRecord` from `nfc_util.dart` | `package:nfc_util/ndef.dart` |
| `NdefRecord.createText(...)` | `TextRecord.create(...)` |
| `NdefRecord.createUri/createMime/createExternal` | `UriRecord.create`, `MimeRecord.create`, `ExternalRecord.create` |
| `NdefTypeNameFormat.nfcWellknown` / `.nfcExternal` | `.wellKnown` / `.external` |
| `startSession(alertMessage:, invalidateAfterFirstRead:, noPlatformSounds:, discoverNfcBarcode:)` | same options, platform-suffixed: `alertMessageIos:`, `invalidateAfterFirstReadIos:`, `noPlatformSoundsAndroid:`, `discoverNfcBarcodeAndroid:` |
| `stopSession(alertMessage:, errorMessage:)` | `stopSession(alertMessageIos:, errorMessageIos:)` |
| `NfcManager.instance.onAdapterStateChanged` | `NfcUtilAndroid.instance.onAdapterStateChanged` |
| `NfcManager.instance.isSecureNfcSupported()` | `NfcUtilAndroid.instance.isSecureNfcSupported()` |
| `isAvailable()` (deprecated in 2.1.0) | removed — use `checkAvailability()` |
| `NfcError.type` (`NfcErrorType`) | removed — use `error.source` with `iosCode` / `androidCode`, and `sessionEnded` to decide whether to restart |
| `tag.data['nfca']['identifier']` | `tag.id` |
| `MifareClassic.type` (`int`) | `MifareClassicType` enum |
| `setTimeout(int)` / `timeout` as `int` | `Duration` |
| `Ndef.canMakeReadOnly` | `NdefAndroid.from(tag)?.canMakeReadOnly` |
| `onDiscovered` had no Android error channel | `onError` fires on both platforms |

New in 3.0.0 with no 2.2.0 equivalent: the NDEF wire codec and typed record parsing, smart
posters, background tag reading, host card emulation, Apple VAS, `restartPolling`,
`setAlertMessage`, raw `enableReaderMode`, foreground dispatch, configurable presence-check
delay, and typed Android error codes.

## License

[MIT](LICENSE) © Önder ADA
