import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_util/android.dart';
import 'package:nfc_util/src/pigeon.g.dart';
import 'package:nfc_util/testing.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

/// A stand-in Android host that remembers which technology each call addressed.
///
/// Every operation on an `android.nfc.tech` class is a handle plus a technology, so a call
/// wired to the wrong technology reaches a live tag and fails there rather than here. The
/// technology is what this keeps.
class _FakeAndroidHost extends FakeNfcAndroidHostApi {
  final resets = <(String, AndroidTechPigeon)>[];

  /// The keys the card in this test accepts. Anything else is refused, which is the case
  /// `reset` exists for and the one the fake cannot answer on its own.
  final accepted = <Uint8List>[];

  int authenticationAttempts = 0;

  @override
  Future<void> resetTech(String handle, AndroidTechPigeon tech) async => resets.add((handle, tech));

  @override
  Future<bool> mifareClassicAuthenticateSector(String handle, int sectorIndex, Uint8List key, bool useKeyA) async {
    authenticationAttempts++;
    return accepted.any((candidate) => _sameBytes(candidate, key));
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  late _FakeAndroidHost host;
  late void Function() restore;

  setUp(() {
    host = _FakeAndroidHost();
    restore = debugReplaceApis(android: host);
  });

  tearDown(() => restore());

  group('reset', () {
    /// A tag carrying every technology that can be reset, so one tag drives all seven.
    final tag = fakeNfcTag(
      handle: 'tag-1',
      techs: [
        FakeTech.nfcA(),
        FakeTech.nfcB(),
        FakeTech.nfcF(),
        FakeTech.nfcV(),
        FakeTech.isoDep(),
        FakeTech.mifareClassic(),
        FakeTech.mifareUltralight(),
      ],
    );

    test('names the technology it was called on', () async {
      // The reconnect is per-technology, and the seven classes differ only in which constant
      // they pass. A copy-paste between two of them compiles and reconnects the wrong tag
      // interface on a device, which is not visible from Dart at all.
      final calls = <(Future<void> Function(), AndroidTechPigeon)>[
        (NfcA.from(tag)!.reset, AndroidTechPigeon.nfcA),
        (NfcB.from(tag)!.reset, AndroidTechPigeon.nfcB),
        (NfcF.from(tag)!.reset, AndroidTechPigeon.nfcF),
        (NfcV.from(tag)!.reset, AndroidTechPigeon.nfcV),
        (IsoDep.from(tag)!.reset, AndroidTechPigeon.isoDep),
        (MifareClassic.from(tag)!.reset, AndroidTechPigeon.mifareClassic),
        (MifareUltralight.from(tag)!.reset, AndroidTechPigeon.mifareUltralight),
      ];

      // The list above is written out by hand, so a technology added to the shared base
      // would otherwise inherit a reset that nothing here exercises.
      expect([for (final (_, tech) in calls) tech], unorderedEquals(AndroidTechPigeon.values));

      for (final (reset, _) in calls) {
        await reset();
      }

      expect(host.resets, [for (final (_, tech) in calls) ('tag-1', tech)]);
    });

    test('lets a wrong key be followed by a right one', () async {
      // The whole reason it exists. A refused authentication halts the tag while the cached
      // connection still looks alive, so without the reconnect in between the second attempt
      // fails too and a candidate-key loop is impossible short of asking for another tap.
      final classic = MifareClassic.from(tag)!;
      host.accepted.add(MifareClassic.keyNfcForum);

      expect(await classic.authenticateSectorWithKeyA(sectorIndex: 1, key: MifareClassic.keyDefault), isFalse);
      await classic.reset();
      expect(await classic.authenticateSectorWithKeyA(sectorIndex: 1, key: MifareClassic.keyNfcForum), isTrue);

      expect(host.authenticationAttempts, 2);
      expect(host.resets, [('tag-1', AndroidTechPigeon.mifareClassic)]);
    });
  });

  group('the Mifare Classic constants AOSP publishes', () {
    test('are the keys themselves, byte for byte', () {
      // Transcribed from `android.nfc.tech.MifareClassic`. A wrong byte here is a wrong key
      // on the wire, which a card reports as a plain authentication failure -- so nothing
      // would point at the constant.
      expect(MifareClassic.keyDefault, bytes([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]));
      expect(MifareClassic.keyMifareApplicationDirectory, bytes([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5]));
      expect(MifareClassic.keyNfcForum, bytes([0xD3, 0xF7, 0xD3, 0xF7, 0xD3, 0xF7]));
    });

    test('are six bytes each, which is the only length a sector key has', () {
      for (final key in [
        MifareClassic.keyDefault,
        MifareClassic.keyMifareApplicationDirectory,
        MifareClassic.keyNfcForum,
      ]) {
        expect(key, hasLength(6));
      }
    });

    test('cannot be corrupted for everyone by one caller mutating one', () {
      // A Uint8List is mutable. If these were a single shared instance, this line would
      // change what every later authentication in the process sends -- and the failure would
      // surface at a card as a wrong key, not as corruption.
      MifareClassic.keyDefault[0] = 0x00;

      expect(MifareClassic.keyDefault, everyElement(0xFF));
      expect(identical(MifareClassic.keyDefault, MifareClassic.keyDefault), isFalse);
    });

    test('describe the geometry the same way the card does', () {
      expect(MifareClassic.blockSize, 16);
      expect(MifareClassic.sizeMini, 320);
      expect(MifareClassic.size1K, 1024);
      expect(MifareClassic.size2K, 2048);
      expect(MifareClassic.size4K, 4096);
    });

    test('a key goes to the platform unchanged', () async {
      // Nothing pads, truncates or reverses it on the way out; the bytes the caller named
      // are the bytes the tag is asked about.
      host.accepted.add(MifareClassic.keyMifareApplicationDirectory);
      final classic = MifareClassic.from(fakeNfcTag(techs: [FakeTech.mifareClassic()]))!;

      expect(
        await classic.authenticateSectorWithKeyB(sectorIndex: 0, key: MifareClassic.keyMifareApplicationDirectory),
        isTrue,
      );
    });
  });
}
