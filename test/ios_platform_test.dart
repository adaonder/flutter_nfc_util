import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_util/ios.dart';
import 'package:nfc_util/ndef.dart';
import 'package:nfc_util/nfc_util.dart';
import 'package:nfc_util/src/pigeon.g.dart';
import 'package:nfc_util/testing.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

/// A stand-in iOS host that records which tag a per-tag question was asked about.
///
/// `tagIsAvailable` is the one call in the iOS surface whose answer is only meaningful next
/// to the handle it was asked with, so the handle is what this keeps.
class _FakeIosHost extends FakeNfcIosHostApi {
  bool available = true;
  final asked = <String>[];

  @override
  Future<bool> tagIsAvailable(String handle) async {
    asked.add(handle);
    return available;
  }
}

/// A stand-in cross-platform host that records the NDEF calls a tag received.
class _FakeHost extends FakeNfcHostApi {
  NdefMessagePigeon? onTag;

  final reads = <String>[];
  final writes = <(String, NdefMessagePigeon)>[];
  final locks = <String>[];

  @override
  Future<NdefMessagePigeon?> ndefRead(String handle) async {
    reads.add(handle);
    return onTag;
  }

  @override
  Future<void> ndefWrite(String handle, NdefMessagePigeon message) async => writes.add((handle, message));

  @override
  Future<void> ndefWriteLock(String handle) async => locks.add(handle);
}

/// One text record, as the platform hands a message over.
NdefMessagePigeon get _helloWire => NdefMessagePigeon(
  records: [
    NdefRecordPigeon(
      typeNameFormat: TypeNameFormatPigeon.wellKnown,
      type: bytes([0x54]),
      identifier: Uint8List(0),
      payload: bytes([0x02, 0x65, 0x6E, 0x68, 0x69]),
    ),
  ],
);

void main() {
  late _FakeIosHost ios;
  late _FakeHost nfc;
  late void Function() restore;

  setUp(() {
    ios = _FakeIosHost();
    nfc = _FakeHost();
    restore = debugReplaceApis(nfc: nfc, ios: ios);
  });

  tearDown(() => restore());

  group('tagIsAvailable', () {
    test('asks about the tag it was handed, not about the field', () async {
      // `NFCTag.isAvailable` is a question about one tag. A session that has let go of it
      // answers false while a card is still sitting on the phone, so the handle is the whole
      // point of the call.
      final tag = fakeNfcTag(handle: 'tag-7', techs: [FakeTech.iso7816()]);

      expect(await NfcUtilIos.instance.tagIsAvailable(tag), isTrue);
      expect(ios.asked, ['tag-7']);
    });

    test('a tag that has drifted out of range says so rather than throwing', () async {
      // The reason to call it before a long exchange is to be told no cheaply; a throw here
      // would put the check behind the same try/catch as the write it was meant to precede.
      ios.available = false;

      expect(await NfcUtilIos.instance.tagIsAvailable(fakeNfcTag(techs: [FakeTech.mifare()])), isFalse);
    });
  });

  group('a tag whose NDEF probe was skipped', () {
    // What `skipNdefCheck: true` delivers on iOS: a tag with its CoreNFC protocol and no
    // NDEF description, because the queryNDEFStatus and readNDEF round trips never ran.
    NfcTag unprobed() => fakeNfcTag(handle: 'unprobed', techs: [FakeTech.mifare()]);

    test('does not resolve through Ndef.from', () async {
      // The gap this escape hatch exists for. Nothing asked the tag, so there is nothing to
      // build an Ndef out of -- even though reading and writing address it by handle and
      // would work perfectly well.
      expect(Ndef.from(unprobed()), isNull);
    });

    test('reads through Ndef.uncheckedIos, addressing the same tag', () async {
      nfc.onTag = _helloWire;

      final message = await Ndef.uncheckedIos(unprobed()).read();

      expect(nfc.reads, ['unprobed']);
      expect(TextRecord.from(message!.records.single)!.text, 'hi');
    });

    test('writes and locks through it too', () async {
      final ndef = Ndef.uncheckedIos(unprobed());

      await ndef.write(NdefMessage([TextRecord.create('hi')]));
      await ndef.writeLock();

      expect(nfc.writes.single.$1, 'unprobed');
      expect(nfc.writes.single.$2.records, hasLength(1));
      expect(nfc.locks, ['unprobed']);
    });

    test('reports nothing about a tag nobody asked', () async {
      // False, zero and null are not answers here, and the documentation says so: the probe
      // that fills them in is exactly what was skipped. A caller that needs the real status
      // asks ndefQueryStatus for it.
      final ndef = Ndef.uncheckedIos(unprobed());

      expect(ndef.isWritable, isFalse);
      expect(ndef.maxSize, 0);
      expect(ndef.cachedMessage, isNull);
    });
  });
}
