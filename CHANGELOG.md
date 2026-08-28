## 3.3.0

### Upgrading from 3.2.0

Nothing was removed and nothing was renamed. Bump the version and you are done -- unless your
app does one of the four things below.

1. **Answer a reader only from inside `onApduReceived`.**

   Calling `HostCardEmulation.respond()` at any other moment used to crash the app. Now it
   does nothing and writes a line to logcat.

   The moments that count as "any other" are a polling frame arriving while observe mode is
   on, and a link that has already dropped. The framework only gives the service somewhere to
   send an answer when a command APDU arrives, so outside that window there is nothing to
   answer into. Not crashing costs you the signal: nothing in Dart says the answer went
   nowhere.

2. **On iOS, never ask for zero blocks.**

   If you work `numberOfBlocks` out from a list or a calculation, check it is not zero first.
   The ISO 15693 range commands now refuse an empty or negative range and throw
   `PlatformException(code: 'invalidParameter')`.

   They used to hand the numbers straight to CoreNFC as an `NSRange`, which has no defined
   meaning when the length is zero or the start is negative. Ranges up to 65536 blocks are
   untouched, so extended block numbers behave exactly as they did.

3. **`NdefMessage.toBytes()` can now throw.**

   This only reaches you if you build records yourself with `NdefRecord.fromParts` and give
   one a type or identifier longer than 255 bytes. That raises an `ArgumentError` now.

   It used to keep the low eight bits and write the message anyway, which produced bytes no
   reader could decode -- including this package's own parser. Anything read off a tag is safe
   by construction: the length arrives in a one-byte field, so it cannot exceed 255.

4. **`Iso15693.readMultipleBlocksWithConfiguration` can hand back fewer blocks than you asked
   for, including none.**

   Handle a short list rather than indexing into it.

   An empty answer used to crash the app instead of returning. This call also needs an
   entitlement Apple no longer grants, so most apps never reach it at all.

Everything else asks nothing of you. `compileSdk` stays at 36, `minSdk` at 24, the iOS
deployment target at 15.6, and no value was added to any existing public enum. The startup,
resume and package-manager costs described under *Crashes, stalls and leaks* get better on
their own.

### What is new, and what is gone

Nothing is gone. One method is deprecated but still works, one class moved without changing
where you import it from, and everything else below is new.

The list comes from diffing every public declaration against the 3.2.0 tag, rather than from
reading these notes back.

**Removed:** nothing. No member of the public API was deleted or renamed.

**Deprecated, still working:** `Iso15693.getSystemInfo`. Use `getSystemInfoAndUid`, which also
reports the UID. The old one keeps working and answers `uid` as `null`.

**Moved, same import:** `Iso7816ResponseApdu` now lives in the new `package:nfc_util/apdu.dart`
rather than on the iOS surface, because both platforms speak the protocol.
`package:nfc_util/ios.dart` still exports it, so no import of yours changes.

**New libraries**

* `package:nfc_util/apdu.dart` -- `CommandApdu` (with `withExpectedResponseLength` and
  `isExtended`), the sealed `StatusWord` hierarchy (`StatusWordSuccess`, `StatusWordMoreData`,
  `StatusWordWrongLength`, `StatusWordWarning`, `StatusWordError`, `StatusWordUnrecognised`,
  `StatusWordErrorReason`), `Iso7816Chaining`, and `Iso7816ResponseApdu.status`.
* `package:nfc_util/testing.dart` -- `debugReplaceApis`, `fakeNfcTag`, `FakeTech`,
  `FakeNfcHostApi`, `FakeNfcAndroidHostApi`, `FakeNfcIosHostApi`.

**New on iOS -- ISO 15693.** `sendRequest`, `fastReadMultipleBlocks`,
`extendedFastReadMultipleBlocks`, `extendedWriteMultipleBlocks`,
`extendedGetMultipleBlockSecurityStatus`, `authenticate`, `keyUpdate`, `challenge`,
`readBuffer`, `getSystemInfoAndUid`, `readMultipleBlocksWithConfiguration` and
`customCommandWithConfiguration`, plus the types `Iso15693Response`, `Iso15693ResponseFlag` and
`Iso15693CommandConfiguration`.

**New on iOS -- elsewhere.** `NfcUtilIos.tagIsAvailable(tag)` and `Ndef.uncheckedIos(tag)`.

**New on Android.** `isReaderOptionSupported()`, `isReaderOptionEnabled()`, `openNfcSettings()`
and `reset()` on the tag technologies.

**New on Android -- card emulation queries.** `supportsAidPrefixRegistration()`,
`aidsForService()`, `isDefaultServiceForCategory()`, `isDefaultServiceForAid()`,
`categoryAllowsForegroundPreference()` and `selectionModeForCategory()`, with
`CardEmulationCategory` and `AidSelectionMode`.

**New on both platforms.** `NfcTag.otherTagCount`, and on `MifareClassic` the constants
`keyDefault`, `keyMifareApplicationDirectory`, `keyNfcForum`, `blockSize`, `sizeMini`, `size1K`,
`size2K` and `size4K`.

The audit release. Nothing here came from a competing package -- a survey of the Flutter,
React Native, Capacitor and Cordova NFC libraries turned up no capability this one lacked.
What it turned up instead was surface sitting unclaimed in Apple's and Google's own SDKs,
some of it public for a decade, which a release-by-release reading of the platforms cannot
see because nothing about it is new.

**The two entries worth reading are the first two.** One is a hole you cannot work around,
the other is a wrong answer.

Nothing here is breaking. `compileSdk` stays at 36, `minSdk` at 24, the iOS deployment
target at 15.6, and no value was added to any existing public enum. Two new public libraries
appear, `package:nfc_util/apdu.dart` and `package:nfc_util/testing.dart`, and one method is
deprecated without being removed.

* **iOS could not send half of the ISO 15693 command set, and there was no way around it.**
  *(Fix -- anyone reading ISO 15693 / NFC-V tags on iOS.)* Thirteen of `NFCISO15693Tag`'s
  methods were never bridged, and `customCommand` is not an escape hatch for them: CoreNFC
  restricts it to command codes `A0`--`DF`, while every ISO 15693-3 security command
  (authenticate `35`, key update `36`, challenge `39`, read buffer `3A`) and both fast-read
  commands (`2D`, `3D`) sit outside that window. So a tag that Android drives perfectly well
  through `NfcV.transceive` simply could not be driven from iOS through this package -- the
  opposite direction from every asymmetry the README documents.

  The whole protocol is now bridged. The one that closes the hole on its own is
  `Iso15693.sendRequest`, the general carrier: request flag, command code, data. Alongside
  it, `fastReadMultipleBlocks`, `extendedFastReadMultipleBlocks`,
  `extendedWriteMultipleBlocks`, `extendedGetMultipleBlockSecurityStatus`, `authenticate`,
  `keyUpdate`, `challenge`, `readBuffer`, and the two commands that take a
  `Iso15693CommandConfiguration` so CoreNFC retries inside its own session rather than
  paying a round trip to Dart per attempt.

  Four of these hand back the tag's 8-bit response flag, which is now the new
  `Iso15693ResponseFlag` set on `Iso15693Response` rather than being swallowed. All of this
  is iOS 14 API, well under the 15.6 deployment target, so none of it is gated and no floor
  moved.

