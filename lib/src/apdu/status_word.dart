/// What a card said in its two status bytes, decoded.
///
/// The point of the type is that a caller stops carrying a table of hex constants in its
/// head: `9000`, `61xx`, `6A82` and the rest turn into cases the analyzer can check.
///
/// It is a sealed hierarchy rather than an enum because the interesting status words carry a
/// number -- how many bytes are still waiting, what length the card wanted, how many attempts
/// remain -- and because an enum would have to answer for every value a future card can
/// send. Anything this release does not classify arrives as [StatusWordUnrecognised] with
/// [value] intact, so a card that speaks a proprietary dialect stays readable instead of
/// being flattened into "unknown" or, worse, throwing.
///
/// ```dart
/// switch (response.status) {
///   case StatusWordSuccess():
///     return response.payload;
///   case StatusWordMoreData(:final remainingBytes):
///     return getResponse(remainingBytes);
///   case StatusWordError(reason: StatusWordErrorReason.fileNotFound):
///     throw StateError('no such file on this card');
///   case final other:
///     throw StateError('card answered ${other.value.toRadixString(16)}');
/// }
/// ```
sealed class StatusWord {
  const StatusWord._(this.statusWord1, this.statusWord2);

  /// Decodes the two status bytes as the card sent them.
  factory StatusWord(int statusWord1, int statusWord2) {
    _checkByte(statusWord1, 'statusWord1');
    _checkByte(statusWord2, 'statusWord2');
    return _decode(statusWord1, statusWord2);
  }

  /// Decodes the 16-bit form card specifications are written in, such as `0x6A82`.
  factory StatusWord.fromValue(int value) {
    if (value < 0 || value > 0xFFFF) throw ArgumentError.value(value, 'value', 'is not a 16-bit status word');
    return _decode((value >> 8) & 0xFF, value & 0xFF);
  }

  /// SW1.
  final int statusWord1;

  /// SW2.
  final int statusWord2;

  /// SW1 and SW2 as one 16-bit value, which is how card specifications write them.
  int get value => (statusWord1 << 8) | statusWord2;

  @override
  bool operator ==(Object other) => other is StatusWord && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'StatusWord(${_hex(value)})';
}

/// `9000`. The command completed and the card has nothing further to hand over.
final class StatusWordSuccess extends StatusWord {
  const StatusWordSuccess._(super.statusWord1, super.statusWord2) : super._();

  @override
  String toString() => 'StatusWordSuccess(${_hex(value)})';
}

/// `61xx`. The command completed and [remainingBytes] more bytes are waiting behind a
/// GET RESPONSE.
///
/// A caller that stops here gets a truncated answer, which is the whole reason
/// `Iso7816Chaining` exists.
final class StatusWordMoreData extends StatusWord {
  const StatusWordMoreData._(super.statusWord1, super.statusWord2) : super._();

  /// How many bytes the card is still holding.
  ///
  /// `6100` means 256, not zero: a card with nothing left to give answers `9000`, so SW2 of
  /// zero is the full short-form length -- the same convention the Le byte uses.
  int get remainingBytes => statusWord2 == 0 ? 256 : statusWord2;

  @override
  String toString() => 'StatusWordMoreData(${_hex(value)}, $remainingBytes more bytes)';
}

/// `6Cxx`. The Le the command carried was wrong, and [correctLength] is the one to re-send it
/// with. The card ran nothing and answered with no data.
final class StatusWordWrongLength extends StatusWord {
  const StatusWordWrongLength._(super.statusWord1, super.statusWord2) : super._();

  /// The exact length the card expects. `6C00` means 256, by the same convention as
  /// [StatusWordMoreData.remainingBytes].
  int get correctLength => statusWord2 == 0 ? 256 : statusWord2;

  @override
  String toString() => 'StatusWordWrongLength(${_hex(value)}, expects $correctLength)';
}

/// `62xx` and `63xx`. The command ran, with something the caller should know about.
///
/// A warning is not a failure and the response may well carry a payload; treating everything
/// that is not `9000` as an error throws away data the card successfully returned.
final class StatusWordWarning extends StatusWord {
  const StatusWordWarning._(super.statusWord1, super.statusWord2) : super._();

