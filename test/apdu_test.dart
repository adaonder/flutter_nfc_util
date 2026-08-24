import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_util/apdu.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

Iso7816ResponseApdu answer(List<int> payload, int statusWord1, int statusWord2) =>
    Iso7816ResponseApdu(payload: bytes(payload), statusWord1: statusWord1, statusWord2: statusWord2);

/// A card that answers from a script and remembers what it was asked.
class FakeCard {
  FakeCard(this._answers);

  final List<Iso7816ResponseApdu> _answers;
  final List<Uint8List> commands = [];
  int _next = 0;

  Future<Iso7816ResponseApdu> send(Uint8List command) async {
    commands.add(command);
    if (_next >= _answers.length) fail('the card was sent ${commands.length} commands but scripted only $_next');
    return _answers[_next++];
  }
}

void main() {
  group('CommandApdu encoding', () {
    test('case 1 is the four header bytes alone', () {
      final command = CommandApdu(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04, p2Parameter: 0x0C);
      expect(command.toBytes(), bytes([0x00, 0xA4, 0x04, 0x0C]));
      expect(command.isExtended, isFalse);
    });

    test('case 2S puts Le in the fifth byte', () {
      final command = CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xB0,
        p1Parameter: 0x00,
        p2Parameter: 0x00,
        expectedResponseLength: 8,
      );
      expect(command.toBytes(), bytes([0x00, 0xB0, 0x00, 0x00, 0x08]));
    });

    test('case 2S spells 256 as 0x00', () {
      final command = CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xB0,
        p1Parameter: 0x00,
        p2Parameter: 0x00,
        expectedResponseLength: 256,
      );
      expect(command.toBytes(), bytes([0x00, 0xB0, 0x00, 0x00, 0x00]));
      expect(command.isExtended, isFalse, reason: '256 is the largest length the short form carries');
    });

    test('case 3S writes Lc and then the data', () {
      final command = CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xD6,
        p1Parameter: 0x00,
        p2Parameter: 0x00,
        data: bytes([0xAA, 0xBB, 0xCC]),
      );
      expect(command.toBytes(), bytes([0x00, 0xD6, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC]));
    });

    test('case 4S writes Lc, the data, then Le', () {
      final command = CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xA4,
        p1Parameter: 0x04,
        p2Parameter: 0x00,
        data: bytes([0xA0, 0x00]),
        expectedResponseLength: 256,
      );
      expect(command.toBytes(), bytes([0x00, 0xA4, 0x04, 0x00, 0x02, 0xA0, 0x00, 0x00]));
    });

    test('case 2E writes the marker and a two-byte Le', () {
      final command = CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xB0,
        p1Parameter: 0x00,
        p2Parameter: 0x00,
        expectedResponseLength: 512,
      );
      expect(command.toBytes(), bytes([0x00, 0xB0, 0x00, 0x00, 0x00, 0x02, 0x00]));
      expect(command.isExtended, isTrue);
    });

    test('case 3E writes the marker and a two-byte Lc', () {
      final command = CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xD6,
        p1Parameter: 0x00,
        p2Parameter: 0x00,
        data: Uint8List(256),
      );
      final encoded = command.toBytes();
      expect(encoded.length, 4 + 3 + 256);
      expect(encoded.sublist(0, 7), bytes([0x00, 0xD6, 0x00, 0x00, 0x00, 0x01, 0x00]));
    });

    test('case 4E follows the data with a bare two-byte Le, with no second marker', () {
      final command = CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xA4,
        p1Parameter: 0x04,
        p2Parameter: 0x00,
        data: Uint8List(300),
        expectedResponseLength: 65536,
      );
      final encoded = command.toBytes();
      expect(encoded.length, 4 + 3 + 300 + 2);
      expect(encoded.sublist(0, 7), bytes([0x00, 0xA4, 0x04, 0x00, 0x00, 0x01, 0x2C]));
      expect(encoded.sublist(encoded.length - 2), bytes([0x00, 0x00]), reason: '65536 is spelled 0x0000');
    });

    test('keeps the short form at exactly 255 bytes of data and leaves it at 256', () {
      CommandApdu command(int length) => CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xD6,
        p1Parameter: 0x00,
        p2Parameter: 0x00,
        data: Uint8List(length),
      );

      expect(command(255).isExtended, isFalse);
      expect(command(255).toBytes()[4], 0xFF, reason: 'a one-byte Lc holds 255');
      expect(command(255).toBytes().length, 5 + 255);

      expect(command(256).isExtended, isTrue);
      expect(command(256).toBytes().length, 7 + 256);
    });

    test('keeps the short form at Le 256 and leaves it at 257', () {
      CommandApdu command(int le) => CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xB0,
        p1Parameter: 0x00,
        p2Parameter: 0x00,
        expectedResponseLength: le,
      );

      expect(command(256).toBytes().length, 5);
      expect(command(257).toBytes(), bytes([0x00, 0xB0, 0x00, 0x00, 0x00, 0x01, 0x01]));
    });

    test('a short data field with a long Le encodes the whole command extended', () {
      final command = CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xA4,
        p1Parameter: 0x04,
        p2Parameter: 0x00,
        data: bytes([0xAA]),
        expectedResponseLength: 1024,
      );
      expect(command.toBytes(), bytes([0x00, 0xA4, 0x04, 0x00, 0x00, 0x00, 0x01, 0xAA, 0x04, 0x00]));
    });

    test('forceExtended promotes a command whose lengths would fit the short form', () {
      final command = CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xA4,
        p1Parameter: 0x04,
        p2Parameter: 0x00,
        data: bytes([0xAA, 0xBB]),
        expectedResponseLength: 16,
        forceExtended: true,
      );
      expect(command.isExtended, isTrue);
      expect(command.toBytes(), bytes([0x00, 0xA4, 0x04, 0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB, 0x00, 0x10]));
    });

    test('forceExtended leaves case 1 as four bytes, having no extended spelling', () {
      final command = CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xA4,
        p1Parameter: 0x04,
        p2Parameter: 0x0C,
        forceExtended: true,
      );
      expect(command.isExtended, isFalse);
      expect(command.toBytes(), bytes([0x00, 0xA4, 0x04, 0x0C]));
    });

    test('treats empty data as no data at all', () {
      final command = CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xB0,
        p1Parameter: 0x00,
        p2Parameter: 0x00,
        data: Uint8List(0),
        expectedResponseLength: 4,
      );
      expect(command.data, isNull);
      expect(command.toBytes(), bytes([0x00, 0xB0, 0x00, 0x00, 0x04]), reason: 'no Lc of zero goes on the wire');
    });

    test('withExpectedResponseLength changes Le and nothing else', () {
      final command = CommandApdu(
        instructionClass: 0x80,
        instructionCode: 0xCA,
        p1Parameter: 0x9F,
        p2Parameter: 0x7F,
        data: bytes([0xAA]),
        expectedResponseLength: 256,
      );
      final corrected = command.withExpectedResponseLength(5);

      expect(corrected.expectedResponseLength, 5);
      expect(corrected.toBytes(), bytes([0x80, 0xCA, 0x9F, 0x7F, 0x01, 0xAA, 0x05]));
      expect(command.expectedResponseLength, 256, reason: 'the original is untouched');
    });

    test('rejects a header field that is not a byte', () {
      CommandApdu withHeader({int cla = 0, int ins = 0, int p1 = 0, int p2 = 0}) => CommandApdu(
        instructionClass: cla,
        instructionCode: ins,
        p1Parameter: p1,
        p2Parameter: p2,
      );

      expect(() => withHeader(cla: 256), throwsArgumentError);
      expect(() => withHeader(ins: -1), throwsArgumentError);
      expect(() => withHeader(p1: 0x100), throwsArgumentError);
      expect(() => withHeader(p2: -5), throwsArgumentError);
    });

    test('rejects data longer than the extended Lc field', () {
      expect(
        () => CommandApdu(
          instructionClass: 0x00,
          instructionCode: 0xD6,
          p1Parameter: 0x00,
          p2Parameter: 0x00,
          data: Uint8List(65536),
        ),
        throwsArgumentError,
      );
    });

    test('rejects an expectedResponseLength that cannot be encoded', () {
      CommandApdu withLe(int le) => CommandApdu(
        instructionClass: 0x00,
        instructionCode: 0xB0,
        p1Parameter: 0x00,
        p2Parameter: 0x00,
        expectedResponseLength: le,
      );

      expect(() => withLe(0), throwsArgumentError, reason: 'zero is null, not 256');
      expect(() => withLe(-1), throwsArgumentError);
      expect(() => withLe(65537), throwsArgumentError);
      expect(withLe(65536).toBytes().length, 7);
    });
  });

  group('StatusWord decoding', () {
    test('9000 is success', () {
      final status = StatusWord(0x90, 0x00);
      expect(status, isA<StatusWordSuccess>());
      expect(status.value, 0x9000);
    });

    test('61xx carries the number of bytes still waiting', () {
      expect((StatusWord(0x61, 0x08) as StatusWordMoreData).remainingBytes, 8);
      expect((StatusWord(0x61, 0xFF) as StatusWordMoreData).remainingBytes, 255);
    });

    test('6100 means 256 bytes, not none', () {
      expect((StatusWord(0x61, 0x00) as StatusWordMoreData).remainingBytes, 256);
    });

    test('6Cxx carries the length the card wants instead', () {
      expect((StatusWord(0x6C, 0x10) as StatusWordWrongLength).correctLength, 16);
      expect((StatusWord(0x6C, 0x00) as StatusWordWrongLength).correctLength, 256);
    });

    test('62xx warns with memory unchanged and 63xx with memory changed', () {
      final unchanged = StatusWord(0x62, 0x85) as StatusWordWarning;
      expect(unchanged.isNonVolatileMemoryChanged, isFalse);
      expect(unchanged.retryCounter, isNull);

      final changed = StatusWord(0x63, 0x00) as StatusWordWarning;
      expect(changed.isNonVolatileMemoryChanged, isTrue);
      expect(changed.retryCounter, isNull);
    });

    test('63Cx carries the attempts left, down to none', () {
      expect((StatusWord(0x63, 0xC3) as StatusWordWarning).retryCounter, 3);
      expect((StatusWord(0x63, 0xC0) as StatusWordWarning).retryCounter, 0);
      expect((StatusWord(0x63, 0xCF) as StatusWordWarning).retryCounter, 15);
    });

    test('names the errors worth branching on', () {
      StatusWordErrorReason? reasonOf(int value) => (StatusWord.fromValue(value) as StatusWordError).reason;

      expect(reasonOf(0x6982), StatusWordErrorReason.securityStatusNotSatisfied);
      expect(reasonOf(0x6A82), StatusWordErrorReason.fileNotFound);
      expect(reasonOf(0x6A86), StatusWordErrorReason.incorrectP1P2);
      expect(reasonOf(0x6D00), StatusWordErrorReason.instructionNotSupported);
      expect(reasonOf(0x6E00), StatusWordErrorReason.classNotSupported);
    });

    test('an unnamed checking error is still an error', () {
      final status = StatusWord.fromValue(0x6A83);
      expect(status, isA<StatusWordError>());
      expect((status as StatusWordError).reason, isNull);
      expect(status.value, 0x6A83, reason: 'the raw value is what says what happened');

      expect(StatusWord.fromValue(0x6700), isA<StatusWordError>());
      expect(StatusWord.fromValue(0x6400), isA<StatusWordError>());
      expect(StatusWord.fromValue(0x6F00), isA<StatusWordError>());
    });

    test('a status word outside every ISO shape stays readable', () {
      final status = StatusWord.fromValue(0x9101); // DESFire, wrapped in ISO 7816.
      expect(status, isA<StatusWordUnrecognised>());
      expect(status.value, 0x9101);
      expect(status.statusWord1, 0x91);
      expect(status.statusWord2, 0x01);
      expect(status.toString(), contains('9101'));
    });

    test('only 9000 is success, not every 90xx', () {
      expect(StatusWord.fromValue(0x9001), isA<StatusWordUnrecognised>());
    });

    test('fromValue and the two-byte constructor agree', () {
      for (final value in [0x9000, 0x6100, 0x6C10, 0x6285, 0x63C2, 0x6A82, 0x9101]) {
        expect(StatusWord.fromValue(value), StatusWord((value >> 8) & 0xFF, value & 0xFF), reason: '$value');
      }
    });

    test('equal status words compare and hash equal', () {
      expect(StatusWord(0x6A, 0x82), StatusWord(0x6A, 0x82));
      expect(StatusWord(0x6A, 0x82).hashCode, StatusWord(0x6A, 0x82).hashCode);
      expect(StatusWord(0x6A, 0x82), isNot(StatusWord(0x6A, 0x83)));
    });

    test('rejects values that are not status bytes', () {
      expect(() => StatusWord(0x100, 0x00), throwsArgumentError);
      expect(() => StatusWord(0x90, -1), throwsArgumentError);
      expect(() => StatusWord.fromValue(0x10000), throwsArgumentError);
      expect(() => StatusWord.fromValue(-1), throwsArgumentError);
    });
  });

  group('Iso7816ResponseApdu', () {
    test('splits the status bytes off a raw response', () {
      final response = Iso7816ResponseApdu.fromBytes(bytes([0x6F, 0x2A, 0x90, 0x00]));
      expect(response.payload, bytes([0x6F, 0x2A]));
      expect(response.statusWord1, 0x90);
      expect(response.statusWord2, 0x00);
      expect(response.isSuccess, isTrue);
    });

    test('a status word on its own leaves an empty payload', () {
      final response = Iso7816ResponseApdu.fromBytes(bytes([0x6A, 0x82]));
      expect(response.payload, isEmpty);
      expect(response.status, isA<StatusWordError>());
    });

    test('refuses a frame with no room for a status word', () {
      expect(() => Iso7816ResponseApdu.fromBytes(bytes([0x90])), throwsFormatException);
      expect(() => Iso7816ResponseApdu.fromBytes(Uint8List(0)), throwsFormatException);
    });

    test('does not alias the buffer it was given', () {
      final raw = bytes([0x01, 0x02, 0x90, 0x00]);
      final response = Iso7816ResponseApdu.fromBytes(raw);
      raw[0] = 0xFF;
      expect(response.payload, bytes([0x01, 0x02]));
    });

    test('status decodes what statusWord1 and statusWord2 hold', () {
      expect(answer([], 0x61, 0x05).status, isA<StatusWordMoreData>());
      expect(answer([], 0x90, 0x00).status, isA<StatusWordSuccess>());
    });
  });

  group('Iso7816Chaining', () {
    final select = CommandApdu(
      instructionClass: 0x00,
      instructionCode: 0xA4,
      p1Parameter: 0x04,
      p2Parameter: 0x00,
      data: bytes([0xA0, 0x00]),
      expectedResponseLength: 256,
    );

    test('hands back a response that starts no chain, untouched', () async {
      final card = FakeCard([
        answer([0x6F, 0x0A], 0x6A, 0x82),
      ]);
      final response = await Iso7816Chaining(card.send).sendCommand(select);

      expect(card.commands, hasLength(1));
      expect(response.payload, bytes([0x6F, 0x0A]));
      expect(response.status, isA<StatusWordError>());
    });

    test('follows 61xx with GET RESPONSE and concatenates the frames', () async {
      final card = FakeCard([
        answer([0x01, 0x02], 0x61, 0x03),
        answer([0x03, 0x04, 0x05], 0x90, 0x00),
      ]);
      final response = await Iso7816Chaining(card.send).sendCommand(select);

      expect(card.commands[0], select.toBytes());
      expect(card.commands[1], bytes([0x00, 0xC0, 0x00, 0x00, 0x03]));
      expect(response.payload, bytes([0x01, 0x02, 0x03, 0x04, 0x05]));
      expect(response.isSuccess, isTrue);
    });

    test('follows a chain of several rounds', () async {
      final card = FakeCard([
        answer([0x01], 0x61, 0x02),
        answer([0x02, 0x03], 0x61, 0x01),
        answer([0x04], 0x90, 0x00),
      ]);
      final response = await Iso7816Chaining(card.send).sendCommand(select);

      expect(card.commands, hasLength(3));
      expect(card.commands[2], bytes([0x00, 0xC0, 0x00, 0x00, 0x01]));
      expect(response.payload, bytes([0x01, 0x02, 0x03, 0x04]));
    });

    test('asks for 256 bytes when the card answers 6100', () async {
      final card = FakeCard([
        answer([], 0x61, 0x00),
        answer([0xAA], 0x90, 0x00),
      ]);
      await Iso7816Chaining(card.send).sendCommand(select);

      expect(card.commands[1], bytes([0x00, 0xC0, 0x00, 0x00, 0x00]), reason: 'Le 256 is the byte 0x00');
    });

    test('keeps the status word that ended the chain, warning or not', () async {
      final card = FakeCard([
        answer([0x01], 0x61, 0x01),
        answer([0x02], 0x62, 0x85),
      ]);
      final response = await Iso7816Chaining(card.send).sendCommand(select);

      expect(response.payload, bytes([0x01, 0x02]));
      expect(response.status, isA<StatusWordWarning>());
      expect(response.status.value, 0x6285);
    });

    test('re-encodes a CommandApdu with the Le a 6Cxx named', () async {
      final card = FakeCard([
        answer([], 0x6C, 0x05),
        answer([0x01, 0x02, 0x03, 0x04, 0x05], 0x90, 0x00),
      ]);
      final response = await Iso7816Chaining(card.send).sendCommand(select);

      expect(card.commands[1], bytes([0x00, 0xA4, 0x04, 0x00, 0x02, 0xA0, 0x00, 0x05]));
      expect(response.payload, bytes([0x01, 0x02, 0x03, 0x04, 0x05]), reason: 'the rejected frame carried nothing');
    });

    test('puts a corrected Le where each raw command case keeps it', () async {
      Future<Uint8List> retried(List<int> command) async {
        final card = FakeCard([
          answer([], 0x6C, 0x05),
          answer([0xAA], 0x90, 0x00),
        ]);
        await Iso7816Chaining(card.send).sendCommandRaw(bytes(command));
        return card.commands[1];
      }

      // Case 1: there is no Le yet, so one is appended.
      expect(await retried([0x00, 0xB0, 0x00, 0x00]), bytes([0x00, 0xB0, 0x00, 0x00, 0x05]));

      // Case 2S: the Le byte is replaced.
      expect(await retried([0x00, 0xB0, 0x00, 0x00, 0x40]), bytes([0x00, 0xB0, 0x00, 0x00, 0x05]));

      // Case 3S: appended after the data, which must not be touched.
      expect(
        await retried([0x00, 0xD6, 0x00, 0x00, 0x02, 0xAA, 0xBB]),
        bytes([0x00, 0xD6, 0x00, 0x00, 0x02, 0xAA, 0xBB, 0x05]),
      );

      // Case 4S: the trailing Le byte is replaced, not appended to.
      expect(
        await retried([0x00, 0xA4, 0x04, 0x00, 0x02, 0xA0, 0x00, 0x00]),
        bytes([0x00, 0xA4, 0x04, 0x00, 0x02, 0xA0, 0x00, 0x05]),
      );

      // Case 2E: the two Le bytes after the marker are replaced.
      expect(
        await retried([0x00, 0xB0, 0x00, 0x00, 0x00, 0x01, 0x00]),
        bytes([0x00, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x05]),
      );

      // Case 3E: an extended Le is appended after the data.
      expect(
        await retried([0x00, 0xD6, 0x00, 0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB]),
        bytes([0x00, 0xD6, 0x00, 0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB, 0x00, 0x05]),
      );

      // Case 4E: the trailing pair is replaced.
      expect(
        await retried([0x00, 0xA4, 0x04, 0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB, 0x01, 0x2C]),
        bytes([0x00, 0xA4, 0x04, 0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB, 0x00, 0x05]),
      );
    });

    test('corrects the GET RESPONSE, not the original command, when the chain is answered 6Cxx', () async {
      final card = FakeCard([
        answer([0x01], 0x61, 0x05),
        answer([], 0x6C, 0x03),
        answer([0x02, 0x03, 0x04], 0x90, 0x00),
      ]);
      final response = await Iso7816Chaining(card.send).sendCommand(select);

      expect(card.commands[1], bytes([0x00, 0xC0, 0x00, 0x00, 0x05]));
      expect(card.commands[2], bytes([0x00, 0xC0, 0x00, 0x00, 0x03]));
      expect(response.payload, bytes([0x01, 0x02, 0x03, 0x04]));
    });

    test('gives up once the card passes maxContinuations', () async {
      var sent = 0;
      Future<Iso7816ResponseApdu> endless(Uint8List command) async {
        sent++;
        return answer([0xAA], 0x61, 0x08);
      }

      await expectLater(Iso7816Chaining(endless, maxContinuations: 2).sendCommand(select), throwsStateError);
      expect(sent, 3, reason: 'the first send plus the two continuations it was allowed');
    });

    test('a card that keeps answering 6Cxx is bounded too', () async {
      var sent = 0;
      Future<Iso7816ResponseApdu> stubborn(Uint8List command) async {
        sent++;
        return answer([], 0x6C, 0x05);
      }

      await expectLater(Iso7816Chaining(stubborn, maxContinuations: 4).sendCommand(select), throwsStateError);
      expect(sent, 5);
    });

    test('refuses a raw command shorter than the header before sending anything', () {
      final card = FakeCard([]);
      expect(() => Iso7816Chaining(card.send).sendCommandRaw(bytes([0x00, 0xA4, 0x04])), throwsArgumentError);
      expect(card.commands, isEmpty);
    });

    test('refuses to guess where Le goes in a malformed raw command', () async {
      final card = FakeCard([answer([], 0x6C, 0x05)]);
      // Lc says five bytes of data follow; only one does.
      await expectLater(
        Iso7816Chaining(card.send).sendCommandRaw(bytes([0x00, 0xA4, 0x04, 0x00, 0x05, 0xAA])),
        throwsArgumentError,
      );
    });

    test('refuses a maxContinuations that allows nothing', () {
      expect(
        () => Iso7816Chaining((command) async => answer([], 0x90, 0x00), maxContinuations: 0),
        throwsArgumentError,
      );
    });
  });
}
