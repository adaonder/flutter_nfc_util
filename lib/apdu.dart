/// ISO 7816-4 command APDUs, status words, and response chaining.
///
/// Like the NDEF codec, none of this needs a tag: [CommandApdu] encodes, [StatusWord]
/// decodes, and both can be exercised in a unit test on a machine with no NFC radio at all.
/// [Iso7816Chaining] does talk to a card, but only through a function you hand it, so it
/// belongs to neither platform and works with both.
///
/// What the platform libraries give you is a way to move bytes -- `Iso7816.sendCommandRaw` on
/// iOS, `IsoDep.transceive` on Android. What they do not give you is the protocol: nothing
/// builds an extended-length APDU, nothing tells you what `6A82` means, and nothing follows a
/// `61xx` chain, so a caller who does not know to loop gets a silently truncated answer. This
/// library is that missing half.
///
/// ```dart
/// import 'package:nfc_util/apdu.dart';
/// import 'package:nfc_util/ios.dart' as ios;
///
/// final card = ios.Iso7816.from(tag)!;
/// final response = await Iso7816Chaining(card.sendCommandRaw).sendCommand(
///   CommandApdu(
///     instructionClass: 0x00,
///     instructionCode: 0xA4,
///     p1Parameter: 0x04,
///     p2Parameter: 0x00,
///     data: applicationId,
///     expectedResponseLength: 256,
///   ),
/// );
///
/// if (response.status case StatusWordError(reason: final reason)) {
///   throw StateError('SELECT refused: ${reason ?? response.status}');
/// }
/// ```
library;

export 'src/apdu/chaining.dart' show Iso7816Chaining;
export 'src/apdu/command_apdu.dart' show CommandApdu;
export 'src/apdu/response_apdu.dart' show Iso7816ResponseApdu;
export 'src/apdu/status_word.dart'
    show
        StatusWord,
        StatusWordError,
        StatusWordErrorReason,
        StatusWordMoreData,
        StatusWordSuccess,
        StatusWordUnrecognised,
        StatusWordWarning,
        StatusWordWrongLength;
