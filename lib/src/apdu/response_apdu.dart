import 'dart:typed_data';

import 'status_word.dart';

// The ISO 7816-4 response half. It lives here rather than beside the iOS tag classes
// because both platforms speak this protocol: iOS through `Iso7816`, Android through
// `IsoDep`. Until 3.3.0 only the iOS side had a type for it and the Android side handed
// back bare bytes, so the same card answered in two different shapes depending on the
// phone.
//
// `package:nfc_util/ios.dart` still exports it, so nothing that used it has to change.

/// The two status bytes an ISO 7816 card answers with, plus its payload.
class Iso7816ResponseApdu {
  const Iso7816ResponseApdu({required this.payload, required this.statusWord1, required this.statusWord2});

  /// Splits a response that still has its status bytes on the end.
  ///
  /// That is what a raw transceive hands back -- `IsoDep.transceive` on Android, and any
  /// other path that moves bytes rather than parsed frames. CoreNFC has already split them,
  /// so the iOS side never needs this.
  ///
  /// Throws a [FormatException] on fewer than two bytes: a response that short is not a
  /// truncated payload, it is a frame with no status word at all, and reading a status out of
  /// it would invent one.
  factory Iso7816ResponseApdu.fromBytes(Uint8List bytes) {
    if (bytes.length < 2) throw const FormatException('response APDU is shorter than its two status bytes');
    return Iso7816ResponseApdu(
      // Copy: sublistView aliases the caller's buffer, which nothing here owns.
      payload: Uint8List.fromList(Uint8List.sublistView(bytes, 0, bytes.length - 2)),
      statusWord1: bytes[bytes.length - 2],
      statusWord2: bytes[bytes.length - 1],
    );
  }

  /// The response body, without the status bytes.
  final Uint8List payload;

  /// SW1.
  final int statusWord1;

  /// SW2.
  final int statusWord2;

  /// SW1 and SW2 as one 16-bit value, which is how card specifications write them.
  int get statusWord => (statusWord1 << 8) | statusWord2;

  /// The status bytes decoded into something to branch on.
  ///
  /// The [StatusWord] hierarchy lives in `package:nfc_util/apdu.dart`, which is where the
  /// rest of the ISO 7816-4 codec is; importing it is what turns `61xx` into a case with the
  /// remaining byte count on it rather than a number to compare against.
  StatusWord get status => StatusWord(statusWord1, statusWord2);

  /// Whether the card reported plain success, `9000`.
  ///
  /// A card can also answer `61xx` (more data available) or `62xx`/`63xx` (a warning), none
  /// of which are failures; check [statusWord] when those matter.
  bool get isSuccess => statusWord == 0x9000;

  @override
  String toString() =>
      'Iso7816ResponseApdu(${payload.length} bytes, SW=${statusWord.toRadixString(16).padLeft(4, '0')})';
}