* **iOS silently picked one card out of a wallet and told you nothing.** *(Fix -- anyone
  whose users might tap a wallet rather than a loose card.)* When CoreNFC reported several
  tags in one detection, the plugin addressed the first and dropped the rest without a
  signal. Which card that is, is not deterministic, so the same wallet could read as a
  different card on consecutive taps and nothing anywhere said so. `NfcTag.otherTagCount`
  now reports how many others were there -- zero for the ordinary single-card tap. It is
  `null` on Android, where reader mode delivers one tag per callback and the question does
  not arise.

  Deliberately a field rather than a callback: an app should not have to opt in to being
  told its read may have been the wrong card. What to do about it stays the app's -- asking
  the user to present one card is a sentence only they can write, in only their language.

* **`package:nfc_util/apdu.dart`, so a long card response is not silently truncated.**
  *(New -- anyone talking to an ISO 7816 card, which is every DESFire, ePassport, EMV or
  applet exchange.)* Neither CoreNFC nor `android.nfc.tech.IsoDep` chains for the caller.
  When a card answers `61xx` -- "more data available, ask for the rest" -- you got the first
  frame and a status word, and code that did not know to loop got a truncated response with
  no error. Every serious consumer has been writing that loop by hand.

  `CommandApdu` encodes the four ISO 7816-4 cases in both short and extended form, so
  `IsoDep.isExtendedLengthApduSupported` finally has something that can act on it. `StatusWord`
  is a sealed hierarchy rather than an enum -- `StatusWordUnrecognised` keeps the raw bytes,
  because a card is allowed to answer something this package has never heard of and that must
  not be a crash. `Iso7816Chaining` handles `61xx` and `6Cxx` against a function you supply,
  so it works over the iOS and Android surfaces alike.

  It is opt-in, and it is not wired into `transceive` or `Iso7816.sendCommand`. DESFire's own
  `AF` continuation and ISO 7816 secure messaging manage their own, and a transport that
  chained underneath them would corrupt both.

  All of it is pure Dart with no platform call, so it runs in a plain `flutter test` with no
  device -- the same property `package:nfc_util/ndef.dart` has.

* **`package:nfc_util/testing.dart`, because the documented test story required an
  implementation import.** *(New -- anyone with a test.)* `debugReplaceApis` was exported
  from none of the four public libraries, so following the README meant importing
  `package:nfc_util/src/api.dart` and tripping `implementation_imports` -- a lint this
  package's own config turns on. It now exports `debugReplaceApis`, a `fakeNfcTag` builder
  that takes public types rather than the generated ones, and default fakes for all three
  host APIs so a test overrides only what it asserts on.

  This is not a convenience. The README already says CoreNFC sessions do not start in the
  Simulator and no emulator has an NFC radio; fakes are the only mechanism by which any CI
  exercises a tap at all. The library's own documentation states where the boundary still
  is: a host call naming a generated class or enum anywhere in its signature cannot be
  overridden without that implementation import, and the generated shapes are not
  re-exported because they change without a major version.

* **`isReaderOptionEnabled()`, for a dead end that reported itself as healthy.** *(New,
  Android.)* NFC can be on while tag *reading* is off -- a separate Android 15 switch.
  `checkAvailability()` answered `enabled`, `startSession` succeeded, and no tag was ever
  discovered. Same silent shape as the intent-side failures `checkTagIntentSetup()` was
  added for in 3.2.0. With `isReaderOptionSupported()`. Both answer `true` below API 35,
  where the switch does not exist, so `false` always means the user actually turned it off.

  Not folded into `checkAvailability()`: a new `NfcAvailability` value would be a breaking
  change for one diagnostic.

* **`openNfcSettings()`.** *(New, Android.)* Takes the user to the system NFC screen, falling
  back to wireless settings where there is none. The package already shipped
  `openTagIntentPreferenceSettings()` and already told you in two places to offer "open
  settings" only when it would help -- and then made you write the `Intent` yourself.

* **`reset()` on the Android tag technologies.** *(New, Android.)* Closes the connection and
  reopens it, reselecting the tag in the field. The plugin reuses a connection across calls
  and `isConnected` is a local flag, so a Mifare Classic authentication that fails halts the
  tag while the flag still reads true and every later command fails too. Trying a list of
  candidate keys against a sector was therefore impossible without tearing down the whole
  session. It deliberately discards sector authentication and any `setTimeout`, which is
  said plainly on the method.

  `isConnected` itself is still not exposed. It reads like a presence check and is not one.

* **The query half of `CardEmulation`.** *(New, Android.)* 3.2.0 shipped everything that
  writes -- register AIDs, set preferred, observe mode, polling-loop filters -- and nothing
  that reads back. Now `supportsAidPrefixRegistration()`, `aidsForService()`,
  `isDefaultServiceForCategory()`, `isDefaultServiceForAid()`,
  `categoryAllowsForegroundPreference()` and `selectionModeForCategory()`, with
  `CardEmulationCategory` and `AidSelectionMode`.

  `supportsAidPrefixRegistration()` is the one that earns its place: without it, registering
  a prefix AID on hardware that cannot route prefixes just fails, indistinguishable from a
  malformed AID. Every one of these has been public since API 19 or 21 -- below this
  package's own floor -- which is exactly why a version-diff reading of the platform never
  surfaced them.

* **Smaller things.** `MifareClassic.keyDefault`, `keyMifareApplicationDirectory` and
  `keyNfcForum`, the platform's own published keys, plus its block size and four card sizes;
  each key is a getter handing back a fresh list, because a shared `Uint8List` is one stray
  write away from breaking authentication process-wide with a failure that looks like a
  wrong key. `NfcUtilIos.tagIsAvailable(tag)`, which asks whether *that* tag is still
  reachable rather than whether some tag is in the field. `Ndef.uncheckedIos(tag)`, so a
  session started with `skipNdefCheck` can still read and write NDEF on iOS -- the host calls
  were always handle-based and would have worked; only the constructor stood in the way. It
  is iOS-only on purpose, and says so: on Android `skipNdefCheck` means the platform never
  attached the tech at all.

* **`Iso15693.getSystemInfo` is deprecated, not removed.** It calls a selector Apple
  deprecated in iOS 14. `getSystemInfoAndUid()` replaces it and returns the tag UID as well.
  The old one keeps working and reports `uid` as `null`.

### Crashes, stalls and leaks

A pass over the plugin's own threading and lifecycle, separate from the capability work above.
Two of these crashed an app outright; the rest cost time or memory on paths apps take
constantly.

None of it was reachable by the analyzer or the test suite. Every one was present while
`flutter analyze` was clean and the whole suite was green.

* **A tag that answered a block read with nothing took the app down.** *(Fix, iOS.)*
  `readMultipleBlocksWithConfiguration` crashed on an empty answer. It hands back an empty
  list now.

  It was an unrecoverable trap rather than an error an app could catch. That call returns one
  concatenated `Data` instead of an array, so the block size has to be recovered by division
  -- and an empty answer made the divisor zero. A zero step reaches `stride(by:)` and its
  "Stride size must not be zero" precondition, which is compiled into release builds as well
  as debug ones. Reproduced against the real standard library before and after: `SIGTRAP`,
  then no blocks.

* **Answering a reader at the wrong moment took the process down.** *(Fix, Android -- host
  card emulation.)* `HostCardEmulation.respond()` crashed unless a command APDU was in flight.
  It is a logged no-op now.

  `sendResponseApdu` writes to a `Messenger` the framework only hands over with a command
  APDU, and this was the one platform call in the plugin that was not wrapped -- so answering
  a polling frame while observe mode was on, or answering after the link had dropped, threw
  out of a Pigeon handler that does not catch. The service also drops its own static reference
  in `onDestroy` now, which `onDeactivated` alone did not cover: a component can be stopped
  with no reader exchange to end.

