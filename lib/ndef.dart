/// NDEF values and the NFC Forum wire codec.
///
/// The value types here are pure Dart and need no tag: [NdefMessage.toBytes] and
/// [NdefMessage.fromBytes] implement the wire format directly, so a message can be built
/// for host card emulation or parsed out of an Android intent without a session.
///
/// The typed record views both build and parse:
///
/// ```dart
/// final message = NdefMessage([
///   TextRecord.create('merhaba', languageCode: 'tr'),
///   UriRecord.create(Uri.parse('https://example.com')),
/// ]);
///
/// for (final record in message.records) {
///   final text = TextRecord.from(record);
///   if (text != null) print('${text.languageCode}: ${text.text}');
/// }
/// ```
library;

export 'src/ndef/message.dart' show NdefMessage;
export 'src/ndef/ndef.dart' show Ndef;
export 'src/ndef/record.dart'
    show
        ExternalRecord,
        MimeRecord,
        NdefRecord,
        NdefTypeNameFormat,
        SmartPosterAction,
        SmartPosterRecord,
        TextRecord,
        UriRecord;
