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

Three things reading the SDKs turned up that are not "a newer OS added something" — they are
about code that already ships, or surface that has been reachable for years and was never
taken.

### `Iso15693.getSystemInfo()` calls a selector Apple deprecated in iOS 14

`NfcUtilPlugin.swift` calls `tag.getSystemInfo(requestFlags:)`, which `CoreNFC.apinotes` maps
to `getSystemInfoWithRequestFlag:completionHandler:` — marked
`API_DEPRECATED_WITH_REPLACEMENT("getSystemInfoAndUIDWithRequestFlag:completionHandler:", ios(13.0, 14.0))`
in `NFCISO15693Tag.h`. The replacement is available well below this package's 15.6 floor, so
**no floor moves** and this could be a minor release.

It is not a rename, though, which is why it has not been done casually:

* the apinotes mark the replacement `SwiftPrivate: true`, so from Swift it surfaces as
  `__getSystemInfoAndUID(...)` rather than as an idiomatic method;
* it returns the tag UID in addition to the five values the current call yields, which means
  a new field on `Iso15693SystemInfoPigeon` and on the public `Iso15693SystemInfo`.

Adding a field to a Pigeon *class* is additive and safe — unlike an enum value — so the only
real cost is the `SwiftPrivate` awkwardness. Worth doing before Apple removes the old one.

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

## Public enum additions

Adding a value to a public Dart enum is source-breaking against an exhaustive `switch`, so
each of these forces a major on its own, regardless of which SDK it needs:

* `NfcPollingOption.pace`
* `SessionKindPigeon` → a `payment` case, so `onError` and `onSessionBecameActive` stay
  unambiguous once a third iOS session exists
* `NfcEventKind.offHostAidSelected`
* possibly a typed `unsupportedApiLevel` on `NfcAndroidErrorCode`, replacing the string code
  3.2.0 throws

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
| A background Flutter engine for host card emulation | A real gap, and a large one: today APDUs are bridged only while the engine is alive, and a tap with the app fully stopped answers `6D00`. It is an architectural change to the plugin rather than a platform-version question, so it is tracked separately from this file's release rule. |

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