* **Becoming the preferred card wrote to the package manager every single time.** *(Fix,
  Android -- host card emulation.)* `setPreferredService(true)` now writes only when something
  actually changes, and reads the current state at most once per process.

  Enabling the emulation component takes the package manager's write lock, schedules a
  settings flush and broadcasts -- and this package's own documentation tells apps to make
  that call on every resume. The setting is persistent, so it was nearly always already what
  the call was about to ask for.

* **`checkTagIntentSetup()` re-ran six package-manager queries on every call.** *(Fix,
  Android.)* It works the answer out once now.

  The probe reads the manifest, which cannot change without the process restarting, so
  repeating it bought nothing. The call is still synchronous and still does that first pass on
  the platform thread; making it asynchronous would mean regenerating the whole Pigeon layer,
  which is a release of its own.

* **Every Flutter engine paid for the NFC adapter, even the ones that never touch NFC.**
  *(Fix, Android.)* The adapter is resolved on first use now instead of at plugin attach.

  `NfcAdapter.getDefaultAdapter` is a feature check plus a binder lookup, and every engine
  performs an attach -- including the background engines other plugins spin up for push
  messages and scheduled work. An app that merely depends on this package was paying for it
  there.

* **The ISO 15693 range commands checked nothing.** *(Fix, iOS.)* They share one guard now and
  report a bad range as `invalidParameter`.

  Every single-block command already narrowed its block number and reported an out-of-range
  one; the eight range commands built an `NSRange` straight from the wire values, so a
  negative block number or a zero-length range reached CoreNFC with no defined reading. The
  guard's ceiling is the extended commands' 16-bit block address -- deliberately wider than
  the 0...255 the short commands can reach, because a range this package refuses is one the
  tag never gets to answer.

* **A tag that launched the app leaked a handle on every activity rebuild.** *(Fix, Android.)*
  The one being replaced is released now.

  The launch intent is read once per attach, and an activity torn down and rebuilt inside a
  live process hands the same intent over again -- so each rebuild added a handle nothing ever
  released. A handle you already took through `takeInitialTag` is untouched.

* **`NdefMessage.toBytes()` would rather fail than write a message nothing can read.**
  *(Behaviour change.)* A type or identifier over 255 bytes raises an `ArgumentError` instead
  of being silently truncated.

  `TYPE_LENGTH` and `ID_LENGTH` are one byte each. The validating constructor has always
  refused anything longer, but `NdefRecord.fromParts` -- the decode path, which has to
  represent whatever a tag holds -- does not, and the encoder was taking the low eight bits.
  It now raises in the same words the constructor uses. Only a hand-built record reaches it:
  nothing decoded off a tag can carry a type or identifier that long, because both arrive
  through that same one-byte field.

* **`TextRecord.create` and `MimeRecord.create` now name the argument they refuse.** *(Fix.)*
  Same inputs rejected as before; only the error message changes.

  Both encoded to ASCII before checking anything, so a non-ASCII language code or media type
  surfaced as `dart:convert`'s "Contains invalid characters." -- which names neither the
  parameter nor the rule.

* **The example clears the handlers it sets.** *(Example.)* And it catches the failure of the
  APDU answer it cannot await.

  `onTagFromIntent` and `onNdefFromBackground` write to a process-wide router, so a closure
  capturing the `State` kept it, and the log it holds, alive past `dispose`. The `mounted`
  guard made a stale handler harmless, not free. The unawaited answer would otherwise surface
  as an unhandled async error with nothing to connect it to the tap that caused it.

`NfcAdapter.enableReaderMode` and `disableReaderMode` stay on the platform thread on purpose,
and now say so in the code. Both are bound to a *resumed* activity and the platform applies
them through the activity lifecycle, so moving them off it would race a rotation or a pause
and leave the controller polling for a session that is gone, or not polling for one that is
not.

### Not verified on hardware

Everything above passes the ten test layers, including a real CoreNFC build. None of it has
touched a card. The ISO 15693 security commands need a tag that implements ISO/IEC 29167,
`reset()` needs a Mifare Classic card and a wrong key, and the card-emulation queries need a
reader. The fixes above are in the same position: the emulation guard wants a reader to
exercise it, and the Android stalls they remove were found by inspecting which calls cross a
binder on the platform thread rather than by profiling a handset. `ROADMAP.md` tracks what is
still owed a measurement.

## 3.2.0

Android caught up. Three OS releases had added NFC surface this package did not reach --
observe mode and polling loop filters in Android 15, card-emulation events and a tag-scan
allowlist in Android 16, a permission on the receiving activity in Android 17 -- and two of
those changes break existing apps *silently*, with the tap simply doing nothing.

**The one entry worth reading is the first.** It is a fix, it needs no code change, and until
now it was quietly costing installs.

Nothing here is breaking: `compileSdk` stays at 36, `minSdk` at 24, the iOS deployment target
at 15.6, and no value was added to any public enum. Every new capability answers a probe with
`false` on a device too old for it, and every new *action* throws
`PlatformException('unsupported_api_level')` rather than doing nothing.

* **Apps depending on this plugin were being filtered off every device without NFC.** *(Fix
  -- every app that depends on this package, whether or not it uses anything else in this
  release.)* The plugin's manifest asked for `android.permission.NFC` without declaring the
  matching `<uses-feature android:name="android.hardware.nfc" android:required="false">`.
  Play *infers* the feature as required from the permission, so an app offering NFC as one
  feature among many was invisible on Play to anyone whose phone has no NFC controller -- and
  nothing in the app, the build or the console said so. The feature is now declared, and not
  required. An app that genuinely cannot work without NFC overrides it with `tools:replace`;
  see the README.

* **`checkTagIntentSetup()` reports the two silent Android 16/17 failures.** *(New --
  anyone whose app can be launched by a tag.)* Android 16 lets the user switch an app off a
  per-app "Launch via NFC" allowlist. Android 17 refuses to dispatch NFC intents to an
  activity that is not protected by `android.permission.DISPATCH_NFC_MESSAGE`. Both fail with
  no error, no log line and no way for the app to notice. One call now answers both, and
  lists by name the activities in your app that answer an NFC intent without the permission.
  It finds them by probing, because Android exposes no way to read an activity's intent
  filters; the README says exactly which filter shapes the probe covers.

  Also `isTagIntentAllowed()`, `isTagIntentAppPreferenceSupported()` and
  `openTagIntentPreferenceSettings()`, which takes the user to the switch. `isTagIntentAllowed`
  answers true on a device with no allowlist, so false always means the user actually said no.

* **Observe mode works without registering AIDs, and the polling-loop pattern syntax is
  documented correctly.** *(Fix, found by review before release.)* Two defects in the feature
  above, both caught on an Android 17 device rather than by reading the code. The plugin only
  ever claimed its emulation service inside `registerAids`, so the documented observe-mode
  sequence turned observe mode on into nothing: measured, `setObserveModeEnabled` returned
  false and `isObserveModeEnabled` stayed false, and even had it succeeded,
  `processPollingFrames` drops every batch when no engine has claimed the bridge. The service
  is now claimed by the observe-mode and polling-filter calls too, so an app can watch readers
  without offering to be a card; after the fix the same sequence reports
  `setObserveMode=true, isEnabled=true`. Separately, `registerPollingLoopPatternFilter` is
  **not** a regular expression: the pattern must begin with hex digits and may then use `*`
  and `?`, so the `'.*'` this package's own README and example used threw every time. `6A*`
  and `6A01` are accepted; `.*`, a bare `*`, `????` and `*6A*` are rejected.

