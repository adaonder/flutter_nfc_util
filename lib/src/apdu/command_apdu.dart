import 'dart:typed_data';

/// One ISO 7816-4 command APDU, and the rules for putting it on the wire.
///
/// The package could already tell you whether a card takes extended-length APDUs --
/// `IsoDep.isExtendedLengthApduSupported` -- while giving you nothing that could build one,
/// so every caller wrote the Lc and Le fields by hand. That is a quiet thing to get wrong.
/// The four ISO 7816-4 cases differ only in where the length bytes sit, and a command
/// assembled for the wrong case is still a syntactically valid APDU: the card answers `6700`,
/// or reads a data field that starts three bytes off, rather than reporting anything that
/// names the mistake.
///
/// The short form is used whenever the sizes fit it. Data longer than 255 bytes or an
/// [expectedResponseLength] above 256 leaves no choice but the extended form, and
/// [forceExtended] asks for it outright -- whether a particular card accepts extended APDUs
/// is the caller's knowledge, not something the lengths can imply.
///
/// ```dart
/// final select = CommandApdu(
///   instructionClass: 0x00,
///   instructionCode: 0xA4,
///   p1Parameter: 0x04,
///   p2Parameter: 0x00,
///   data: applicationId,
///   expectedResponseLength: 256,
/// );
/// final response = await card.sendCommandRaw(select.toBytes());
/// ```
class CommandApdu {
  const CommandApdu._({
    required this.instructionClass,
    required this.instructionCode,
    required this.p1Parameter,
    required this.p2Parameter,
    required this.data,
    required this.expectedResponseLength,
    required this.forceExtended,
  });

  /// Constructs a command, rejecting values that cannot be encoded.
  ///
  /// Every range is checked here rather than at [toBytes], so a command that could never
  /// reach a card fails where it was written instead of inside a reader session.
  factory CommandApdu({
    required int instructionClass,
    required int instructionCode,
    required int p1Parameter,
    required int p2Parameter,
    Uint8List? data,
    int? expectedResponseLength,
    bool forceExtended = false,
  }) {
    _checkByte(instructionClass, 'instructionClass');
    _checkByte(instructionCode, 'instructionCode');
    _checkByte(p1Parameter, 'p1Parameter');
    _checkByte(p2Parameter, 'p2Parameter');

    // An empty data field is the same as none: the wire has no Lc of zero, in either form,
    // so a caller who passes an empty list means case 1 or case 2 whether they know it or not.
    final body = (data == null || data.isEmpty) ? null : data;
    if (body != null && body.length > 65535) {
      throw ArgumentError.value(body.length, 'data', 'does not fit the two-byte extended Lc field');
    }
    if (expectedResponseLength != null && (expectedResponseLength < 1 || expectedResponseLength > 65536)) {
      throw ArgumentError.value(
        expectedResponseLength,
        'expectedResponseLength',
        'must be between 1 and 65536; pass null for a command that asks for no response data',
      );
    }

    return CommandApdu._(
      instructionClass: instructionClass,
      instructionCode: instructionCode,
      p1Parameter: p1Parameter,
      p2Parameter: p2Parameter,
      data: body,
      expectedResponseLength: expectedResponseLength,
      forceExtended: forceExtended,
    );
  }

  /// CLA.
  final int instructionClass;

  /// INS.
  final int instructionCode;

  /// P1.
  final int p1Parameter;

  /// P2.
  final int p2Parameter;

  /// The command data field, or null when the command carries none.
  ///
  /// An empty list given to the constructor arrives here as null, because Lc is 1..255 in
  /// the short form and 1..65535 in the extended one -- zero is not a length the wire has.
  final Uint8List? data;

  /// How many bytes of response the command asks for, or null when it asks for none.
  ///
  /// Null and zero are different, and only null can be sent: a short Le byte of `0x00` means
  /// 256 and an extended Le of `0x0000` means 65536, so nothing encodes "answer with no
  /// bytes". Zero is rejected rather than quietly turned into 256.
  final int? expectedResponseLength;

  /// Whether the extended form was asked for even though the lengths fit the short one.
  ///
  /// Cards that reject extended APDUs are common enough that this is never inferred; a
  /// reader that has checked `IsoDep.isExtendedLengthApduSupported`, or that knows its card,
  /// sets it.
  final bool forceExtended;

  /// Whether [toBytes] writes the extended length fields.
  ///
  /// False for a command with neither data nor [expectedResponseLength] even when
  /// [forceExtended] is set: case 1 is the four header bytes alone, and ISO 7816-4 gives it
  /// no extended spelling.
  bool get isExtended {
    final body = data;
    final le = expectedResponseLength;
    if (body == null && le == null) return false;
    return forceExtended || (body != null && body.length > 255) || (le != null && le > 256);
  }

  /// Encodes the command per ISO 7816-4.
  Uint8List toBytes() {
    final out = BytesBuilder(copy: false);
    out.add([instructionClass, instructionCode, p1Parameter, p2Parameter]);

    final body = data;
    final le = expectedResponseLength;
    if (body == null && le == null) return out.takeBytes(); // Case 1: the header is the whole command.

    if (!isExtended) {
      if (body != null) {
        out.addByte(body.length); // Case 3S and 4S.
        out.add(body);
      }
      if (le != null) out.addByte(le == 256 ? 0x00 : le); // Case 2S and 4S; 256 is spelled 0x00.
      return out.takeBytes();
    }

    // The `0x00` marker announces the extended fields, and it is written exactly once. A
    // command that carries data spends it on Lc, so its Le follows the data field as a bare
    // pair of bytes; a command with no data spends it on Le instead.
    out.addByte(0x00);
    if (body != null) {
      out.add([(body.length >> 8) & 0xFF, body.length & 0xFF]); // Case 3E and 4E.
      out.add(body);
    }
    if (le != null) out.add([(le >> 8) & 0xFF, le & 0xFF]); // Case 2E and 4E; 65536 wraps to 0x0000.

    return out.takeBytes();
  }

  /// The same command asking for [expectedResponseLength] bytes instead.
  ///
  /// This is what a `6Cxx` answer calls for: the card rejected the Le it was sent and named
  /// the one it wants, and the command has to go out again unchanged except for that field.
  CommandApdu withExpectedResponseLength(int expectedResponseLength) => CommandApdu(
    instructionClass: instructionClass,
    instructionCode: instructionCode,
    p1Parameter: p1Parameter,
    p2Parameter: p2Parameter,
    data: data,
    expectedResponseLength: expectedResponseLength,
    forceExtended: forceExtended,
  );

  @override
  String toString() {
    final header = [
      instructionClass,
      instructionCode,
      p1Parameter,
      p2Parameter,
    ].map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    final body = data;
    return 'CommandApdu($header, ${body == null ? 'no data' : '${body.length} bytes'}, '
        'Le ${expectedResponseLength ?? 'none'}${isExtended ? ', extended' : ''})';
  }
}

void _checkByte(int value, String name) {
  if (value < 0 || value > 255) throw ArgumentError.value(value, name, 'is not a byte');
}
