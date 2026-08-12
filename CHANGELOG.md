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

The rest of the `nfc_util` 4.x catch-up. Android-only additions; nothing is breaking.

### Added

* **`NfcManager.onAdapterStateChanged`**, a `Stream<NfcAdapterState>` that emits when the
  user switches NFC on or off in system settings. Pairs with `checkAvailability()`: check
  once at startup, then react to changes instead of polling. The stream does not replay the
  current state. On iOS it never emits — there is no NFC toggle to watch.

  The receiver is registered against the application context, so a configuration change does
  not churn it, and it is unregistered on activity and engine detach. (Upstream registers an
  equivalent receiver and never unregisters it, leaking one per attach cycle.)

* **`NfcBarcode`** tag class and the **`startSession(discoverNfcBarcode:)`** flag that makes
  it reachable. Barcode (Kovio) tags are only discovered when `FLAG_READER_NFC_BARCODE` is
  set, so the flag is the point — `nfc_util` ships the tag class but never sets the flag
  from `startSession`, leaving the class unreachable through its own API. The class carries
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
  than talking to the tag. (Upstream implements all three natively but never exposed them in
  Dart, so they are unreachable there.)

## 2.1.0

Catches up with the useful parts of `nfc_util` 4.x. Nothing here is breaking: existing
code compiles and behaves as it did.

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
  release before this one did — note this is the opposite of `nfc_util`, which defaults
  it to `false`. Pass `noPlatformSounds: false` to let the sound play.

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