* **Observe mode and polling loop filters.** *(New -- host card emulation, Android 15 and
  above.)* The phone can now watch a reader's polling loop without answering it, which is how
  an app sees which terminal it is at before deciding what to present:
  `isObserveModeSupported()`, `setObserveModeEnabled()`, `setDefaultToObserveMode()`,
  `registerPollingLoopFilter()`, `registerPollingLoopPatternFilter()`, their removals, and
  `onPollingFrames`. Frames arrive batched, carry their type, bytes, vendor gain and
  timestamp, and a frame type this release has no name for still arrives rather than being
  dropped -- a reader's proprietary probe is often the thing an app registered a filter for.

  `setObserveModeEnabled` returns `false` rather than throwing when the app is not the
  preferred service, because that is an ordinary state to be in. Call `setPreferredService(true)`
  first.

* **`setDiscoveryTechnology` and `getAntennaInfo`.** *(New -- Android 15 and Android 14
  respectively.)* The first narrows what the controller polls for and answers as while your
  activity is in the foreground -- narrower than reader mode, and reaching tags delivered by
  intent too. An empty `listen` set stops the phone answering readers at all. The second
  reports where the antennas are, in millimetres, for a "hold your tag here" hint; it returns
  null on the many devices that publish no geometry.

* **A card-emulation event stream.** *(New -- Android 16 and above.)* AID conflicts, unrouted
  AIDs, preferred-service and observe-mode changes, remote-field changes and NFC stack errors,
  as one `Stream<NfcEvent>` behind `enableNfcEvents()`. Registration is explicit rather than
  implicit in listening, because it costs a framework callback the plugin has to unregister
  again -- one left behind keeps the plugin, and through it the Flutter engine, alive after
  teardown. The plugin unregisters on engine detach regardless.

* **`ACTION_TAG_DISCOVERED` is deprecated as of Android 17, and still accepted.** *(No
  change needed.)* Every device up to API 36 still delivers it, so dropping it would make a
  working app go quiet the moment it was rebuilt against a newer `compileSdk`. New manifests
  should use `NDEF_DISCOVERED` or `TECH_DISCOVERED`.

* **A README section for Android 16 and 17, and four troubleshooting rows.** *(Docs.)* What
  changed, what fails silently, and what to do. The `DISPATCH_NFC_MESSAGE` question was
  measured on hardware rather than guessed at: the permission turns out not to be new at all
  -- `dumpsys package` reports it as platform-declared (`sourcePackage=android`,
  `signature|privileged`) and held by the NFC system service on an API 28 phone as well as on
  an API 37 Pixel, so API 37 merely starts *enforcing* it. Guarding an activity with it is
  therefore safe on old devices, and the example now ships the `<activity-alias>` as live
  configuration rather than as a comment. Reader sessions and foreground dispatch are
  unaffected by every Android 16 and 17 change, and the README now says so where it matters.

* **The example's NFC intent filters moved to a guarded `<activity-alias>`.** *(Example.)*
  `MainActivity` carried both the launcher filter and the NFC filters, and
  `android:permission` guards a whole activity -- so the attribute could not go there without
  gating the launcher. The alias takes the taps and carries the permission; `MainActivity`
  stays unguarded. Verified on both devices: `checkTagIntentSetup()` reports `unguarded: []`
  with the permission in place and names the alias without it.

* **A sixth test layer, because a malformed manifest reached a device build.** *(Fix -- CI.)*
  `tool/check_xml.py` parses every XML in the package and rejects `--` inside a comment, which
  is illegal in XML and legal everywhere else this codebase writes em-dashes; and the Kotlin
  step now also runs `:nfc_util:assembleDebug`, which is what actually processes the plugin
  manifest. Neither `:nfc_util:test` nor any Dart layer reads that file, so a manifest that
  did not parse used to surface only in a *consuming app's* build, naming a file its author
  has never opened.

* **The example app gained a `Capabilities` button and observe-mode controls.** *(Example.)*
  The capability probes need no tag and no radio, so they answer on a phone with NFC switched
  off -- which is exactly when you want to know what the device could do.

Not in this release, and deliberately: everything that needs a compile SDK newer than 36, or
an Xcode newer than the current one. That is a smaller set than it first looks -- Android now
ships *minor* SDK releases, and most of what looks like Android 17 surface is in fact API
36.1: the power-saving trio, the per-service screen-on/unlock switches, the polling-filter
readback and `onOffHostAidSelected` all carry `since="36.1"`. Only `allowOneTransaction`, the
reader-mode annotation pair and `getGestureExchangeAid` need API 37. On iOS, iOS 26.0 brings
`NFCPaymentTagReaderSession` and 26.4 brings a run-time session configuration for the ISO 7816
and FeliCa discovery lists. [ROADMAP.md](ROADMAP.md) has the verified split, the floor each
group would impose, and the three maintenance items reading the SDKs turned up.

## 3.1.2

Documentation only. The plugin, the example app and the tests are byte for byte what 3.1.1
shipped, so **there is nothing here to upgrade for** unless you are reading the README.

* **The README now opens with a step-by-step Quick start.** *(Docs -- anyone setting the
  package up for the first time.)* Six numbered steps take an empty project to a tag read on
  a real phone: add the package, do nothing on Android, do three things on iOS, paste one
  complete `main.dart`, run it on hardware, and know what each platform looks like when it
  works. The Dart in step 4 is a whole file rather than a fragment -- imports, widget,
  availability check, session, cleanup -- and it was compiled, analyzed and formatted
  against this version before being embedded, rather than written into the README by
  hand.

* **`Setup` is split into what everyone needs and what almost nobody does.** *(Docs.)* It is
  now `Setup in detail`, with the reader-only minimum first and the background-tag intent
  filters, the card emulation description, the ISO 7816 identifiers and the VAS format each
  behind a plain statement of when they apply. Previously all of them sat in one list, and
  an app that only wanted to read a tag could not tell which four of the five iOS items it
  could skip.

* **A troubleshooting table, and a table of contents.** *(Docs.)* The table is written from
  the symptom rather than the cause, starting with the iOS reader sheet that never appears
  because the FeliCa system codes are missing -- previously a sentence buried in prose, and
  the mistake people hit first.

Also corrected: the host card emulation section said a background engine "is not in 3.0.0",
which told a reader on 3.1.x nothing about their own version.

## 3.1.1

The plugin itself is byte for byte what 3.1.0 shipped. Everything here is the example app
and the checks around it, so **an app that does not open `example/` has no reason to
upgrade** -- nothing it depends on changed.

The one entry worth reading is the first: on Flutter 3.47 and newer the example would not
build for Android at all, which is a bad first impression for anyone evaluating the package.

* **The example app builds again on current Flutter.** *(Fix -- anyone building `example/`
  for Android on Flutter 3.47 or newer. Nothing to change if you only depend on the plugin.)*
  Flutter 3.47 raised the minimum Gradle it accepts to 8.14.0, and the example still shipped
  the 8.13 wrapper, so `flutter build apk` stopped with "Your project's Gradle version is
  lower than Flutter's minimum supported version" before compiling anything. The wrapper now
  asks for Gradle 8.14.3, which older Flutter versions accept too. The plugin's own Android
  build was never affected: it uses the host app's wrapper, not this one.

* **The example demonstrates the package without a tag, and says what it is doing while it
  waits for one.** *(Internal -- only affects people reading or running `example/`.)*
  "Build & decode NDEF" builds a message with all five record types and decodes it again in
  pure Dart, so the example is no longer a screen of greyed-out buttons on a simulator. A
  running session shows a progress strip and a sentence, which on Android was previously
  invisible; "Stop session" appears only while one is running; the log reads in the order it
  was written, colours failures and can be copied whole; a blank tag is formatted with
  `NdefFormatable.format` instead of being reported as unwritable; and "Inspect tag" probes
  every typed view each platform offers, including `Iso15693`, which was missing entirely.
  The app is now called "NFC Util" on the home screen instead of `nfc_util_example`.

