import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_util/android.dart';
import 'package:nfc_util/ios.dart';
import 'package:nfc_util/ndef.dart';
import 'package:nfc_util/nfc_util.dart';
import 'package:nfc_util/src/pigeon.g.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

/// A tag carrying only the technologies named, the way the platform delivers one.
NfcTag tagWith({
  Uint8List? id,
  List<String>? techList,
  NfcAPigeon? nfcA,
  NfcBPigeon? nfcB,
  IsoDepPigeon? isoDep,
  MifareClassicPigeon? mifareClassic,
  MifareUltralightPigeon? mifareUltralight,
  NfcBarcodePigeon? nfcBarcode,
  NdefAndroidPigeon? ndefAndroid,
  bool? ndefFormatable,
  NdefIosPigeon? ndefIos,
  FeliCaPigeon? felica,
  Iso7816Pigeon? iso7816,
  MiFarePigeon? mifare,
}) => NfcTag(
  TagPigeon(
    handle: 'handle-1',
    id: id,
    techList: techList,
    nfcA: nfcA,
    nfcB: nfcB,
    isoDep: isoDep,
    mifareClassic: mifareClassic,
    mifareUltralight: mifareUltralight,
    nfcBarcode: nfcBarcode,
    ndefAndroid: ndefAndroid,
    ndefFormatable: ndefFormatable,
    ndefIos: ndefIos,
    felica: felica,
    iso7816: iso7816,
    mifare: mifare,
  ),
);

