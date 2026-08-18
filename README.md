# NFC Util

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

## Contents

New here? Everything you need for a first tag read is in [Quick start](#quick-start).

* [What it does](#what-it-does)
* [Install](#install)
* [Quick start](#quick-start)
* [Setup in detail](#setup-in-detail)
  * [The minimum, for reading tags](#the-minimum-for-reading-tags)
  * [Only if you need it](#only-if-you-need-it)
  * [Troubleshooting](#troubleshooting)
* [The four libraries](#the-four-libraries)
* [Sessions](#sessions)
* [NDEF](#ndef)
* [Tag technologies](#tag-technologies)
* [Background tag reading](#background-tag-reading)
* [Host card emulation](#host-card-emulation)
* [Apple Wallet passes](#apple-wallet-passes)
* [Errors](#errors)
* [Testing](#testing)
* [Upgrading from 2.2.0](#upgrading-from-220)
* [License](#license)

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
  nfc_util: ^3.1.2
```

Requires Flutter 3.44, Android API 24, iOS 15.6.

## Quick start

Six steps from an empty project to a tag read on a real phone. Nothing else in this README is
needed to get that far.

### 1. Add the package

```bash
flutter pub add nfc_util
```

Then check your project clears the floor: **Flutter 3.44**, **Android API 24** (`minSdk` in
`android/app/build.gradle.kts`), **iOS 15.6** (`IPHONEOS_DEPLOYMENT_TARGET` in Xcode).

### 2. Android: nothing to do

The plugin declares `android.permission.NFC` for you, so an app that only reads tags needs no
manifest change at all. **Skip to step 4.**

Android needs manifest entries only for letting a tag *launch* your app while it is closed,
which is a later concern — see [Setup in detail](#setup-in-detail).

### 3. iOS: three things

**a.** In Xcode, open `ios/Runner.xcworkspace` → select the **Runner** target → **Signing &
Capabilities** → **+ Capability** → add **Near Field Communication Tag Reading**.

**b.** Open `ios/Runner/Info.plist` and add both keys below. The first is the sentence iOS
shows the user when the reader opens; the second is the one people forget:

```xml
<key>NFCReaderUsageDescription</key>
<string>This app uses NFC to read tags.</string>

<key>com.apple.developer.nfc.readersession.felica.systemcodes</key>
<array>
    <string>12FC</string>
    <string>8008</string>
    <string>0003</string>
    <string>FE00</string>
</array>
```

**c.** Know why **b** matters. `startSession` polls for every tag type by default, FeliCa
included, and CoreNFC refuses a FeliCa poll unless those system codes are listed. Without the
key **no reader sheet appears, no exception is thrown, and it looks like your code did
nothing**. If you would rather not poll FeliCa at all, leave the key out and pass
`pollingOptions: {NfcPollingOption.iso14443}` to `startSession` instead. This is the single
most common iOS mistake with this package.

### 4. Write your first screen

Replace `lib/main.dart` with this. It runs as it stands: press the button, hold a tag to the
phone, read its text.

```dart
import 'package:flutter/material.dart';
import 'package:nfc_util/ndef.dart';
import 'package:nfc_util/nfc_util.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: TagReaderPage());
}

class TagReaderPage extends StatefulWidget {
  const TagReaderPage({super.key});

  @override
  State<TagReaderPage> createState() => _TagReaderPageState();
}

class _TagReaderPageState extends State<TagReaderPage> {
  String _status = 'Press the button, then hold a tag against your phone.';

  void _show(String message) {
    if (mounted) setState(() => _status = message);
  }

  Future<void> _readTag() async {
    // 1. Can we use NFC right now? This never throws, so it is safe as a gate.
    final availability = await NfcUtil.instance.checkAvailability();
    if (availability != NfcAvailability.enabled) {
      _show(availability == NfcAvailability.disabled ? 'NFC is switched off in Settings.' : 'This phone has no NFC.');
      return;
    }

    // 2. Start reading. On iOS this is what opens the system reader sheet.
    await NfcUtil.instance.startSession(
      alertMessageIos: 'Hold your phone near the tag',
      onDiscovered: (tag) async {
        // 3. A tag arrived. Read its NDEF message and pull out the text records.
        final message = await Ndef.from(tag)?.read();
        final texts = <String>[];
        for (final record in message?.records ?? const <NdefRecord>[]) {
          final text = TextRecord.from(record);
          if (text != null) texts.add(text.text);
        }
        _show(texts.isEmpty ? 'Tag read, but it holds no text.' : texts.join('\n'));

        // 4. Done with this tag: close the session.
        await NfcUtil.instance.stopSession(alertMessageIos: 'Done');
      },
      onError: (error) async => _show(error.message),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Read an NFC tag')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(_status, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton(onPressed: _readTag, child: const Text('Read a tag')),
        ],
      ),
    ),
  );
}
```

### 5. Run it on a real phone

```bash
flutter run
```

**It has to be a physical phone.** No Android emulator and no iOS Simulator has an NFC radio,
so there the button only reports that the device has no NFC. For a test tag, any cheap
**NTAG213** sticker works — write some text onto it with any NFC writer app first, so there is
something to read.

### 6. What you should see

The two platforms feel different, which is normal and not a bug:

| | Android | iOS |
|---|---|---|
| After pressing the button | nothing visible — the phone is already listening | the system reader sheet slides up, showing your `alertMessageIos` text |
| When the tag touches | the system tag sound, then the text on screen | the sheet reports "Done" and dismisses itself, then the text |
| If no tag ever arrives | the session stays open until you stop it | iOS closes the session on its own and `onError` fires |

That is the whole loop. From here:

* reading or writing more than plain text → [NDEF](#ndef)
* Mifare, FeliCa, ISO 15693, ISO 7816 → [Tag technologies](#tag-technologies)
* launching your app by tapping a tag → [Background tag reading](#background-tag-reading)
* something not working → [Troubleshooting](#troubleshooting)
* every feature at once, one button each → the demo app in [`example/`](example/)

## Setup in detail

Everything the two platforms can ask for. The first subsection is what Quick start already
did; the rest you add only when you use the feature that needs it.

### The minimum, for reading tags

**Android** — nothing. The plugin declares `android.permission.NFC` and its card emulation
service itself, so a reader-only app needs no manifest change.

**iOS** — three things, all of them [Quick start step 3](#3-ios-three-things):

1. The **Near Field Communication Tag Reading** capability in Xcode.
2. `NFCReaderUsageDescription` in `Info.plist`.
3. `com.apple.developer.nfc.readersession.felica.systemcodes` in `Info.plist`. Polling
   `iso18092` — which `startSession` does by default — makes CoreNFC demand it. **Without it
   the reader sheet simply never appears**, `startSession` still returns normally, and the
   failure arrives asynchronously. Either add the key or drop `iso18092` from
   `pollingOptions`.

### Only if you need it

**Background tag reading (Android)** — only if a tag should launch your app while it is
closed. The intent filters name *your* activity, so only your manifest can declare them. Add
to the launcher activity, which must be `android:launchMode="singleTop"` or a tap starts a
second copy instead of delivering to the running one:

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

**Card emulation description (Android)** — only if you use host card emulation. The string
shown in the system's "Tap and pay" settings defaults to "NFC card emulation". Override it by
declaring `nfc_util_hce_description` in your own `strings.xml`.

**ISO 7816 tags (iOS)** — only if you send APDUs to a smart card. Those tags additionally need
`com.apple.developer.nfc.readersession.iso7816.select-identifiers` in `Info.plist`, listing
the AIDs you select.

**Apple Wallet passes (iOS)** — only if you read Wallet passes. They need `VAS` in
`com.apple.developer.nfc.readersession.formats`. This is **not** part of the Xcode capability,
which grants only `NDEF` and `TAG`: the App ID has to be provisioned for VAS separately, and
adding the value to a profile that does not carry it fails the **build**, not the session —
*"Provisioning profile ... doesn't match the entitlements file's value for the
com.apple.developer.nfc.readersession.formats entitlement"*. The example app therefore ships
without it, so it builds on any team; add it once your own App ID is provisioned.

### Troubleshooting

| What you see | Why, and what to do |
|---|---|
| **iOS: no reader sheet, and no error either.** The call returns and nothing happens. | The FeliCa system codes are missing from `Info.plist` — [step 3](#3-ios-three-things). |
| `The getter 'instance' isn't defined for the type 'NfcUtil'` | A class of your own named `NfcUtil` shadows the package's. Import it under a prefix — [The four libraries](#the-four-libraries). |
| `PlatformException(session_already_exists)` | A session is still running. Call `stopSession()` first, and after an error restart only when `error.sessionEnded` is true — [Errors](#errors). |
| No tag is ever detected | An emulator or the Simulator (neither has a radio), or NFC is switched off. `checkAvailability()` tells the two apart. |
| **Android: the tap opens a different app** | Another app claims the tag first. Call `enableForegroundDispatch()` while your screen is up — [Background tag reading](#background-tag-reading). |
| A write appears to do nothing | Check `ndef.isWritable`, and `message.byteLength <= ndef.maxSize`, before writing — [NDEF](#ndef). |
| **iOS: the session ends by itself** | Expected. CoreNFC closes an idle session and reports it through `onError`. |

## The four libraries

Which platforms a class works on is told by the import path, not by a suffix on the class
name. `nfc_util.dart` and `ndef.dart` work everywhere; `android.dart` and `ios.dart` work only
on the platform they name.

```dart
import 'package:nfc_util/nfc_util.dart';          // NfcUtil, NfcTag, NfcError
import 'package:nfc_util/ndef.dart';              // Ndef, NdefMessage, typed records
import 'package:nfc_util/android.dart' as android; // android.nfc
import 'package:nfc_util/ios.dart' as ios;         // CoreNFC
```

`NfcUtil` is a thin adapter, and it hides nothing: anything it does not cover is reachable
directly on `NfcUtilAndroid` or `NfcUtilIos`.

**If your app has its own `NfcUtil`** — a wrapper named after the thing it wraps is the
obvious name on both sides of the import — the result is not a conflict but a shadow: the
local declaration wins, and `NfcUtil.instance` fails with *"The getter 'instance' isn't
defined for the type 'NfcUtil'"*. Import the package under a prefix:

```dart
import 'package:nfc_util/nfc_util.dart' as nfc;

if (await nfc.NfcUtil.instance.checkAvailability() != nfc.NfcAvailability.enabled) return;
await nfc.NfcUtil.instance.startSession(onDiscovered: (tag) async { /* ... */ });
```

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

While an iOS session is up you can narrate it and move it along:

```dart
await ios.NfcUtilIos.instance.tagSessionSetAlertMessage('Hold still, writing…');
await ios.NfcUtilIos.instance.tagSessionRestartPolling();   // drop this tag, look for the next
```

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

**`registerAids` changes persistent device state.** The emulation service ships disabled; a
successful call enables it and stores the AID group with the Android framework, and both
survive the process being killed, a reboot and an app update. The device answers readers for
those AIDs whenever the app is installed, running or not. `unregisterAids()` is the only way
back short of uninstalling, so pair the two — a call that fails or returns false leaves
nothing behind, but one that succeeds and is never undone leaves the app enrolled forever.

Pick your own AID. `F0010203040506` above is a sample: two apps built from it on one device
claim the same identifier, and the second registration is refused.

**This release bridges APDUs only while the Flutter engine is alive.** A tap with the app
fully stopped is answered with `6D00` rather than queued. Emulating a card while the app is
closed needs a background engine, which this release does not have.

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
posters, background tag reading, host card emulation, Apple VAS,
`NfcUtilIos.tagSessionRestartPolling`, `tagSessionSetAlertMessage` and
`vasSessionSetAlertMessage`, raw `NfcUtilAndroid.enableReaderMode`, foreground dispatch,
configurable presence-check delay, and typed Android error codes.

## License

[MIT](LICENSE) © Önder ADA