Also not visible to an app: `pub publish --dry-run` moved out of the per-push CI job, because
it fails a build over warnings that say nothing about the code, and the workflow's actions
were bumped off the deprecated Node 20 runtime. The example's widget tests go from one to two
-- the second drives the NDEF codec end to end, which is the only part of the app a test can
reach with no platform behind it.

## 3.1.0

Four bugs, and all four failed the same way: something went wrong and the app was never told.
Next to 3.0.1, a scan that dies when the phone is rotated now says so, an error handler that
fails leaves a trace instead of vanishing, and two settings that used to be changed quietly on
their way to the platform are now rejected up front.

**Is this a safe upgrade?** For nearly every app, yes -- upgrade and the fixes apply on their
own. No class, method, parameter or enum changed its name or its shape, so nothing has to be
rewritten. One thing is worth checking first: an app that passes an empty `pollingOptions` set,
or a presence-check delay that is negative or longer than about 24.9 days, now gets an
`ArgumentError` from the call itself, with a message saying why. Neither input ever did what it
looked like it did, so an app passing one was already broken on at least one platform -- the
failure is just loud now instead of silent. Those are the last two entries below.

* **Rotating the phone during a scan no longer leaves the app waiting for a tag that cannot
  arrive.** *(Fix -- Android only; no code change needed.)* The scan really is over once the
  activity goes away: reader mode needs an activity, and the reattach after a rotation does not
  bring the session back. Nothing said so, though. Tearing reader mode down never told Dart, so
  the app's `onDiscovered` and `onError` stayed registered and it went on believing a scan was
  running while nothing was polling. Both activity detaches now report an error with
  `sessionEnded: true`, the signal an app already handles for a timeout or a user cancel, so
  the scan can be restarted the same way. Engine detach stays silent on purpose: the Dart
  isolate that would receive the message is going away too.

* **An `onError` handler that fails partway through is now reported instead of vanishing.**
  *(Fix -- both platforms; matters to apps whose `onError` is `async` and can throw. No code
  change needed.)* A handler that awaited something and then threw produced an unhandled zone
  error far from its cause, with nothing in it naming this plugin. `onError` is typed
  `Future<void> Function(NfcError)` and the future it returned was discarded; a synchronous
  throw was already caught by the generated Pigeon handler, so only a throw after the handler's
  first `await` escaped. That future is now watched, and a failure goes to
  `FlutterError.reportError` with `library: 'nfc_util'`. Dispatch is still synchronous rather
  than awaited, so restarting a session from inside `onError`, the pattern the docs describe,
  keeps working.

* **`pollingOptions: {}` now throws `ArgumentError` instead of meaning one thing on Android and
  the opposite on iOS.** *(Behaviour change -- only for callers that pass an empty set; pass
  `null` instead.)* An empty set made Android scan for everything while iOS refused to start at
  all -- the same code, opposite outcomes. Android was substituting all four reader flags; iOS
  returned an `unavailable` error. The check now runs in Dart, before either platform is
  touched. `null` has always been the way to ask for "poll for everything".
  `NfcUtilAndroid.enableReaderMode` rejects an empty `flags` set for the same reason, and there
  the old behaviour was worse: the raw flag list has no all-technologies fallback, so an empty
  set started reader mode with flags `0`, polling for nothing at all.

* **A presence-check delay the platform cannot carry now throws `ArgumentError` rather than
  quietly becoming a different number.** *(Behaviour change -- only for callers passing a
  negative delay or one over about 24.9 days; the 250 ms default is unchanged.)* A negative
  `Duration` reached the reader as a negative delay, and anything past `0x7fffffff`
  milliseconds wrapped around into some other number entirely -- thirty days arriving as a
  negative one. Dart sends the `Duration`'s `inMilliseconds` as a 64-bit value and Kotlin
  narrows it with `.toInt()` before putting it in the reader-mode bundle, so both cases
  corrupted the extra without a word. Zero to `0x7fffffff` milliseconds is accepted. Applies to
  `presenceCheckDelayAndroid` on `NfcUtil.startSession` and to `presenceCheckDelay` on
  `NfcUtilAndroid.enableReaderMode`.

None of the rest is visible to an app. `analysis_options.yaml` now declares the formatter
settings the sources are actually written at -- `page_width` 120 and `trailing_commas` preserve
-- so `dart format` and pana, which scores the package on pub.dev, agree with the code rather
than fight it, and `tool/generate_pigeon.sh` no longer passes `--line-length` by hand. The
example moves from `flutter_lints` 5 to 6, matching the package. A new CI workflow runs the
format check, both analyzers, both Dart suites and a publish dry run, with a separate job for
the Kotlin unit tests -- which is what would have caught the formatting drift. The Dart unit
tests go from 106 to 117.

## 3.0.1

Two things that are cheap to change now and expensive once apps depend on them. 3.0.0 was
never published, so this supersedes it.

* **A `PlatformException` from a tag operation now carries the same code on both platforms.**
  iOS spelled two of them `invalid_parameter` and `no_result` while Android spelled the same
  conditions `invalidParameter` and `unknown`, so `e.code == 'invalid_parameter'` matched on
  one platform and never on the other, and
  `NfcAndroidErrorCode.values.byName(e.code)` -- which the docs advertise -- threw on iOS for
  the two most ordinary failures. Every tag-operation code now spells an enum value.

  The three codes that describe the session rather than a tag name no enum value and stay as
  they are, but are no longer literals a caller has to retype: `NfcErrorCodes.unavailable`,
  `.sessionAlreadyExists` and `.noActivity`.

* **Consumers no longer get a build warning naming this plugin.** It applied the Kotlin
  Gradle plugin itself, which the Flutter tool warns about on every build of every app that
  depends on it -- "future versions of Flutter will fail to build". The Kotlin plugin now
  comes from the consuming project, as the current plugin template does, and `jvmTarget`
  moved to the top-level `kotlin` block with it.

* **A session that ends by itself now disarms itself.** Only `stopSession` ran the teardown,
  so a scan the user cancelled or that timed out left its callbacks on the handler stack for
  the life of the process. `onError` now drops the arm it dispatched to when the session is
  over -- by identity, so restarting from inside `onError`, which is what the docs suggest,
  is not deafened by its own cleanup.

* **iOS background tag reading adopts the scene lifecycle.** It rode Flutter's app-delegate
  fallback, which Flutter's own headers describe as the path for plugins that are not
  scene-aware. A tag tapped while the app runs now arrives through `scene(_:continue:)`, and
  a tag that launched the app through `scene(_:willConnectTo:options:)` -- the only place a
  launch-time activity appears, since UIKit never calls the continue hook at launch. The
  app-delegate hooks stay for non-scene apps.

* **A failed `registerAids` no longer leaves the app enrolled as a card.** Enabling the
  emulation component is persistent -- it survives process death, reboot and app update -- and
  it was switched on before the registration was attempted and never put back if the
  registration threw or was refused. An app whose call returned false was left claiming the
  placeholder AID forever, answering every reader with `6D00`. Both paths now roll it back.

  That persistence is now documented, on `registerAids`, on `unregisterAids` and in the
  README: `unregisterAids()` is the only way to undo a successful registration short of
  uninstalling, and the README's sample AID is called out as a sample.

### Documentation

* `startSession`'s per-parameter comments were dropped by dartdoc, hover and autocomplete
  alike, so three options were documented nowhere a caller looks. They are in the method doc
  now.