  /// Whether the card's non-volatile memory changed, `63xx`, rather than being left as it
  /// was, `62xx`.
  bool get isNonVolatileMemoryChanged => statusWord1 == 0x63;

  /// The attempts still left before the card locks, when it answered `63Cx` to a failed
  /// verification. Null for every other warning.
  ///
  /// Zero is a real answer and means the next failure is not survivable -- which is exactly
  /// the moment to stop retrying a PIN rather than burning the last attempt.
  int? get retryCounter => statusWord1 == 0x63 && (statusWord2 & 0xF0) == 0xC0 ? statusWord2 & 0x0F : null;

  @override
  String toString() {
    final counter = retryCounter;
    return 'StatusWordWarning(${_hex(value)}, memory '
        '${isNonVolatileMemoryChanged ? 'changed' : 'unchanged'}'
        '${counter == null ? '' : ', $counter attempts left'})';
  }
}

/// SW1 in `64`..`6F`: the card refused the command and ran nothing.
///
/// [reason] names the handful of status words worth branching on and is null for the rest --
/// the checking and execution errors run to dozens of values, most of them
/// application-specific, so an unnamed one is still an error rather than something
/// unrecognised.
final class StatusWordError extends StatusWord {
  const StatusWordError._(super.statusWord1, super.statusWord2, this.reason) : super._();

  /// The recognised meaning, or null when only [value] says what went wrong.
  final StatusWordErrorReason? reason;

  @override
  String toString() => 'StatusWordError(${_hex(value)}${reason == null ? '' : ', ${reason!.name}'})';
}

/// A status word that fits none of the shapes ISO 7816-4 defines.
///
/// Cards do this: Mifare DESFire answers `91xx` in its native wrapped mode, and plenty of
/// proprietary applets invent their own. [value] is kept exactly as it arrived so a caller
/// that knows the dialect can read it, and nothing here throws on a status word this release
/// has never seen.
final class StatusWordUnrecognised extends StatusWord {
  const StatusWordUnrecognised._(super.statusWord1, super.statusWord2) : super._();

  @override
  String toString() => 'StatusWordUnrecognised(${_hex(value)})';
}

/// The status words worth branching on by name, ordered as the specification numbers them.
enum StatusWordErrorReason {
  /// `6982`. The command needs a security condition -- a PIN, a mutual authentication --
  /// that has not been met yet.
  securityStatusNotSatisfied,

  /// `6A82`. No file or application with that identifier. On a SELECT, usually the wrong AID
  /// rather than a broken card.
  fileNotFound,

  /// `6A86`. P1 or P2 is wrong for this instruction.
  incorrectP1P2,

  /// `6D00`. The card knows the class but not this instruction.
  instructionNotSupported,

  /// `6E00`. The card does not answer to this CLA at all.
  classNotSupported,
}

StatusWord _decode(int statusWord1, int statusWord2) {
  // Order matters: 0x6C is inside the error range and has to be recognised before it.
  if (statusWord1 == 0x90 && statusWord2 == 0x00) return StatusWordSuccess._(statusWord1, statusWord2);
  if (statusWord1 == 0x61) return StatusWordMoreData._(statusWord1, statusWord2);
  if (statusWord1 == 0x6C) return StatusWordWrongLength._(statusWord1, statusWord2);
  if (statusWord1 == 0x62 || statusWord1 == 0x63) return StatusWordWarning._(statusWord1, statusWord2);
  if (statusWord1 >= 0x64 && statusWord1 <= 0x6F) {
    return StatusWordError._(statusWord1, statusWord2, _reasonFor((statusWord1 << 8) | statusWord2));
  }
  return StatusWordUnrecognised._(statusWord1, statusWord2);
}

StatusWordErrorReason? _reasonFor(int value) => switch (value) {
  0x6982 => StatusWordErrorReason.securityStatusNotSatisfied,
  0x6A82 => StatusWordErrorReason.fileNotFound,
  0x6A86 => StatusWordErrorReason.incorrectP1P2,
  0x6D00 => StatusWordErrorReason.instructionNotSupported,
  0x6E00 => StatusWordErrorReason.classNotSupported,
  _ => null,
};

void _checkByte(int value, String name) {
  if (value < 0 || value > 255) throw ArgumentError.value(value, name, 'is not a byte');
}

String _hex(int value) => value.toRadixString(16).padLeft(4, '0').toUpperCase();
