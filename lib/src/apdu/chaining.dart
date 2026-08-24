import 'dart:typed_data';

import 'command_apdu.dart';
import 'response_apdu.dart';
import 'status_word.dart';

/// ISO 7816-4 response chaining, wrapped around a transceive function you already have.
///
/// Neither CoreNFC nor `android.nfc.tech.IsoDep` follows a chain for you. A card that answers
/// `61xx` is saying "here is the first frame, ask again for the rest", and a caller that does
/// not know to loop keeps the first frame and the status word and never learns that the
/// answer was cut in half. `6Cxx` is the mirror image: the card rejected the Le it was sent,
/// named the length it wants, and ran nothing at all. Every serious reader ends up writing
/// the same two loops, so they are written once here.
///
/// **This is opt-in on purpose, and it is deliberately not wired into `transceive` or
/// `Iso7816.sendCommand`.** Protocols layered on top of ISO 7816 run continuations of their
/// own: Mifare DESFire signals "more frames" with its own `AF` status and expects the reader
/// to answer `AF`, and secure messaging wraps and unwraps each command and response as a
/// unit. A transport that silently issued GET RESPONSE underneath either of them would splice
/// bytes into the middle of a frame the layer above is still assembling, and corrupt an
/// exchange that was working. Chaining belongs where the caller knows the card is speaking
/// plain ISO 7816-4, which is here.
///
/// It takes a function rather than a tag, so it works against both platforms without knowing
/// either exists. iOS hands over a parsed response already:
///
/// ```dart
/// final chain = Iso7816Chaining(ios.Iso7816.from(tag)!.sendCommandRaw);
/// ```
///
/// Android hands over raw bytes with the status word still on the end, which
/// [Iso7816ResponseApdu.fromBytes] splits:
///
/// ```dart
/// final isoDep = android.IsoDep.from(tag)!;
/// final chain = Iso7816Chaining((command) async => Iso7816ResponseApdu.fromBytes(await isoDep.transceive(command)));
/// final response = await chain.sendCommand(selectApdu);
/// ```
class Iso7816Chaining {
  /// Wraps [send], the "one command in, one response out" call for a card in the field.
  ///
  /// [maxContinuations] bounds how many extra round trips one call may cost. The default
  /// carries about 8 KB at the 256 bytes a short Le can ask for, which covers ordinary file
  /// reads; raise it for a card that really does return more, and leave it low enough that a
  /// card answering `61xx` forever -- a broken applet, or a field that dropped mid-exchange
  /// -- fails instead of hanging the session until it times out.
  Iso7816Chaining(this.send, {this.maxContinuations = 32}) {
    if (maxContinuations < 1) {
      throw ArgumentError.value(maxContinuations, 'maxContinuations', 'must be at least one');
    }
  }

  /// Sends one already-encoded command and returns one response.
  final Future<Iso7816ResponseApdu> Function(Uint8List command) send;

  /// The most continuations a single call will follow before giving up.
  final int maxContinuations;

  /// Sends [command], following any chain it starts.
  ///
  /// The payload of every frame is concatenated, and the status word returned is the last
  /// one -- the one that ended the chain rather than the `61xx` that continued it.
  ///
  /// Throws a [StateError] when the card asks for more than [maxContinuations] continuations.
  Future<Iso7816ResponseApdu> sendCommand(CommandApdu command) =>
      _chain(command.toBytes(), (length) => command.withExpectedResponseLength(length).toBytes());

  /// Sends an already-encoded [command], following any chain it starts.
  ///
  /// For a caller that assembles its own APDUs. A `6Cxx` retry has to put the corrected Le
  /// back in the right place, so the command's shape is read far enough to find its length
  /// fields; one that fits none of the four ISO 7816-4 cases throws an [ArgumentError] rather
  /// than being re-sent with a byte appended to whatever it happened to end with.
  ///
  /// Throws a [StateError] when the card asks for more than [maxContinuations] continuations.
  Future<Iso7816ResponseApdu> sendCommandRaw(Uint8List command) {
    if (command.length < 4) {
      throw ArgumentError.value(command.length, 'command', 'is shorter than the four-byte APDU header');
    }
    return _chain(command, (length) => _withCorrectedLe(command, length));
  }

  Future<Iso7816ResponseApdu> _chain(Uint8List command, Uint8List Function(int correctLength) retry) async {
    var sent = command;
    var correct = retry;
    var response = await send(sent);
    final payload = BytesBuilder(copy: false);
    var continuations = 0;

    while (true) {
      switch (response.status) {
        case StatusWordMoreData(:final remainingBytes):
          payload.add(response.payload);
          sent = _getResponse(remainingBytes);
          // From here on the command in flight is the GET RESPONSE, so a `6Cxx` answer
          // corrects that and not the command the caller started with.
          correct = _getResponse;
        case StatusWordWrongLength(:final correctLength):
          // The card ran nothing and returned no data, so this frame contributes no payload.
          sent = correct(correctLength);
        default:
          payload.add(response.payload);
          return Iso7816ResponseApdu(
            payload: payload.takeBytes(),
            statusWord1: response.statusWord1,
            statusWord2: response.statusWord2,
          );
      }

      if (++continuations > maxContinuations) {
        throw StateError(
          'the card asked for more than $maxContinuations continuations; it is either returning '
          'more data than Iso7816Chaining.maxContinuations allows for, or it never stops asking',
        );
      }
      response = await send(sent);
    }
  }
}

/// `00 C0 00 00 Le` -- fetch [length] bytes the card said it was still holding.
Uint8List _getResponse(int length) => CommandApdu(
  instructionClass: 0x00,
  instructionCode: 0xC0,
  p1Parameter: 0x00,
  p2Parameter: 0x00,
  expectedResponseLength: length,
).toBytes();

/// [command] with its Le set to [length], leaving everything else exactly as it was.
///
/// Where Le sits depends on which of the four cases the command is, and the cases are told
/// apart by length alone, so this reads the encoding rather than guessing: replacing the last
/// byte of a case 3 command would corrupt its data field, and appending to a case 4 command
/// would leave two Le fields on the wire.
Uint8List _withCorrectedLe(Uint8List command, int length) {
  final short = [length == 256 ? 0x00 : length];
  final extended = [(length >> 8) & 0xFF, length & 0xFF];

  // Case 1 has no Le to replace and case 2S has nothing but one, so both keep the header only.
  if (command.length <= 5) return _replaceTail(command, 4, short);

  if (command[4] != 0x00) {
    final lc = command[4];
    if (command.length == 5 + lc) return _replaceTail(command, command.length, short); // Case 3S.
    if (command.length == 6 + lc) return _replaceTail(command, command.length - 1, short); // Case 4S.
  } else if (command.length >= 7) {
    // A leading zero where Lc would be is the extended-form marker. Case 2E is checked first
    // because its Le bytes sit exactly where an extended Lc of zero would read from.
    if (command.length == 7) return _replaceTail(command, 5, extended); // Case 2E.
    final lc = (command[5] << 8) | command[6];
    if (command.length == 7 + lc) return _replaceTail(command, command.length, extended); // Case 3E.
    if (command.length == 9 + lc) return _replaceTail(command, command.length - 2, extended); // Case 4E.
  }

  throw ArgumentError.value(command.length, 'command', 'is not one of the four ISO 7816-4 command cases');
}

Uint8List _replaceTail(Uint8List command, int keep, List<int> tail) =>
    Uint8List.fromList([...command.sublist(0, keep), ...tail]);