* The "new in 3.0.0" list named `restartPolling` and `setAlertMessage`, which do not exist:
  they are `NfcUtilIos.tagSessionRestartPolling`, `tagSessionSetAlertMessage` and
  `vasSessionSetAlertMessage`. The two session controls also got a snippet in the README,
  which never showed them.

* `vasSessionBegin` claimed to need the ISO 7816 select-identifiers key. That belongs to tag
  sessions; a VAS session needs the entitlement and `NFCReaderUsageDescription`, and takes
  its pass type identifiers per command.

## 3.0.0

A full rewrite, and the first release since 2.2.0. Every import and most names changed, the
platform channel is now generated rather than hand-written, and three subsystems that did
not exist before are in: background tag reading, host card emulation, and Apple Value Added
Services.

See the README for the complete 2.2.0 mapping table.

### Breaking

* **The entry-point class is now `NfcUtil`, not `NfcManager`.** There is no deprecated
  alias, so code using the old name stops compiling until it is updated.

  ```dart
  await NfcUtil.instance.startSession(onDiscovered: (tag) async { /* ... */ });
  ```

* **The libraries are split by platform.** `package:nfc_util/platform_tags.dart` is gone.
  Android technologies come from `package:nfc_util/android.dart`, iOS ones from
  `package:nfc_util/ios.dart`, and NDEF from `package:nfc_util/ndef.dart`. Portability is
  told by the import path rather than by a suffix on every class name, and the two platform
  libraries can be imported together under prefixes.

* **NDEF record construction moved to the typed record classes.**
  `NdefRecord.createText(...)` is now `TextRecord.create(...)`, and likewise `UriRecord`,
  `MimeRecord` and `ExternalRecord`. Each of them also parses: `TextRecord.from(record)`
  returns null rather than throwing when the record is something else. 2.x could only build
  records, never read them back.

* **`NfcErrorType` is gone.** An error now carries `source` plus one of `iosCode` /
  `androidCode`. The coarse three-value category could not distinguish the failures that
  matter, and widening it would have broken exhaustive switches anyway.

* **Platform-only session options carry a platform suffix**: `alertMessageIos`,
  `invalidateAfterFirstReadIos`, `noPlatformSoundsAndroid`, `discoverNfcBarcodeAndroid`.
  There is no import path to disambiguate a parameter, so the name has to.

* **Android-only entry points moved to `NfcUtilAndroid`**: `onAdapterStateChanged`,
  `isSecureNfcSupported`, `isSecureNfcEnabled`.

* **`isAvailable()` is removed**, as 2.1.0 said it would be. Use `checkAvailability()`.

* `NfcTag` no longer carries a raw map. The tag identifier is `tag.id` and the Android
  technology list is `tag.techList`; 2.x repeated the identifier on twelve of its thirteen
  technology classes.

* Timeouts are `Duration` rather than `int` milliseconds, and `MifareClassic.type` /
  `MifareUltralight.type` are enums rather than raw ints.

* `Ndef.canMakeReadOnly` moved to `NdefAndroid`, which is where it is actually knowable.

### Added

* **Background and launch-on-tag reading.** On Android, `NfcUtilAndroid.takeInitialTag()`
  and `onTagFromIntent` deliver tags that arrive by intent filter, plus
  `enableForegroundDispatch()` to stop another app claiming a tap while yours is on screen.
  On iOS, `NfcUtilIos.takeInitialNdefMessage()` and `onNdefFromBackground` catch the NDEF
  message iPhone XS and later read with no app running. The manifest filters have to live
  in the application because they name its own activity; the README carries the block.

* **Host card emulation** (`package:nfc_util/android.dart`). The phone
  answers a reader as a card: `registerAids` registers application identifiers at run time
  so the set can change without a release, `onApduReceived` / `respond` carry the exchange,
  and `setPreferredService` keeps a tap from going to the user's wallet instead. APDUs are
  bridged only while the Flutter engine is alive; a tap with the app fully stopped is
  answered with `6D00`. Emulating while closed needs a background engine, which is not in
  this release. Android only -- Apple's equivalent is not available to third-party apps.

* **Apple Value Added Services.** `NfcUtilIos.vasSessionBegin` reads Wallet passes rather
  than tags, with `vasSessionInvalidate`, `vasSessionSetAlertMessage` and
  `vasSessionReadingAvailable`. Needs `VAS` in the reader session formats entitlement.

* **An NDEF wire codec in pure Dart.** `NdefMessage.toBytes()` and
  `NdefMessage.fromBytes()` implement the NFC Forum format, so a message can be built or
  parsed with no tag in range -- which is what card emulation and intent payloads need, and
  what makes the whole layer testable without a device. Chunked records are reassembled on
  decode.

* **Smart posters.** `SmartPosterRecord.create` / `.from` handle the nested-message record
  a printed NFC poster carries, including title, action and icon.

* **iOS session control**: `tagSessionSetAlertMessage` to narrate a multi-step exchange,
  `tagSessionRestartPolling` to move on from a tag early, and an `onBecameActiveIos`
  callback for when the reader sheet is actually up.

* **Continuous scanning that does not race the app.** With
  `invalidateAfterFirstReadIos: false` the session polls again after each tag -- but only
  once `onDiscovered` has returned, so a tag is never dropped out from under an app that is
  still reading it.

* **`NfcUtilAndroid.enableReaderMode(flags:)`**, the raw escape hatch for reader flag
  combinations the cross-platform call does not express, and `presenceCheckDelayAndroid`,
  which 2.x hardcoded to 250 ms.

* **`NdefIos.queryStatus()`**, the live NDEF status as opposed to the copy captured at
  discovery -- the way to confirm a tag actually locked.

* **`NfcError.sessionEnded`**, the difference between "start a new session" and "keep
  waiting". Every CoreNFC failure ends the session, but on Android a tag that could not be
  read leaves reader mode polling -- and starting again there is refused, so an app that
  restarted on every error would go permanently deaf.

* `Iso7816ResponseApdu.statusWord` and `.isSuccess`, and `FeliCaStatusFlag.isSuccess`.

### Fixed

* **`onError` now fires on Android.** In 2.x it was iOS-only: the Kotlin side never invoked
  it, so a tag that failed at discovery left the app watching a session that looked alive
  and delivered nothing. Android failures are also classified into eight typed codes rather
  than four bare strings, so "the tag moved" and "the tag refused the command" are finally
  distinguishable.

* **A second `startSession()` is rejected on both platforms** with `session_already_exists`.
  Android used to replace the running session in silence, so the same code behaved
  differently per platform.

* **iOS connect failures are reported rather than swallowed.**

* `Ndef.read()` no longer reports a zero-length message as a failure on iOS.

* **iOS no longer delivers a tag for a session it no longer owns.** The NDEF probe is two
  round trips and CoreNFC still runs a pending completion after the session dies, so a tag
  could be registered in a map `stopSession` had just emptied and handed to an app that had
  already been told the session was over.

* **iOS no longer loses a newly-started session to the old one's invalidation.**
  `invalidate()` returns long before CoreNFC calls back, so a `stopSession` immediately
  followed by a `startSession` had the old session's death notice arrive after the new one
  was stored, clearing it -- which dropped the live session's only strong reference, wiped
  the tags it had registered, made `stopSession` a no-op and let the next `startSession`
  slip past the guard into a second concurrent session. An invalidation for a session the
  plugin no longer owns is now ignored.

* **A refused `startSession` no longer silences the session that is still running.** 2.2.0
  cleared the callbacks whenever a start threw, so a start refused while a session was live
  left that session holding the radio and delivering to nobody. The handlers are a stack
  now, so a refusal restores whatever was armed before it -- correct even with two starts in
  flight, where saving and writing back a single previous value is not.

