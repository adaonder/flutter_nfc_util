# Roadmap

What is deliberately **not** in the current release, and why.

Everything here was verified against the SDKs themselves rather than against documentation:
the Android entries by diffing `android.jar` and then cross-checking each member's real
`since=` in `platforms/android-37.0/data/api-versions.xml`, the iOS entries by reading the
CoreNFC headers in the iOS 26.5 SDK. Where an entry names a version, that is what the SDK
says — see [How to keep this file honest](#how-to-keep-this-file-honest) for the commands.

The rule that decides which release something lands in:

> A capability that compiles against a `compileSdk` the current AGP can express, and that
> adds no value to a public enum, can ship in a minor release. Anything that moves a
> toolchain floor further than that, or adds an enum value, waits for a major.

Current floors: `compileSdk 36`, `minSdk 24`, iOS deployment target 15.6, Flutter 3.44,
AGP 8.13.2. `minSdk` and the iOS deployment target are **not** planned to move.

**There are two axes here, and this file only ever had one.** Until 3.3.0 everything below
came from an SDK *version diff* — what did Android 16.1 add, what did iOS 26.4 add. That
reading is blind by construction to surface that has been public for years and was simply
never taken, because nothing about it is new. The 3.3.0 audit found the larger of its two
severe gaps on that blind axis: thirteen `NFCISO15693Tag` methods available since iOS 14,
and the whole query half of `CardEmulation` available since API 19. Neither would ever have
appeared in a version diff. [Reachable at the current floor, and never
taken](#reachable-at-the-current-floor-and-never-taken) is the section for that axis; keep
both sweeps running, they do not find the same things.

---

## Verification of the current release

Neither of these is code. Both were open questions the documentation could not answer
honestly; both have now been measured on hardware, and what is left of each is stated
plainly rather than glossed.

### 1. `DISPATCH_NFC_MESSAGE` below API 37 — measured, and it is safe

**Closed.** This used to be the open question that kept the example's `<activity-alias>` a
comment instead of live configuration. It was measured on two real devices, a Pixel 10 on
Android 17 (API 37) and a phone on Android 9 (API 28):

| Measurement | API 37 | API 28 |
|---|---|---|
| `pm list permissions` knows `android.permission.DISPATCH_NFC_MESSAGE` | yes | **yes** |
| `dumpsys package` → who declares it | `sourcePackage=android`, `prot=signature\|privileged` | same |
| NFC system service holds it | `com.google.android.nfc` → `granted=true` | `com.android.nfc` → `granted=true` |
| A guarded `<activity-alias>` registers and resolves `TECH_DISCOVERED` | yes | **yes** |

So it is not a new permission. It is an existing platform permission, present at least as far
back as API 28, that API 37 newly *enforces* on the receiving activity. Because the platform
declares it and the NFC service holds it, guarding an activity with it is safe on old
devices: the NFC service can still start that activity, and ordinary apps still cannot — which
is the point of the change.

The example therefore ships the guarded `<activity-alias>` as live configuration, with the
NFC intent filters moved off `MainActivity` so its launcher entry stays unguarded.

`checkTagIntentSetup()` was checked against a negative control rather than assumed to work:
with the permission on the alias it reports `unguarded: []` and `isHealthy: true`; with the
permission removed and the app rebuilt, it reports
`unguarded: [com.onderada.nfc_util_example.NfcEntryAlias]` and `isHealthy: false`.

**Still unmeasured:** an actual tag tap launching the app through the guarded alias. Everything
up to that point checks out, but the dispatch itself needs a tag held to the phone.

### 2. The hardware matrix

`tool/test_all.sh` covers six layers, the last of them on device. No test needs a tag or a
reader **in the field** — the on-device suite starts reader mode, reconfigures discovery
technology and registers AIDs, so it does drive the controller, but it never requires
something held to the phone.

**Done.** The on-device suite passes 8/8 on both ends of the Android support range, which is
what verifies the whole capability contract on real hardware rather than against fakes:

| | Android 17 (API 37) | Android 9 (API 28) |
|---|---|---|
| observe mode supported | true | false |
| tag-scan allowlist supported | true | false |
| card-emulation events | true | false |
| antenna geometry | `72x152 mm, [(31, 25)]` | null |
| `checkTagIntentSetup().isHealthy` | true | true |
| every probe answers without throwing | yes | **yes** |
| every gated action throws `unsupported_api_level` | n/a | **yes** |

**Left, and it needs a human holding something to a phone:**

| What | Why no test can do it |
|---|---|
| Reader mode against a real tag; a manifest-filter launch; an HCE tap | needs a tag, or a reader and a second device |
| Observe mode and polling frames against a real reader | needs a reader emitting a polling loop |
| The Android 16 tag-scan allowlist prompt, and a web-link tag going to `ACTION_VIEW` | needs a written tag and a user decision |
| Launch from a force-stopped app on Android 17 | needs a tag tap after `am force-stop` |
| iOS 15.6: probes answer `false`/`null` without crashing | no iOS 15.6 device to hand |

**Added by 3.3.0, and owed a measurement.** All of it compiles and passes the ten test
layers; none of it has touched a card:

| What | What it needs |
|---|---|
| The ISO 15693 security commands (`authenticate`, `keyUpdate`, `challenge`, `readBuffer`) and `sendRequest` | a tag implementing ISO/IEC 29167 |
| `Iso15693.readMultipleBlocksWithConfiguration` / `customCommandWithConfiguration` | the header says CoreNFC answers `unsupportedFeature` for these on a tag from an `NFCTagReaderSession` without `com.apple.developer.nfc.readersession.iso15693.tag-identifiers`; that is the expected common outcome and has not been confirmed |
| `splitBlocks` even-division path in `readMultipleBlocksWithConfiguration` | CoreNFC returns one concatenated `Data` here, unlike every other read-multiple call; the uneven case falls back to one undivided element rather than slicing at a guess |
| `MifareClassic.reset()` | a Mifare Classic card and a deliberately wrong key, to confirm the halted-tag recovery it exists for |
| `NfcTag.otherTagCount` | two cards in the field at once |
| The `CardEmulation` query half | a reader, and a second app claiming the same AID for the conflict cases |
| `NfcUtilIos.tagIsAvailable` | a tag taken out of the field mid-session |
| `Ndef.uncheckedIos` | a `skipNdefCheck` session against a real NDEF tag |

One measurement is worth more than the rest, because six decisions rest on it:
**is `MiFare.sendMiFareCommand` a general raw-frame escape hatch on iOS?** The audit assumed
it was and classified NTAG21x `PWD_AUTH`, `GET_VERSION`, `READ_SIG`, Ultralight C 3DES and
the Ultralight command layer as reachable today because of it. `NFCMiFareTag.h` does not
support that reading: it names three NXP families, not any ISO 14443-3A tag, and it inserts
CRC and handles chaining internally, so it is not a raw transceive. Run it against (i) a
non-NXP Type 2 tag that CoreNFC reports as `MiFareFamily.unknown` and (ii) a plain NTAG213
`READ` (`30 04`), then either document the escape hatch honestly on the `MiFare` class or
reopen those six decisions — in which case their iOS halves are *unreachable*, not
app-level.

---

## Android: three floors, not one

Android now ships **minor** SDK releases, and this matters more than anything else on this
page. `android-36` is API 36, `android-37.0` is API 37 — and **API 36.1 sits between them**.
A plain `javap` diff of the two jars lumps every 36.1 addition in with the 37.0 ones; only
`api-versions.xml` records the real `since=` per member.

For `android.nfc` the split is lopsided: of the fifteen members added between the two jars,
**eleven are API 36.1** and only four are API 37.

That changes the release plan. AGP has expressed a minor compile SDK since **8.11.1**, via
`compileSdkMinor`, and this plugin already builds with AGP 8.13.2:

```groovy
android {
    compileSdk = 36
    compileSdkMinor = 1   // AGP 8.11.1+
}
```

So the API 36.1 group is reachable without waiting for a major — the floor it imposes on a
consuming app is "AGP 8.11.1 or newer", not "an AGP that knows API 37". The caveat is that
the `android-36.1` platform is a separate SDK package that has to be installed; it is not
present on this machine, so nothing below has been compiled yet.

| Floor | Moved by | Costs a consumer |
|---|---|---|
| `compileSdk 36` → **36 + `compileSdkMinor 1`** | the API 36.1 table below | AGP 8.11.1+, and the `android-36.1` platform installed |
| → **37** | the API 37 table below | an AGP that knows API 37, failing with an error that does not name this plugin |
| Xcode → **26.0**, then **26.4** | the iOS table below | CI on an older Xcode, silently |

A symbol can only be *named* if it exists in the SDK being compiled against, which is why
none of the following can be reached today. Reflection would dodge the bump and defeat the
schema-first design the package is built on; it is not on the table.

### Android 16.1 (API 36.1) — candidate for a minor release

Nothing here adds a public enum value except the last row, so most of this group could ship
as **3.3.0** once the platform is installed and the AGP floor is stated.

**`NfcAdapter`**

| Member | What it is for |
|---|---|
| `isPowerSavingModeSupported()` / `isPowerSavingModeEnabled()` / `setPowerSavingMode(boolean)` | Controller power state. |
| `isExitFramesSupported()` | Whether the controller reports exit frames. |

**`CardEmulation`** — every one of its additions is 36.1; the API 37 release added none.

| Member | What it is for |
|---|---|
| `setRequireDeviceScreenOnForService(ComponentName, boolean)` / `isDeviceScreenOnRequiredForService` | Lets an app change at run time what `res/xml/nfc_util_apduservice.xml` fixes at build time. |
| `setRequireDeviceUnlockForService(ComponentName, boolean)` / `isDeviceUnlockRequiredForService` | As above, for the unlock requirement. |
| `getPollingLoopFiltersForService(ComponentName)` / `getPollingLoopPatternFiltersForService` | Readback of what 3.2.0's `registerPollingLoopFilter` wrote. |
| `PROTOCOL_AND_TECHNOLOGY_ROUTE_NDEF_NFCEE` | Routing constant — see *Out of scope*. |

**`CardEmulation.NfcEventCallback`**

`onOffHostAidSelected(String, String)` — a reader selected an AID routed to a secure element
rather than to the host. The wire is already shaped for it: 3.2.0's `NfcEventKindPigeon` was
designed as one flat kind so this slots in without a channel change, and it needs only a new
enum value plus an `offHostSecureElement` field. **The enum value is what holds it to a
major**, not the SDK.

### Android 17 (API 37)

Four members, and one deprecation.

| Member | What it is for |
|---|---|
| `allowOneTransaction()` | Lets a single exchange through without leaving observe mode. The missing half of the observe-mode story shipped in 3.2.0, and the reason API 37 matters at all here. |
| `isReaderModeAnnotationSupported()` + `EXTRA_READER_TECH_A_POLLING_LOOP_ANNOTATION` | A reader-mode annotation. The constant's value is `android.nfc.extra.READER_TECH_A_POLLING_LOOP_ANNOTATION`; the jar alone does not prove where it is passed, so treat "it goes in the reader-mode extras `Bundle`" as the working assumption to confirm against the platform docs before implementing. Needs a new field on `SessionConfigPigeon` and a matching parameter on `NfcUtil.startSession`. |
| `getGestureExchangeAid()` | Wallet-role surface — see *Out of scope*. |
| `ACTION_TAG_DISCOVERED` | **Deprecated.** Already suppressed and still accepted, because every device up to API 36 sends it. |

No class was added or removed under `android.nfc` between the two jars.

---

## iOS

Verified against `iPhoneOS26.5.sdk`'s CoreNFC headers. Note the two distinct SDK floors: the
payment session needs only iOS 26.0, everything else needs 26.4.

| API | Since | What it is for |
|---|---|---|
| `NFCPaymentTagReaderSession` | iOS 26.0 | An `NFCTagReaderSession` subclass that performs the SELECT-by-DF-name itself, from `com.apple.developer.nfc.readersession.iso7816.select-identifiers`, and hands back an `NFCISO7816Tag`. Accepts `NFCPollingISO14443` only. Reuses the whole existing `Iso7816` Dart surface; the only new state is a third session slot beside the tag and VAS sessions. |
| `NFCTagReaderSessionConfiguration` (Swift: `NFCTagReaderSession.Configuration`), `init(configuration:delegate:queue:)`, `restartPolling(configuration:)` | iOS 26.4 | **The most useful of these.** Lets a session pick, at run time, a *subset* of the ISO 7816 select identifiers and FeliCa system codes declared in `Info.plist` — entries not in the plist are dropped, and an empty array means "all of them". Today those lists are fixed at build time, and the README's first troubleshooting row exists because a missing FeliCa system code produces no reader sheet and no error. Note that `restartPolling(configuration:)` does **not** persist the configuration: a later plain `restartPolling()` reverts to the one the session was initialised with. |
| `NFCPollingPACE` + `NFCISO7816Tag.supportsPACE` | iOS 16.0 / 26.4 | Password Authenticated Connection Establishment, for ePassport-class tags. **Never exposed by this package**, at any version — it predates the 3.x line. Needs `PACE` added to `com.apple.developer.nfc.readersession.formats`. Before iOS 26.4 it is exclusive and supersedes `NFCPollingISO14443`; from 26.4 it combines with the other options. Held for a major only because it adds a value to the public `NfcPollingOption` enum. |
| `NFCReaderErrorIneligible`, `NFCReaderErrorAccessNotAccepted` | iOS 26.0 | **Already handled.** `TagMapper.swift` maps raw values 7 and 8, and `NfcReaderErrorCode` already carries both. On the iOS 26 SDK the raw-value fallback can become named cases — cosmetic, no behaviour change. |

Every one of these stays behind `@available(iOS …)` with an `if #available` at each entry
point, so the deployment target stays at 15.6 and the probes answer `false` on an older
phone. Only the *compile-time* SDK moves.

---

## Maintenance, not features

Two things reading the SDKs turned up that are not "a newer OS added something" — they are
about code that already ships.

*(The third, `Iso15693.getSystemInfo()` calling a selector Apple deprecated in iOS 14,
shipped in 3.3.0: `getSystemInfoAndUid()` replaces it and returns the UID, and the old one
is deprecated rather than removed. The `SwiftPrivate` awkwardness the entry predicted was
real — the Swift name is `__getSystemInfoAndUID(with:)`.)*

### FeliCa card emulation has never been exposed

`android.nfc.cardemulation.HostNfcFService` and `NfcFCardEmulation` are in the **public**
`android.jar` at every level this package supports, so an ordinary app can use them. They are
the FeliCa counterpart to the ISO 7816 host card emulation shipped in 3.0.0: the phone
answers a FeliCa reader rather than an APDU reader, addressed by system code and NFCID2
rather than by AID.

Not planned, but not out of scope either — it is a second emulation service, a second
manifest entry and a second bridge, and it should be a deliberate decision rather than an
oversight. It is listed here so it stops being an oversight.

### `HostApduService.notifyUnhandled()` is never called

A `final` method on the service the plugin already subclasses. It tells the system this
service cannot handle the AID the reader selected, so the platform can offer the user
another app instead of leaving the reader waiting. Today the plugin answers `6D00` in that
situation, which is a valid card response but tells the *system* nothing. A small, contained
improvement to the existing emulation path.

## Reachable at the current floor, and never taken

The axis a version diff cannot see. Everything here compiles against today's `compileSdk`
and today's deployment target — the only reason it is not in the package is that nobody
looked for it.

**3.3.0 took the two that mattered.** The rest of `NFCISO15693Tag` (iOS 14, thirteen
methods, and `customCommand` was never an escape hatch for them because CoreNFC caps it at
command codes `A0`–`DF`), and the query half of `CardEmulation` (API 19–21, below `minSdk`).
Also `NfcAdapter.isReaderOption*`, `Settings.ACTION_NFC_SETTINGS`, the `MifareClassic`
constants, `NFCTag.isAvailable`, and the ISO 7816-4 chaining every consumer was writing by
hand.

**Still on this axis, and not yet decided:**

| API | Since | Note |
|---|---|---|
| `NfcAdapter.ignore(Tag, int, OnTagRemovedListener, Handler)` | API 24 — exactly `minSdk` | The only tag-*removed* signal the platform offers. Today the package can only learn a tag is gone by poking it and catching `TAG_LOST`. Two things must be documented or it reads as broken: after `ignore()` every call on that tag throws `IOException` (so the handle must be destroyed with it), and randomised-UID tags — most modern DESFire and EMV — cannot be debounced reliably. **Measure first:** how it interacts with an active reader-mode session is not settled by the SDK docs, and this file's own rule says measure rather than assume. |
| `NfcAdapter.enableForegroundDispatch` filters and tech lists | API 10 | The plugin passes `null, null`, which is the documented wildcard and is what the API promises today. The only thing wildcards cannot express is a MIME type chosen at run time. Do the narrow version — one optional `List<String> mimeTypes` — or decide against it and move this row to *Out of scope*, so it stops looking overlooked. The full `IntentFilter` / `String[][]` model should not be done: `setDiscoveryTechnology` already answers the tech-list half. |
| `HostApduService.onDeactivated`'s reason constant | API 19 | Surfaced as a bare `int` — the package's only untyped platform constant, against `NfcAdapterState`, `NfcAndroidErrorCode`, `PollingFrameType` and the rest, which are all typed. The enum itself is minor-safe; **changing the callback's signature is source-breaking**, so it is either a major or a second typed callback plus a deprecation. |
| `ACTION_TRANSACTION_DETECTED` | API 28 | Off-host secure-element transaction events. Do **not** ship alone: it adds an `NfcEventKind` value, and so does API 36.1's `NfcEventCallback.onOffHostAidSelected` — the selection and completion halves of the same story. They ride the same major or neither does. Delivery is the real problem: the app is by definition not running, so a runtime receiver is useless and a manifest receiver merges `NFC_TRANSACTION_EVENT` into every consuming app. |

---

## The NDEF and spec layer

This file had no place for these, which is itself the point: every section above is a
platform API, while the package's most distinctive component — a ~790-line pure-Dart NDEF
codec that works with no tag present — lives in a layer the roadmap never modelled.

Nothing here needs a Pigeon, Kotlin or Swift change, and all of it is testable without a
device.

| Item | Note |
|---|---|
| **Connection Handover** (`Hr`/`Hs`/`Hm`/`Hi`, `ac`, `cr`, `err`) | The strongest candidate. A handover tag today decodes as an opaque `MimeRecord`. The nested-message pattern is already proven in `SmartPosterRecord.from`, and the record ID field that `ac` needs to resolve its carrier reference already survives end to end. **Split it:** decode first, encode second. The value `from()` adds that a caller cannot write themselves is resolving each Alternative Carrier's reference against its siblings' `identifier`. **Stop at the envelope** — WSC TLV and BT/BLE OOB EIR are Bluetooth SIG and Wi-Fi Alliance formats, not NFC Forum, and owning two foreign versioned registries does not belong in a package whose only dependency is `meta`. |
| The negotiated half (`HandoverRequest`, `AlternativeCarrier`, `CollisionResolution`) | Do **not** defer this as "peer-to-peer is dead". ISO/IEC 18013-5 mDL is exactly the peer: the reader app is the Handover Requester, the holder answers with a Handover Select, and the whole negotiation completes between two ordinary apps over ISO-DEP / Type 4 with no OS flow involved. Same signal reverses the default for Type 4 emulation below. |
| **Type 4 Tag emulation over HCE** | The package owns both halves and joins neither: the APDU pipe in `hce.dart`, the encoder in `NdefMessage.toBytes()`. An app can already do this from Dart — the real prize is different: a Type 4 emulator knows its bytes at *registration* time, so a native state machine (CC file `E103`, NDEF file `E104`, SELECT / READ BINARY / UPDATE BINARY) checked *before* the bridge dispatch answers correctly **with the app fully stopped**. That makes it **not** a duplicate of the background-engine row in *Out of scope* — it is the case that sidesteps it. `UPDATE BINARY` must be a first-class writable mode, not an opt-in afterthought, because negotiated handover requires the reader to write. |
| **Signature RTD** (`Sig`) | Parse only, and there is a blocker to clear first: `Sig` covers the *on-the-wire* encoding of the preceding records, but this package does not keep the original bytes. `NdefMessage.fromBytes` rebuilds from parts, `toBytes` always emits the short-record form under 256 bytes and never chunks, while `fromBytes` coalesces chunked records — so a re-encode can differ byte for byte from what was signed. Fix that (keep per-record source offsets, or require the caller to hand over the raw bytes) before anything else. Verification needs X.509/ECDSA and a **trust-store policy**, which is the app's decision, not a transport's. |
| **Device Information RTD** (`Di`) | Small, but useless alone — its role is to accompany a handover message. Ship with Connection Handover or not at all. |
| **TNEP 1.0** | Named NFC Forum spec, no native work. The library-shaped part is only a ~200-line `Tp`/`Te` codec; the poller loop is close to write-wait-read. Do not build it speculatively. If it is built, ship the record codec first and tie the poller to a real request, measuring it against the iOS session timeout with an actual tag. |
| `SmartCard.from(tag)` | The cross-platform peer to `Ndef.from(tag)`, normalising Android `IsoDep` and iOS `Iso7816`. Honestly a convenience — but so is `Ndef.from`, and the package chose to own that, so refusing here would be an inconsistency rather than a principle. Keep it to APDU exchange only; `timeout`, `isExtendedLengthApduSupported` and `initialSelectedAID` are single-platform and stay one import away. 3.3.0's `package:nfc_util/apdu.dart` is the transport it would wrap. |
| `package:nfc_util/testing.dart`'s remaining boundary | A host call naming a generated class **or enum anywhere in its signature** still cannot be overridden without importing `package:nfc_util/src/pigeon.g.dart`. `resetTech` and the six card-emulation queries answer nothing and are still affected, via their parameters. Re-exporting `AndroidTechPigeon` and `CardEmulationCategoryPigeon` would close most of it — but it would also make a generated shape public API permanently, which is the exact promise `TagPigeon`'s `@internal` makes. Deliberately not done; revisit only with a concrete need. |

---

## Public enum additions

Adding a value to a public Dart enum is source-breaking against an exhaustive `switch`, so
each of these forces a major on its own, regardless of which SDK it needs:

* `NfcPollingOption.pace`
* `SessionKindPigeon` → a `payment` case, so `onError` and `onSessionBecameActive` stay
  unambiguous once a third iOS session exists
* `NfcEventKind.offHostAidSelected`
* `Iso15693RequestFlag.commandSpecificBit8` — `NFCISO15693RequestFlagCommandSpecificBit8`,
  bit 7, added in iOS 14. Noticed while bridging the rest of `NFCISO15693Tag` for 3.3.0 and
  deliberately left out: the public enum mirrors the other six exactly, and adding the
  seventh is source-breaking. Not urgent, because `sendRequest` takes the flag byte as a raw
  `int` and can already set it.
* possibly a typed `unsupportedApiLevel` on `NfcAndroidErrorCode`, replacing the string code
  3.2.0 throws
* possibly a typed `HceDeactivationReason`, replacing the bare `int` — see [Reachable at the
  current floor](#reachable-at-the-current-floor-and-never-taken); the enum is minor-safe,
  the signature change is not

## Migration notes to write

For a minor that takes the API 36.1 group: AGP 8.11.1 or newer, and the `android-36.1`
platform installed. Nothing else changes.

For the major: the stated AGP floor for `compileSdk 37`, the iOS 26.4 SDK (Xcode 26.4 or
newer — iOS 26.0 is enough only if `NFCPaymentTagReaderSession` ships alone), and a re-check
of any exhaustive `switch` over the enums above. `minSdk` and the iOS deployment target do
not move, so no device support is dropped.

---

## Out of scope, and why

These are not "later" — they are things this package should not try to expose.

| API | Why not |
|---|---|
| `NfcAdapter.enable()` / `disable()` | System apps only; needs `WRITE_SECURE_SETTINGS`, which a normal app cannot hold. |
| `CardEmulation.PROTOCOL_AND_TECHNOLOGY_ROUTE_*`, `NfcAdapter.getGestureExchangeAid()` | Routing-table and wallet-role surface, meaningful only to a default-wallet app. |
| `NfcOemExtension` | A `@SystemApi`: absent from the public `android.jar` at every level, including 37, so it cannot be named from an app at any `compileSdk`. |
| iOS `NFCCardSession`, Apple's NFC & SE Platform (HCE, credential provisioning, presentment intent assertion) | Behind a signed Apple agreement and an entitlement granted per organisation, not obtainable by a general-purpose package. Regions and use cases keep expanding — MultiSSD in iOS 26.2, government ID in 26.4 — but the gate does not. |
| A background Flutter engine for host card emulation | A real gap, and a large one: today APDUs are bridged only while the engine is alive, and a tap with the app fully stopped answers `6D00`. It is an architectural change to the plugin rather than a platform-version question, so it is tracked separately from this file's release rule. Note that Type 4 NDEF emulation is **not** this item — see [The NDEF and spec layer](#the-ndef-and-spec-layer). |
| `android.se.omapi` | The contacted smart-card interface; the NFC controller is not involved at all. APDU access is gated by GlobalPlatform SE Access Control, keyed to the calling app's signing certificate — an entitlement in all but name, issued by the SIM or eSE owner instead of by Apple. Same reasoning as the row above it. |
| Topaz / Jewel (NFC Forum Type 1) product commands | A platform limit, not an oversight, and confirmed from both primary sources: `android.jar` at API 37 has ten classes under `android/nfc/tech/` and none of them is Type 1, and `NFCPollingOption` is exactly ISO14443 / ISO15693 / ISO18092 / PACE. Recorded here because its absence is otherwise invisible. |
| EMV contactless card reading (PAN, expiry, Track 2) | Disqualified twice over. Apple excludes payment AIDs from `select-identifiers`, so the feature would be structurally Android-only and would break the package's cross-platform contract — the same reasoning that retires `NFCCardSession` above. And making PAN extraction a first-class API pushes PCI-DSS scope and app-review exposure onto users who never asked for it. |
| The mdoc / ISO 18013-5 stack itself | CBOR/COSE session encryption, device retrieval, issuer-signed document verification: an application-domain stack, like eMRTD and EMV. This package supplies the engagement transport and, if it lands, the handover codec; the mdoc part is the app's. |
| PC/SC desktop readers (Windows / macOS / Linux), CCID, WebUSB | The object model does not survive the move: PC/SC has no session, no alert sheet, no polling option, no HCE, no adapter state and no background tag delivery, so roughly half of a ~9,100-line public surface would throw `unsupported` on three new platforms. A sibling package, never a seventh library here. Point at `dart_pcsc` / `ccid` from the README instead. |
| Web NFC (W3C `NDEFReader`) | Chromium-on-Android only, still Experimental, no Safari or Firefox commitment, and NDEF-only by design. There is also a structural cost: `lib/src/api.dart` holds three concrete Pigeon host objects as top-level variables and every tag class calls them directly — there is no platform-interface indirection, and a federated `nfc_util_web` would need that split first. Revisit if a second browser engine ships `NDEFReader`; then it is an endorsed `nfc_util_web`, never a partial web branch inside this plugin. |
| `CardEmulation` preferred-payment trio, `ACTION_CHANGE_DEFAULT` | Wallet-role surface, and the trio would merge `NFC_PREFERRED_PAYMENT_INFO` into every consuming app's manifest — the same fight over `android.hardware.nfc` that 3.2.0 had to fix. `ACTION_CHANGE_DEFAULT` is deprecated as of API 35. |
| Vendor product command layers: NTAG 424 DNA SUN/SDM, NTAG 21x `PWD_AUTH`, DESFire authentication, Ultralight C 3DES, ICODE SLIX passwords, FeliCa Lite-S MAC, ST25 | Transport for all of these is already complete; what they add is cryptography and per-product memory maps. Each would force `pointycastle` onto every consumer that only reads NDEF, and a config-page writer that guesses a tag's variant can brick it — a wrong offset hits a lock or OTP page irreversibly. Companion packages if demand is shown. Accepting a second vendor's map after NXP would turn a bounded package into an open-ended vendor-table commitment. **Conditional:** the iOS half of this row depends on the `sendMiFareCommand` measurement in [the hardware matrix](#2-the-hardware-matrix). |

---

## How to keep this file honest

**Android.** A jar diff finds the members; `api-versions.xml` is the only thing in the SDK
that tells a minor release from a major one, and it is what makes the 36.1-versus-37 split
above visible at all:

```bash
javap -constants -cp "$ANDROID_HOME/platforms/android-37.0/android.jar" android.nfc.NfcAdapter
grep -o 'name="[^"]*" since="36.1"' "$ANDROID_HOME/platforms/android-37.0/data/api-versions.xml"
```

Check `platforms/*/source.properties` for each platform's real `AndroidVersion.ApiLevel`
before trusting a directory name.

**iOS.** Read the headers, not the release notes:

```bash
ls "$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/CoreNFC.framework/Headers"
```

iOS 26.4's session configuration appeared in no release-notes summary and was found only
this way. The same directory's `CoreNFC.apinotes` gives the Swift names, which differ from
the Objective-C selectors.