void main() {
  group('NfcTag', () {
    test('hoists the identifier and technology list', () {
      final tag = tagWith(id: bytes([0x04, 0xA2, 0x1B]), techList: ['NfcA', 'MifareUltralight']);
      expect(tag.id, bytes([0x04, 0xA2, 0x1B]));
      expect(tag.techList, ['NfcA', 'MifareUltralight']);
      expect(tag.handle, 'handle-1');
    });

    test('reports an empty technology list rather than null on iOS', () {
      expect(tagWith().techList, isEmpty);
    });
  });

  group('from() returns null for the wrong technology', () {
    final empty = tagWith();

    test('every Android class', () {
      expect(NfcA.from(empty), isNull);
      expect(NfcB.from(empty), isNull);
      expect(NfcF.from(empty), isNull);
      expect(NfcV.from(empty), isNull);
      expect(IsoDep.from(empty), isNull);
      expect(MifareClassic.from(empty), isNull);
      expect(MifareUltralight.from(empty), isNull);
      expect(NfcBarcode.from(empty), isNull);
      expect(NdefAndroid.from(empty), isNull);
      expect(NdefFormatable.from(empty), isNull);
    });

    test('every iOS class', () {
      expect(FeliCa.from(empty), isNull);
      expect(Iso7816.from(empty), isNull);
      expect(Iso15693.from(empty), isNull);
      expect(MiFare.from(empty), isNull);
      expect(NdefIos.from(empty), isNull);
    });

    test('and Ndef', () {
      expect(Ndef.from(empty), isNull);
    });
  });

  group('Android technologies', () {
    test('a technology the platform could not describe is simply absent', () {
      // A throw building one technology used to take down the whole tag, so an app that only
      // wanted the UID got nothing. Each is independent now.
      final tag = tagWith(
        id: bytes([0x04, 0x11]),
        techList: ['NfcB', 'IsoDep'],
        nfcB: null,
        isoDep: IsoDepPigeon(
          hiLayerResponse: null,
          historicalBytes: null,
          isExtendedLengthApduSupported: false,
          maxTransceiveLength: 261,
          timeout: 300,
        ),
      );

      expect(NfcB.from(tag), isNull);
      expect(IsoDep.from(tag), isNotNull, reason: 'the rest of the tag still has to arrive');
      expect(tag.id, bytes([0x04, 0x11]));
    });

    test('poll bytes the stack never reported read as null, not empty', () {
      // AOSP fills these only once the poll bytes are long enough; a B-prime target answers
      // no SENSB_RES at all. Empty would say "the tag answered nothing", which is a lie.
      final nfcB = NfcB.from(
        tagWith(nfcB: NfcBPigeon(applicationData: null, protocolInfo: null, maxTransceiveLength: 253)),
      )!;
      expect(nfcB.applicationData, isNull);
      expect(nfcB.protocolInfo, isNull);

      final nfcA = NfcA.from(
        tagWith(nfcA: NfcAPigeon(atqa: null, sak: 0x20, maxTransceiveLength: 253, timeout: 618)),
      )!;
      expect(nfcA.atqa, isNull);
      expect(nfcA.sak, 0x20, reason: 'the values that are present still arrive');
    });

    test('NfcA carries its discovery-time values', () {
      final nfcA = NfcA.from(
        tagWith(nfcA: NfcAPigeon(atqa: bytes([0x44, 0x00]), sak: 0x00, maxTransceiveLength: 253, timeout: 618)),
      )!;
      expect(nfcA.atqa, bytes([0x44, 0x00]));
      expect(nfcA.sak, 0x00);
      expect(nfcA.maxTransceiveLength, 253);
      expect(nfcA.timeout, const Duration(milliseconds: 618));
    });

    test('MifareClassic maps the type enum', () {
      for (final (wire, expected) in [
        (MifareClassicTypePigeon.classic, MifareClassicType.classic),
        (MifareClassicTypePigeon.plus, MifareClassicType.plus),
        (MifareClassicTypePigeon.pro, MifareClassicType.pro),
        (MifareClassicTypePigeon.unknown, MifareClassicType.unknown),
      ]) {
        final classic = MifareClassic.from(
          tagWith(
            mifareClassic: MifareClassicPigeon(
              type: wire,
              blockCount: 256,
              sectorCount: 40,
              size: 4096,
              maxTransceiveLength: 253,
              timeout: 618,
            ),
          ),
        )!;
        expect(classic.type, expected);
      }
    });

    test('MifareUltralight maps the type enum', () {
      final ultralight = MifareUltralight.from(
        tagWith(
          mifareUltralight: MifareUltralightPigeon(
            type: MifareUltralightTypePigeon.ultralightC,
            maxTransceiveLength: 253,
            timeout: 618,
          ),
        ),
      )!;
      expect(ultralight.type, MifareUltralightType.ultralightC);
    });

    test('NfcBarcode tolerates a tag that reports no payload', () {
      final barcode = NfcBarcode.from(
        tagWith(nfcBarcode: NfcBarcodePigeon(type: NfcBarcodeTypePigeon.kovio, barcode: null)),
      )!;
      expect(barcode.type, NfcBarcodeType.kovio);
      expect(barcode.barcode, isNull);
    });

    test('IsoDep keeps both the A and B response fields nullable', () {
      final isoDep = IsoDep.from(
        tagWith(
          isoDep: IsoDepPigeon(
            hiLayerResponse: null,
            historicalBytes: bytes([0x80, 0x73]),
            isExtendedLengthApduSupported: true,
            maxTransceiveLength: 261,
            timeout: 300,
          ),
        ),
      )!;
      expect(isoDep.hiLayerResponse, isNull);
      expect(isoDep.historicalBytes, bytes([0x80, 0x73]));
      expect(isoDep.isExtendedLengthApduSupported, isTrue);
    });

    test('NdefFormatable resolves from the flag alone', () {
      expect(NdefFormatable.from(tagWith(ndefFormatable: true)), isNotNull);
      expect(NdefFormatable.from(tagWith(ndefFormatable: false)), isNull);
    });

    test('NdefAndroid exposes what only Android knows', () {
      final ndef = NdefAndroid.from(
        tagWith(
          ndefAndroid: NdefAndroidPigeon(
            type: 'org.nfcforum.ndef.type2',
            maxSize: 137,
            isWritable: true,
            canMakeReadOnly: false,
          ),
        ),
      )!;
      expect(ndef.type, 'org.nfcforum.ndef.type2');
      expect(ndef.canMakeReadOnly, isFalse);
    });
  });

  group('iOS technologies', () {
    test('MiFare maps the family enum', () {
      final mifare = MiFare.from(
        tagWith(mifare: MiFarePigeon(family: MiFareFamilyPigeon.desfire, historicalBytes: null)),
      )!;
      expect(mifare.family, MiFareFamily.desfire);
    });

    test('Iso7816 carries the application CoreNFC selected', () {
      final card = Iso7816.from(
        tagWith(
          iso7816: Iso7816Pigeon(
            initialSelectedAID: 'A0000002471001',
            historicalBytes: null,
            applicationData: null,
            proprietaryApplicationDataCoding: false,
          ),
        ),
      )!;
      expect(card.initialSelectedAID, 'A0000002471001');
    });

    test('NdefIos maps the status enum', () {
      final ndef = NdefIos.from(
        tagWith(ndefIos: NdefIosPigeon(status: NdefStatusPigeon.readOnly, capacity: 492)),
      )!;
      expect(ndef.status, NdefStatus.readOnly);
      expect(ndef.capacity, 492);
    });
  });

  group('Ndef resolves on either platform', () {
    test('from the Android shape', () {
      final ndef = Ndef.from(
        tagWith(
          ndefAndroid: NdefAndroidPigeon(
            type: 'org.nfcforum.ndef.type2',
            maxSize: 137,
            isWritable: true,
            canMakeReadOnly: true,
            cachedMessage: NdefMessagePigeon(
              records: [
                NdefRecordPigeon(
                  typeNameFormat: TypeNameFormatPigeon.wellKnown,
                  type: bytes([0x54]),
                  identifier: Uint8List(0),
                  payload: bytes([0x02, 0x65, 0x6E, 0x68, 0x69]),
                ),
              ],
            ),
          ),
        ),
      )!;

      expect(ndef.isWritable, isTrue);
      expect(ndef.maxSize, 137);
      expect(TextRecord.from(ndef.cachedMessage!.records.single)!.text, 'hi');
    });

    test('from the iOS shape, deriving writability from the status', () {
      expect(
        Ndef.from(tagWith(ndefIos: NdefIosPigeon(status: NdefStatusPigeon.readWrite, capacity: 492)))!.isWritable,
        isTrue,
      );
      expect(
        Ndef.from(tagWith(ndefIos: NdefIosPigeon(status: NdefStatusPigeon.readOnly, capacity: 492)))!.isWritable,
        isFalse,
      );
      expect(
        Ndef.from(tagWith(ndefIos: NdefIosPigeon(status: NdefStatusPigeon.notSupported, capacity: 0)))!.isWritable,
        isFalse,
      );
    });

    test('maps iOS capacity onto maxSize', () {
      expect(
        Ndef.from(tagWith(ndefIos: NdefIosPigeon(status: NdefStatusPigeon.readWrite, capacity: 492)))!.maxSize,
        492,
      );
    });
  });

  group('Iso7816ResponseApdu', () {
    test('combines the two status bytes the way card specifications write them', () {
      final success = Iso7816ResponseApdu(payload: Uint8List(0), statusWord1: 0x90, statusWord2: 0x00);
      expect(success.statusWord, 0x9000);
      expect(success.isSuccess, isTrue);
    });

    test('does not call a warning or a "more data" answer success', () {
      // 61xx means the card has more data waiting; 6A82 means "file not found".
      expect(Iso7816ResponseApdu(payload: Uint8List(0), statusWord1: 0x61, statusWord2: 0x10).isSuccess, isFalse);
      expect(Iso7816ResponseApdu(payload: Uint8List(0), statusWord1: 0x6A, statusWord2: 0x82).statusWord, 0x6A82);
    });
  });

  group('FeliCaStatusFlag', () {
    test('treats a zero first flag as success', () {
      expect(const FeliCaStatusFlag(statusFlag1: 0x00, statusFlag2: 0x00).isSuccess, isTrue);
      expect(const FeliCaStatusFlag(statusFlag1: 0x01, statusFlag2: 0xA4).isSuccess, isFalse);
    });
  });
}