* **An out-of-range block or APDU number no longer kills the app on iOS.** 2.2.0 force-cast
  the argument to `UInt8`; the rewrite's `UInt8(...)` trapped. Neither is reachable now: the
  thirteen narrowing sites report `invalid_parameter` instead. This is not a corner case --
  `Iso15693.getSystemInfo()` reports `totalBlocks`, a 2048-block tag is ordinary, and the
  obvious loop over every block died at block 256.

* **`NfcV.dsfId` and `responseFlags` are unsigned.** `android.nfc.tech.NfcV` reports them as
  signed bytes and 2.2.0 passed them straight through, so a DSFID of `0xA5` arrived as -91 --
  while iOS reported 165 for the same physical tag.

* **`getMaxTransceiveLength` and `getTimeout` no longer disturb the connection.** Both read
  the technology's static description, but 2.2.0 routed them through the connecting path,
  and reconnecting reselects the tag. Asking a tag how long its packets may be, between
  authenticating a Mifare Classic sector and reading it, silently undid the authentication.

* **A type or identifier longer than 255 bytes is refused rather than truncated.** Both are
  one-byte length fields on the wire; 2.2.0 wrote the low byte and produced a message that
  neither this package nor the platform could read back.

* **One unreadable technology no longer costs the whole tag on Android.** Every getter on
  `android.nfc.tech` is unannotated Java, and some of the values really are absent: AOSP
  fills the NfcA and NfcB poll-byte extras only once they are long enough, and a B-prime
  target -- Innovatron, legacy Calypso transit -- answers no SENSB_RES at all while still
  being reported as ISO 14443-3B. Reading one of those threw while describing the tag, and
  the tag was dropped entire: an app that only wanted the UID, or an IsoDep exchange, was
  handed nothing and told only `unknown`. Each technology is now described independently, so
  a technology that cannot be read is absent while the rest of the tag arrives.

  `NfcA.atqa`, `NfcB.applicationData`, `NfcB.protocolInfo`, `NfcF.manufacturer` and
  `NfcF.systemCode` are nullable accordingly. Empty would have been a lie: it is not "the tag
  answered nothing", it is "the platform never told us".

* **A tag delivered by intent that cannot be read is reported rather than dropped.** That
  path has no session behind it, so an app that never hears about the tap had nothing at all
  to go on.

* **Reader mode on a switched-off adapter fails instead of starting.** It used to begin
  without error and then discover nothing, which is indistinguishable from a tag never being
  presented. Reported as `adapterDisabled`.

* **iOS no longer sends channel replies from CoreNFC's queue.** Every tag operation
  completes on the session's own queue, but replies belong to the platform thread. They now
  hop back. A reply already raised on the platform thread stays synchronous, so nothing that
  was correctly ordered is reordered.

### Changed

* **The platform channel is generated by Pigeon.** This removes `lib/src/translator.dart`,
  `android/.../Translator.kt` and `ios/.../Translator.swift` -- 813 lines of hand-written
  codec that had to be kept in step by hand across three languages. Enum bridging is an
  exhaustive `switch` on both sides, so a value added on one side and not the other fails
  the build instead of throwing on a user's device.

* **Twenty-four Android channel methods collapsed into four.** The technology is a
  parameter now, so seven `transceive` entry points became one, and likewise seven
  `getMaxTransceiveLength` and five each of `getTimeout` and `setTimeout`. Android answered
  49 channel methods in 2.2.0 and answers 37 now, ten of which have no 2.2.0 counterpart:
  five for card emulation, three for background reading, and the raw `enableReaderMode`
  pair.

* The example app was rewritten and covers every subsystem, including card emulation,
  background reading and Wallet passes.

### Tests

134 in total, up from 57: 103 Dart (was 51), 19 Swift (2.2.0 shipped only the generated
template, which did not compile), 11 Kotlin (was 5), plus the example's widget test on both
sides. Among them: the handler stack over all three start interleavings, byte narrowing at
its boundaries, the type and identifier length refusal, and a smart poster whose real
destination a leading absolute-URI record used to shadow.

The Dart suite now covers the session lifecycle, tag resolution and error mapping, by
swapping a fake in for the generated host API -- none of which was reachable in 2.x. The NDEF
codec is pure Dart and covered directly, round trip included. Two bugs surfaced that way: TNF
0x07 is reserved and raised `RangeError` instead of `FormatException`, and
`checkAvailability()` never completes in a widget test with no mock registered.

`TagMapper.ndefToWire` was split out of the tag conversion so the `skipNdefCheck` behaviour
stays testable: the `NFCTag` enum wraps concrete CoreNFC types with no public initializer,
but the `NFCNDEFTag` protocol can be faked.

Host card emulation, background reading and Wallet passes cannot be automated: they need a
reader, a closed app and a real pass respectively. `NFCTagReaderSession` does not start in
the Simulator, no emulator has an NFC radio, and the Kotlin target still has no mocking
framework, so the plugin class itself is covered by review rather than by tests.

## 2.2.0

The rest of the Android platform-API catch-up. Android-only additions; nothing is breaking.

### Added

* **`NfcManager.onAdapterStateChanged`**, a `Stream<NfcAdapterState>` that emits when the
  user switches NFC on or off in system settings. Pairs with `checkAvailability()`: check
  once at startup, then react to changes instead of polling. The stream does not replay the
  current state. On iOS it never emits — there is no NFC toggle to watch.

  The receiver is registered against the application context, so a configuration change does
  not churn it, and it is unregistered on activity and engine detach.

* **`NfcBarcode`** tag class and the **`startSession(discoverNfcBarcode:)`** flag that makes
  it reachable. Barcode (Kovio) tags are only discovered when `FLAG_READER_NFC_BARCODE` is
  set, so the flag is the point — without it the tag class can never be reached. The class carries
  `identifier`, `barcodeType` and `barcode`, and has no operations, because
  `android.nfc.tech.NfcBarcode` has none.

* **`startSession(skipNdefCheck:)`** sets `FLAG_READER_SKIP_NDEF_CHECK`, which makes
  discovery measurably faster by skipping the platform's NDEF probe. `Ndef.from(tag)` then
  returns null, so use it only when the tag's NDEF content does not interest you.

* **`NfcManager.isSecureNfcSupported()` / `isSecureNfcEnabled()`**. Secure NFC restricts tag
  reading to an unlocked device. Android API 29+; both return false below that and on iOS.

* **`MifareClassic.blockToSector()` / `sectorToBlock()` / `getBlockCountInSector()`**. Sector
  geometry is not uniform — a 4K card has 32 sectors of 4 blocks followed by 8 of 16 — so
  this arithmetic cannot be done by hand from `blockCount` and `sectorCount`. These resolve
  the technology without opening a connection, since they read a static description rather
  than talking to the tag.

## 2.1.0

Catches up with the useful parts of the Android and CoreNFC platform APIs. Nothing here is
breaking: existing code compiles and behaves as it did.

### Added

* **`NfcManager.checkAvailability()`** returns `NfcAvailability.enabled`, `.disabled` or
  `.unsupported`. `isAvailable()` could only say "no", which conflated a device with no NFC
  hardware and a device where the user has switched NFC off — so an app could not tell
  whether pointing the user at system settings would help. Android reports all three; iOS
  never reports `.disabled`, because CoreNFC has no such state. `isAvailable()` still works
  but is deprecated and will be removed in 3.0.0.

