/// Fakes that stand in for the platform, so a tap can be exercised in a test. Test code only.
///
/// This library exists for a hardware reason rather than a convenience one. `NFCTagReaderSession`
/// does not start in the Simulator and no emulator has an NFC radio, so replacing the platform
/// side is the only mechanism by which any CI runs a tag through an app at all. Everything here
/// is inert -- no channel is touched, no session is started, and no handle addresses a tag -- so
/// an app that reaches for it from its own `lib/` ships that inertness to its users.
///
/// [debugReplaceApis] puts a fake platform in place and hands back the function that puts the
/// real one back; [fakeNfcTag] builds the tag the platform would have delivered; and the three
/// `Fake*HostApi` classes answer every call, so a test writes only the ones it cares about.
///
/// ```dart
/// import 'dart:typed_data';
///
/// import 'package:flutter_test/flutter_test.dart';
/// import 'package:nfc_util/android.dart';
/// import 'package:nfc_util/testing.dart';
///
/// class _Card extends FakeNfcAndroidHostApi {
///   @override
///   Future<Uint8List> mifareClassicReadBlock(String handle, int blockIndex) async =>
///       Uint8List.fromList(List.filled(16, blockIndex));
/// }
///
/// void main() {
///   late void Function() restore;
///   setUp(() => restore = debugReplaceApis(android: _Card()));
///   tearDown(() => restore());
///
///   test('reads the block it asked for', () async {
///     final tag = fakeNfcTag(techs: [FakeTech.nfcA(), FakeTech.mifareClassic()]);
///     expect(await MifareClassic.from(tag)!.readBlock(blockIndex: 4), everyElement(4));
///   });
/// }
/// ```
///
/// One thing this library deliberately does not hand over: the generated wire classes. Every
/// call that answers a plain Dart value -- the transceives, the Mifare reads, the capability
/// questions -- can be overridden with nothing but the import above, but a call that names a
/// generated class or enum *anywhere in its signature* can only be overridden by a test that
/// imports `package:nfc_util/src/pigeon.g.dart` itself. That covers more than the obvious
/// return types: `ndefRead` and the ISO 7816 exchanges answer one, and `resetTech` and the
/// card-emulation queries answer nothing at all but still take one as a parameter. That is an implementation
/// import the analyzer flags, and a shape that changes without a major version, which is why it
/// is not re-exported from here. Say it with a public type where the two are interchangeable --
/// a message handed to `FakeTech.ndefAndroid` and read back as `Ndef.from(tag)?.cachedMessage`,
/// rather than an overridden `ndefRead` -- and where they are not, the import is the price.
library;

export 'src/api.dart' show debugReplaceApis;
export 'src/testing/fake_host.dart' show FakeNfcAndroidHostApi, FakeNfcHostApi, FakeNfcIosHostApi;
export 'src/testing/fake_tag.dart' show fakeNfcTag, FakeTech;
