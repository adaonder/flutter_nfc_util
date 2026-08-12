import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_util/ndef.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('NdefMessage codec', () {
    test('round trips a single short record', () {
      final message = NdefMessage([TextRecord.create('hello')]);
      expect(NdefMessage.fromBytes(message.toBytes()), message);
    });

    test('round trips several records', () {
      final message = NdefMessage([
        TextRecord.create('bir', languageCode: 'tr'),
        UriRecord.create(Uri.parse('https://example.com')),
        MimeRecord.create('application/json', bytes(utf8.encode('{"a":1}'))),
        ExternalRecord.create('example.com', 'widget', bytes([1, 2, 3])),
      ]);
      expect(NdefMessage.fromBytes(message.toBytes()), message);
    });

    test('sets MB on the first record and ME on the last', () {
      final encoded = NdefMessage([TextRecord.create('a'), TextRecord.create('b')]).toBytes();

      expect(encoded[0] & 0x80, 0x80, reason: 'first record carries MB');
      expect(encoded[0] & 0x40, 0x00, reason: 'first record of two does not carry ME');

      // Walk past the first record: header, type length, payload length, type, payload.
      final firstPayloadLength = encoded[2];
      final secondHeader = encoded[3 + encoded[1] + firstPayloadLength];
      expect(secondHeader & 0x80, 0x00, reason: 'second record does not carry MB');
      expect(secondHeader & 0x40, 0x40, reason: 'last record carries ME');
    });

    test('uses the four-byte length for a payload of 256 bytes or more', () {
      final big = Uint8List(300);
      final encoded = NdefMessage([MimeRecord.create('application/octet-stream', big)]).toBytes();

      expect(encoded[0] & 0x10, 0x00, reason: 'SR is clear for a long record');
      final decoded = NdefMessage.fromBytes(encoded);
      expect(decoded.records.single.payload.length, 300);
    });

    test('keeps the short-record form at exactly 255 bytes', () {
      final encoded = NdefMessage([MimeRecord.create('text/plain', Uint8List(255))]).toBytes();
      expect(encoded[0] & 0x10, 0x10, reason: 'SR is set at 255 bytes');
      expect(NdefMessage.fromBytes(encoded).records.single.payload.length, 255);
    });

    test('round trips a record identifier', () {
      final record = NdefRecord(
        typeNameFormat: NdefTypeNameFormat.external,
        type: bytes(utf8.encode('example.com:x')),
        identifier: bytes([0xAA, 0xBB]),
        payload: bytes([1]),
      );
      final decoded = NdefMessage.fromBytes(NdefMessage([record]).toBytes());
      expect(decoded.records.single.identifier, bytes([0xAA, 0xBB]));
    });

    test('writes the ID length byte for an empty record', () {
      final record = NdefRecord(
        typeNameFormat: NdefTypeNameFormat.empty,
        type: Uint8List(0),
        identifier: Uint8List(0),
        payload: Uint8List(0),
      );
      final encoded = NdefMessage([record]).toBytes();
      expect(encoded[0] & 0x08, 0x08, reason: 'IL is set even with no identifier');
      expect(NdefMessage.fromBytes(encoded).records.single, record);
    });

    test('byteLength matches the encoded size', () {
      for (final message in [
        NdefMessage([TextRecord.create('kısa')]),
        NdefMessage([MimeRecord.create('image/png', Uint8List(1000))]),
        NdefMessage([TextRecord.create('a'), UriRecord.create(Uri.parse('tel:+905551112233'))]),
        NdefMessage([
          NdefRecord(
            typeNameFormat: NdefTypeNameFormat.empty,
            type: Uint8List(0),
            identifier: Uint8List(0),
            payload: Uint8List(0),
          ),
        ]),
      ]) {
        expect(message.byteLength, message.toBytes().length, reason: '$message');
      }
    });

    test('decodes an empty buffer as an empty message', () {
      expect(NdefMessage.fromBytes(Uint8List(0)).records, isEmpty);
    });

    test('reassembles a chunked record', () {
      // Three chunks spelling "abcdef": first carries the type, the rest are UNCHANGED.
      final encoded = bytes([
        0xB1, 0x01, 0x02, 0x54, 0x61, 0x62, // MB|CF|SR, type 'T', "ab"
        0x36, 0x00, 0x02, 0x63, 0x64, //       CF|SR|UNCHANGED,     "cd"
        0x56, 0x00, 0x02, 0x65, 0x66, //       ME|SR|UNCHANGED,     "ef"
      ]);

      final decoded = NdefMessage.fromBytes(encoded);
      expect(decoded.records, hasLength(1));
      expect(decoded.records.single.typeNameFormat, NdefTypeNameFormat.wellKnown);
      expect(decoded.records.single.type, bytes([0x54]));
      expect(decoded.records.single.payload, bytes(utf8.encode('abcdef')));
    });

    test('rejects a standalone UNCHANGED record', () {
      // UNCHANGED only means "the previous record's payload continues here". Standing alone
      // it is a record this library's own writer refuses to encode, so accepting it would
      // hand the caller something it could never write back.
      expect(() => NdefMessage.fromBytes(bytes([0xD6, 0x00, 0x01, 0x61])), throwsFormatException);
    });

    test('rejects the reserved type name format', () {
      // 0x07 is reserved by the specification and has no enum value; indexing on it blind
      // would raise a RangeError out of what is a well-defined parse failure.
      expect(() => NdefMessage.fromBytes(bytes([0xD7, 0x00, 0x01, 0x61])), throwsFormatException);
    });

    test('rejects malformed input', () {
      // Truncated payload.
      expect(() => NdefMessage.fromBytes(bytes([0xD1, 0x01, 0x05, 0x54])), throwsFormatException);
      // No MB flag on the first record.
      expect(() => NdefMessage.fromBytes(bytes([0x51, 0x01, 0x01, 0x54, 0x61])), throwsFormatException);
      // No ME flag anywhere.
      expect(() => NdefMessage.fromBytes(bytes([0x91, 0x01, 0x01, 0x54, 0x61])), throwsFormatException);
      // Ends inside a chunk.
      expect(() => NdefMessage.fromBytes(bytes([0xB1, 0x01, 0x01, 0x54, 0x61])), throwsFormatException);
      // A second record after ME.
      expect(
        () => NdefMessage.fromBytes(bytes([0xD1, 0x01, 0x01, 0x54, 0x61, 0xD1, 0x01, 0x01, 0x54, 0x62])),
        throwsFormatException,
      );
    });

    test('decoded records do not alias the source buffer', () {
      final source = NdefMessage([TextRecord.create('x')]).toBytes();
      final decoded = NdefMessage.fromBytes(source);
      final payloadBefore = Uint8List.fromList(decoded.records.single.payload);
      source.fillRange(0, source.length, 0);
      expect(decoded.records.single.payload, payloadBefore);
    });
  });

  group('TextRecord', () {
    test('round trips text and language code', () {
      final parsed = TextRecord.from(TextRecord.create('merhaba dünya', languageCode: 'tr'))!;
      expect(parsed.text, 'merhaba dünya');
      expect(parsed.languageCode, 'tr');
      expect(parsed.isUtf16, isFalse);
    });

    test('defaults the language code to en', () {
      expect(TextRecord.from(TextRecord.create('hi'))!.languageCode, 'en');
    });

    test('decodes a UTF-16 payload', () {
      // Status byte 0x82: UTF-16, two-byte language code. Then 'en', then BE "hi".
      final record = NdefRecord.fromParts(
        typeNameFormat: NdefTypeNameFormat.wellKnown,
        type: bytes([0x54]),
        identifier: Uint8List(0),
        payload: bytes([0x82, 0x65, 0x6E, 0x00, 0x68, 0x00, 0x69]),
      );
      final parsed = TextRecord.from(record)!;
      expect(parsed.text, 'hi');
      expect(parsed.isUtf16, isTrue);
    });

    test('rejects a language code longer than six bits can express', () {
      expect(() => TextRecord.create('x', languageCode: 'a' * 64), throwsArgumentError);
    });

    test('returns null for records that are not text', () {
      expect(TextRecord.from(UriRecord.create(Uri.parse('https://a.example'))), isNull);
      expect(TextRecord.from(MimeRecord.create('text/plain', bytes([1]))), isNull);
      // Truncated: claims a 9-byte language code but carries none.
      expect(
        TextRecord.from(
          NdefRecord.fromParts(
            typeNameFormat: NdefTypeNameFormat.wellKnown,
            type: bytes([0x54]),
            identifier: Uint8List(0),
            payload: bytes([0x09]),
          ),
        ),
        isNull,
      );
    });
  });

  group('UriRecord', () {
    test('round trips common schemes', () {
      for (final uri in [
        'https://www.example.com/a/b',
        'http://example.com',
        'tel:+905551112233',
        'mailto:a@example.com',
        'file:///tmp/x',
      ]) {
        expect(UriRecord.from(UriRecord.create(Uri.parse(uri)))!.uri.toString(), uri, reason: uri);
      }
    });

    test('abbreviates the longest matching prefix, not the first', () {
      // 'urn:' is index 19 and matches; 'urn:epc:id:' is index 30 and matches better.
      final encoded = UriRecord.create(Uri.parse('urn:epc:id:sgtin:1.2.3'));
      expect(encoded.payload[0], 30);
      expect(UriRecord.from(encoded)!.uri.toString(), 'urn:epc:id:sgtin:1.2.3');
    });

    test('falls back to the empty prefix for an unlisted scheme', () {
      final encoded = UriRecord.create(Uri.parse('myapp://open/thing'));
      expect(encoded.payload[0], 0);
      expect(UriRecord.from(encoded)!.uri.toString(), 'myapp://open/thing');
    });

    test('reads an absolute URI record', () {
      final record = NdefRecord(
        typeNameFormat: NdefTypeNameFormat.absoluteUri,
        type: bytes(utf8.encode('https://example.com/abs')),
        identifier: Uint8List(0),
        payload: Uint8List(0),
      );
      expect(UriRecord.from(record)!.uri.toString(), 'https://example.com/abs');
    });

    test('returns null for an unknown prefix index', () {
      final record = NdefRecord.fromParts(
        typeNameFormat: NdefTypeNameFormat.wellKnown,
        type: bytes([0x55]),
        identifier: Uint8List(0),
        payload: bytes([0xFE, 0x61]),
      );
      expect(UriRecord.from(record), isNull);
    });

    test('rejects an empty URI', () {
      expect(() => UriRecord.create(Uri.parse('')), throwsArgumentError);
    });
  });

  group('SmartPosterRecord', () {
    test('round trips a URI, title and action', () {
      final record = SmartPosterRecord.create(
        uri: Uri.parse('https://example.com/promo'),
        title: 'Kampanya',
        titleLanguageCode: 'tr',
        action: SmartPosterAction.execute,
      );

      final parsed = SmartPosterRecord.from(record)!;
      expect(parsed.uri.toString(), 'https://example.com/promo');
      expect(parsed.title(languageCode: 'tr'), 'Kampanya');
      expect(parsed.action, SmartPosterAction.execute);
      expect(parsed.icon, isNull);
    });

    test('round trips an icon', () {
      final iconData = bytes([0x89, 0x50, 0x4E, 0x47]);
      final parsed = SmartPosterRecord.from(
        SmartPosterRecord.create(
          uri: Uri.parse('https://example.com'),
          iconMimeType: 'image/png',
          iconData: iconData,
        ),
      )!;
      expect(parsed.icon?.mimeType, 'image/png');
      expect(parsed.icon?.data, iconData);
    });

    test('title falls back to any language when the requested one is absent', () {
      final parsed = SmartPosterRecord.from(
        SmartPosterRecord.create(uri: Uri.parse('https://a.example'), title: 'Başlık', titleLanguageCode: 'tr'),
      )!;
      expect(parsed.title(languageCode: 'de'), 'Başlık');
    });

    test('survives being nested inside a larger message', () {
      final message = NdefMessage([
        TextRecord.create('before'),
        SmartPosterRecord.create(uri: Uri.parse('https://example.com'), title: 'T'),
        TextRecord.create('after'),
      ]);

      final decoded = NdefMessage.fromBytes(message.toBytes());
      expect(decoded.records, hasLength(3));
      expect(SmartPosterRecord.from(decoded.records[1])!.title(), 'T');
    });

    test('requires the icon type and data together', () {
      expect(
        () => SmartPosterRecord.create(uri: Uri.parse('https://a.example'), iconMimeType: 'image/png'),
        throwsArgumentError,
      );
    });

    test('returns null when the poster carries no URI', () {
      final record = NdefRecord(
        typeNameFormat: NdefTypeNameFormat.wellKnown,
        type: bytes([0x53, 0x70]),
        identifier: Uint8List(0),
        payload: NdefMessage([TextRecord.create('title only')]).toBytes(),
      );
      expect(SmartPosterRecord.from(record), isNull);
    });

    test('returns null when the payload is not an NDEF message', () {
      final record = NdefRecord.fromParts(
        typeNameFormat: NdefTypeNameFormat.wellKnown,
        type: bytes([0x53, 0x70]),
        identifier: Uint8List(0),
        payload: bytes([0xFF, 0xFF, 0xFF]),
      );
      expect(SmartPosterRecord.from(record), isNull);
    });
  });

  group('MimeRecord', () {
    test('round trips type and data', () {
      final parsed = MimeRecord.from(MimeRecord.create('application/json', bytes([0x7B, 0x7D])))!;
      expect(parsed.mimeType, 'application/json');
      expect(parsed.data, bytes([0x7B, 0x7D]));
    });

    test('drops parameters and lowercases the type', () {
      expect(MimeRecord.from(MimeRecord.create('TEXT/Plain; charset=utf-8', bytes([1])))!.mimeType, 'text/plain');
    });

    test('rejects a type without both halves', () {
      expect(() => MimeRecord.create('text', bytes([1])), throwsArgumentError);
      expect(() => MimeRecord.create('/plain', bytes([1])), throwsArgumentError);
      expect(() => MimeRecord.create('text/', bytes([1])), throwsArgumentError);
      expect(() => MimeRecord.create('', bytes([1])), throwsArgumentError);
    });
  });

  group('ExternalRecord', () {
    test('round trips domain, type and data', () {
      final parsed = ExternalRecord.from(ExternalRecord.create('Example.COM', 'Widget', bytes([9])))!;
      expect(parsed.domain, 'example.com');
      expect(parsed.type, 'widget');
      expect(parsed.data, bytes([9]));
    });

    test('returns null without a domain separator', () {
      final record = NdefRecord.fromParts(
        typeNameFormat: NdefTypeNameFormat.external,
        type: bytes(utf8.encode('nocolon')),
        identifier: Uint8List(0),
        payload: Uint8List(0),
      );
      expect(ExternalRecord.from(record), isNull);
    });

    test('rejects empty parts', () {
      expect(() => ExternalRecord.create('', 'x', bytes([1])), throwsArgumentError);
      expect(() => ExternalRecord.create('example.com', '', bytes([1])), throwsArgumentError);
    });
  });

  group('NdefRecord validation', () {
    test('rejects data in an empty record', () {
      expect(
        () => NdefRecord(
          typeNameFormat: NdefTypeNameFormat.empty,
          type: bytes([1]),
          identifier: Uint8List(0),
          payload: Uint8List(0),
        ),
        throwsArgumentError,
      );
    });

    test('rejects a type on an unknown record', () {
      expect(
        () => NdefRecord(
          typeNameFormat: NdefTypeNameFormat.unknown,
          type: bytes([1]),
          identifier: Uint8List(0),
          payload: Uint8List(0),
        ),
        throwsArgumentError,
      );
    });

    test('rejects UNCHANGED as a logical record', () {
      expect(
        () => NdefRecord(
          typeNameFormat: NdefTypeNameFormat.unchanged,
          type: Uint8List(0),
          identifier: Uint8List(0),
          payload: Uint8List(0),
        ),
        throwsArgumentError,
      );
    });

    test('fromParts skips validation so decoding cannot fail on a legal tag', () {
      expect(
        NdefRecord.fromParts(
          typeNameFormat: NdefTypeNameFormat.unchanged,
          type: Uint8List(0),
          identifier: Uint8List(0),
          payload: bytes([1]),
        ).typeNameFormat,
        NdefTypeNameFormat.unchanged,
      );
    });

    test('records compare by value', () {
      expect(TextRecord.create('a'), TextRecord.create('a'));
      expect(TextRecord.create('a').hashCode, TextRecord.create('a').hashCode);
      expect(TextRecord.create('a'), isNot(TextRecord.create('b')));
    });
  });
}