* **`NfcError.code`** carries the exact CoreNFC failure as a new `NfcReaderErrorCode` enum
  (24 values). The iOS side previously mapped 3 of CoreNFC's 22 error codes and dropped the
  rest, so a lost tag, a disabled radio, a too-small tag and a security violation all
  arrived as `NfcErrorType.unknown` with nothing to tell them apart. `NfcErrorType` itself
  is unchanged — widening it would have broken exhaustive `switch` statements — so `type`
  stays the coarse category and `code` carries the detail. Null on Android, and null on iOS
  for failures that did not come from CoreNFC.

  The two codes added in the iOS 26 SDK (`ineligible`, `accessNotAccepted`) are matched by
  raw value, so the plugin still compiles against older SDKs. An unrecognised code decodes
  to `NfcReaderErrorCode.unknown` rather than throwing.

* **`setTimeout` / `getTimeout` / `getMaxTransceiveLength`** on the Android tag classes.
  `timeout` and `maxTransceiveLength` are snapshots taken at discovery, so the timeout could
  be read but never changed — there was no way to give a slow tag more time before the
  exchange failed as `tag_lost`. `setTimeout` and `getTimeout` are on `IsoDep`, `NfcA`,
  `NfcF`, `MifareClassic` and `MifareUltralight`; `getMaxTransceiveLength` is on those plus
  `NfcB` and `NfcV`. `android.nfc.tech` offers no timeout accessor for NfcB and NfcV. The
  existing fields are untouched.

* **`startSession(noPlatformSounds:)`** (Android). `FLAG_READER_NO_PLATFORM_SOUNDS` was
  applied unconditionally, so the system tag-discovery sound could never play and there was
  no way to ask for it. It is now a parameter. **It defaults to `true`**, matching what every
  release before this one did. Pass `noPlatformSounds: false` to let the sound play.

* **`Ndef.canMakeReadOnly`** (Android). The native side already reported this value; it was
  only reachable by digging through `additionalData`. It is now a proper field, and no
  longer appears in `additionalData`. Null on iOS, which does not report it. Check it before
  calling `writeLock()` — not every tag can be locked.

### Fixed

* **iOS: starting a session while one is already running is now rejected** with a
  `session_already_exists` `PlatformException`. The second session used to overwrite the
  first, which was then never invalidated: its reader sheet stayed up and its tags leaked
  for the lifetime of the process.

## 2.0.0

### Requirements

* Minimum Flutter is now **3.44.0**. That is the first stable release which stages the
  `FlutterFramework` Swift package, which `ios/nfc_util/Package.swift` now depends on as
  the Flutter tool requires.
* Minimum iOS deployment target is **15.6**, declared by both the podspec and
  `Package.swift`.

### Breaking

* Removed the unused `flutter create` boilerplate: `NfcUtilPlatform`, `MethodChannelNfcUtil`
  and the `plugin_platform_interface` dependency. These were never part of the NFC API.
* `Ndef.read()` now returns `Future<NdefMessage?>`. A tag with no NDEF message previously
  crashed with a `TypeError` instead of reporting "nothing written yet".
* `MifareClassic.transceive` takes `Uint8List data` instead of `int data`.
* The Objective-C shim (`NfcUtilPlugin.h`/`.m`) is gone and the Swift class is now named
  `NfcUtilPlugin` instead of `SwiftNfcUtilPlugin`. Swift Package Manager does not support
  mixed-language targets, and the shim only existed to expose the Swift class to
  Objective-C. Nothing referenced these types from application code.

### Fixed

* **iOS builds work again under Swift Package Manager.** `Package.swift` declared its
  sources at `Classes/`, which does not exist inside the package root, so the target was
  empty and `xcodebuild` refused to resolve it. Since Flutter 3.44 enables SPM by default,
  this failed every iOS build. The native sources now live at
  `ios/nfc_util/Sources/nfc_util/`, shared by both the podspec and `Package.swift`.

* **Android: implemented every tag I/O method.** `Ndef#read`/`write`/`writeLock`,
  `NfcA`/`NfcB`/`NfcF`/`NfcV`/`IsoDep#transceive`, all nine `MifareClassic` commands,
  the three `MifareUltralight` commands and `NdefFormatable#format`/`formatReadOnly`
  previously threw `MissingPluginException`. Tag I/O runs on a dedicated thread and reuses
  the open connection, so a `MifareClassic` sector authentication still holds for the
  following `readBlock`.
* **iOS: tag I/O inside `onDiscovered` works again.** 1.0.3 invalidated the session as soon
  as a tag was serialized, so `Ndef.read()`/`write()`, `Iso7816.sendCommand()` and friends
  failed with "Tag is not found". With `invalidateAfterFirstRead: true` the session now
  stays open until the app calls `stopSession()`.
* iOS: `Nfc#stopSession` no longer submits its Flutter reply twice when `errorMessage` is
  given (missing `return`), which also invalidated the session twice.
* iOS: an unrecognized tag type left the reader sheet hanging until the 60 s timeout because
  the completion handler was never called.
* iOS: starting a session with an unusable polling option reported success while no session
  had begun; it now returns an `unavailable` error.
* iOS: the tag map is written from the CoreNFC delegate queue and read from the platform
  thread; access is now serialized.
* `FeliCa.requestSpecificationVersion()` invoked `FeliCa#requestSpecificationVersionResponse`,
  which no platform implements, so it always threw `MissingPluginException`.
* `onDiscovered` callbacks that throw no longer leak the native tag handle, and the error is
  no longer swallowed as an unhandled async error.
* Decoding unknown NDEF type-name-format, MiFare family or error-type values from the
  platform threw `StateError`; these now fall back to their `unknown` variants. Records read
  off a tag also skip the creation-time format validation, which rejected legitimate chunked
  records.
* Android: reader mode is now disabled and the tag map cleared on `stopSession` and on
  activity/engine detach. Reader mode previously stayed active, keeping the NFC radio
  polling and holding a reference to a destroyed activity.
* Android: an empty or unrecognized `pollingOptions` list produced zero technology flags,
  which started a session that could never discover a tag. It now falls back to every
  supported technology.

### Documentation

* Documented the most common iOS setup mistake, found while testing on a device: because
  `startSession` polls `iso18092` by default, CoreNFC rejects the session with
  `Missing required entitlement` unless
  `com.apple.developer.nfc.readersession.felica.systemcodes` is in the app's `Info.plist`.
  The reader sheet simply never appears, and `startSession` still completes normally because
  iOS reports the failure asynchronously -- so an app without an `onError` callback sees
  nothing at all. The example now sets the key, passes `onError` on every session, and gained
  a "Tag I/O" button that exercises the tag commands on both platforms.

### Changed

* Android: tag errors distinguish the connect step from the command itself
  (`connect: TagLostException: ...`), and failures are logged under the `NfcUtilPlugin` tag.
  A tag that answers discovery but cannot be connected is otherwise indistinguishable from
  a command that failed.
* Android: dropped the leftover debug logging from `startSession`.
* Android: reader mode sets `FLAG_READER_NO_PLATFORM_SOUNDS` and a 250 ms presence-check
  delay.
* Platform value decoding uses constant reverse maps instead of a linear `firstWhere` scan
  per record.
* Calls whose result is required now raise a `PlatformException(code: 'no_result')` instead
  of force-unwrapping; `NfcManager.isAvailable()` returns `false` rather than throwing.
* iOS: dropped the `@available(iOS 13.0, *)` scaffolding, now that the deployment target is
  15.6.
* CocoaPods builds ship `PrivacyInfo.xcprivacy`, matching what Swift Package Manager builds
  already did.

## 1.0.3

* iOS first scan bug fixed.

## 1.0.2

* Swift Package Manager support

## 1.0.0

* flutter: min 3.32.0

## 0.1.1

* Nfc#disposeTag fixed.

## 0.1.0

* Android and iOS are done.

## 0.0.1

* TODO: Describe initial release.
