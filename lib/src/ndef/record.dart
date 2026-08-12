import 'dart:convert';
import 'dart:typed_data';

import 'message.dart';

/// The NDEF Type-Name-Format, as defined by the NFC Forum NDEF specification.
///
/// The ordinals are the on-tag values 0x00..0x06, so [NdefRecord] can encode one directly.
enum NdefTypeNameFormat {
  /// The record carries no type and no payload.
  empty,

  /// An NFC Forum well-known type: `T` for text, `U` for URI, `Sp` for a smart poster.
  wellKnown,

  /// Media data typed by a MIME type, as defined by RFC 2046.
  media,

  /// An absolute URI, used as the type itself rather than as content.
  absoluteUri,

  /// An application-specific type, namespaced by a domain: `example.com:widget`.
  external,

  /// The payload's type is not known.
  unknown,

  /// A continuation of the previous record's payload. Only valid inside a chunked record.
  unchanged,
}

/// One immutable NDEF record.
///
/// Records read off a tag come back through [NdefRecord.fromParts], which skips the
/// creation-time validation: tags legitimately hold shapes the creation rules reject, and
/// refusing to represent them would turn a readable tag into an exception. Records you
/// build yourself go through the validating constructors.
///
/// For the well-known types there are typed views -- [TextRecord], [UriRecord],
/// [SmartPosterRecord], [MimeRecord], [ExternalRecord] -- which both build and parse.
class NdefRecord {
  const NdefRecord._({
    required this.typeNameFormat,
    required this.type,
    required this.identifier,
    required this.payload,
  });

  /// The NFC Forum URI prefixes, indexed by the first byte of a URI record's payload.
  ///
  /// Index 0 is the empty prefix, meaning the payload holds the whole URI.
  static const List<String> uriPrefixList = [
    '',
    'http://www.',
    'https://www.',
    'http://',
    'https://',
    'tel:',
    'mailto:',
    'ftp://anonymous:anonymous@',
    'ftp://ftp.',
    'ftps://',
    'sftp://',
    'smb://',
    'nfs://',
    'ftp://',
    'dav://',
    'news:',
    'telnet://',
    'imap:',
    'rtsp://',
    'urn:',
    'pop:',
    'sip:',
    'sips:',
    'tftp:',
    'btspp://',
    'btl2cap://',
    'btgoep://',
    'tcpobex://',
    'irdaobex://',
    'file://',
    'urn:epc:id:',
    'urn:epc:tag:',
    'urn:epc:pat:',
    'urn:epc:raw:',
    'urn:epc:',
    'urn:nfc:',
  ];

  /// The well-known type of a text record.
  static final Uint8List wellKnownTypeText = Uint8List.fromList([0x54]); // 'T'

  /// The well-known type of a URI record.
  static final Uint8List wellKnownTypeUri = Uint8List.fromList([0x55]); // 'U'

  /// The well-known type of a smart poster record.
  static final Uint8List wellKnownTypeSmartPoster = Uint8List.fromList([0x53, 0x70]); // 'Sp'

  /// How the [type] field should be read.
  final NdefTypeNameFormat typeNameFormat;

  /// The type, interpreted according to [typeNameFormat].
  final Uint8List type;

  /// The record identifier. Usually empty.
  final Uint8List identifier;

  /// The record content.
  final Uint8List payload;

  /// Constructs a record, rejecting shapes the NDEF specification forbids.
  ///
  /// Prefer [TextRecord.create], [UriRecord.create] and friends, which also get the
  /// payload encoding right.
  factory NdefRecord({
    required NdefTypeNameFormat typeNameFormat,
    required Uint8List type,
    required Uint8List identifier,
    required Uint8List payload,
  }) {
    switch (typeNameFormat) {
      case NdefTypeNameFormat.empty:
        if (type.isNotEmpty || identifier.isNotEmpty || payload.isNotEmpty) {
          throw ArgumentError('an empty record carries no type, identifier or payload');
        }
      case NdefTypeNameFormat.unknown:
        if (type.isNotEmpty) throw ArgumentError('an unknown-format record carries no type');
      case NdefTypeNameFormat.unchanged:
        throw ArgumentError('unchanged is only valid on a chunk continuation, not a whole record');
      case NdefTypeNameFormat.wellKnown:
      case NdefTypeNameFormat.media:
      case NdefTypeNameFormat.absoluteUri:
      case NdefTypeNameFormat.external:
        break;
    }
    return NdefRecord._(typeNameFormat: typeNameFormat, type: type, identifier: identifier, payload: payload);
  }

  /// Constructs a record from values that already exist on a tag or on the wire, without
  /// the creation-time validation.
  ///
  /// Used when decoding. A chunked record carries [NdefTypeNameFormat.unchanged], which the
  /// validating constructor refuses.
  factory NdefRecord.fromParts({
    required NdefTypeNameFormat typeNameFormat,
    required Uint8List type,
    required Uint8List identifier,
    required Uint8List payload,
  }) {
    return NdefRecord._(typeNameFormat: typeNameFormat, type: type, identifier: identifier, payload: payload);
  }

  /// The number of bytes this record occupies when stored on a tag.
  int get byteLength {
    // Header, type length, and a one-byte payload length.
    var length = 3 + type.length + identifier.length + payload.length;

    // A payload of 256 bytes or more needs the four-byte length instead.
    if (payload.length > 255) length += 3;

    // The ID length byte is present when there is an identifier, and -- per the
    // specification -- always for an empty record.
    if (typeNameFormat == NdefTypeNameFormat.empty || identifier.isNotEmpty) length += 1;

    return length;
  }

  @override
  bool operator ==(Object other) =>
      other is NdefRecord &&
      other.typeNameFormat == typeNameFormat &&
      _bytesEqual(other.type, type) &&
      _bytesEqual(other.identifier, identifier) &&
      _bytesEqual(other.payload, payload);

  @override
  int get hashCode => Object.hash(typeNameFormat, _bytesHash(type), _bytesHash(identifier), _bytesHash(payload));

  @override
  String toString() =>
      'NdefRecord(${typeNameFormat.name}, type: ${_hex(type)}, id: ${_hex(identifier)}, '
      'payload: ${payload.length} bytes)';
}

/// A record holding UTF-8 or UTF-16 text, with the language it is written in.
///
/// ```dart
/// final record = TextRecord.create('merhaba', languageCode: 'tr');
/// final parsed = TextRecord.from(record); // parsed.text == 'merhaba'
/// ```
class TextRecord {
  const TextRecord._({required this.text, required this.languageCode, required this.isUtf16});

  /// The decoded text.
  final String text;

  /// The IANA language code the text is written in, such as `en` or `tr`.
  final String languageCode;

  /// Whether the payload was stored as UTF-16 rather than UTF-8.
  final bool isUtf16;

  /// Builds a well-known text record. Always encodes as UTF-8.
  static NdefRecord create(String text, {String languageCode = 'en'}) {
    final languageCodeBytes = ascii.encode(languageCode);
    // The status byte packs the length into six bits, so 63 is the ceiling.
    if (languageCodeBytes.length > 63) throw ArgumentError.value(languageCode, 'languageCode', 'is too long');

    return NdefRecord(
      typeNameFormat: NdefTypeNameFormat.wellKnown,
      type: NdefRecord.wellKnownTypeText,
      identifier: Uint8List(0),
      payload: Uint8List.fromList([languageCodeBytes.length, ...languageCodeBytes, ...utf8.encode(text)]),
    );
  }

  /// Reads [record] as a text record, or returns null when it is not one or is malformed.
  static TextRecord? from(NdefRecord record) {
    if (record.typeNameFormat != NdefTypeNameFormat.wellKnown) return null;
    if (!_bytesEqual(record.type, NdefRecord.wellKnownTypeText)) return null;
    if (record.payload.isEmpty) return null;

    final status = record.payload[0];
    final languageCodeLength = status & 0x3F;
    // A truncated payload is a broken tag, not an exception: report "not a text record".
    if (record.payload.length < 1 + languageCodeLength) return null;

    final isUtf16 = (status & 0x80) != 0;
    final languageCode = ascii.decode(record.payload.sublist(1, 1 + languageCodeLength), allowInvalid: true);
    final textBytes = record.payload.sublist(1 + languageCodeLength);

    final String text;
    if (isUtf16) {
      text = _decodeUtf16(textBytes);
    } else {
      text = utf8.decode(textBytes, allowMalformed: true);
    }

    return TextRecord._(text: text, languageCode: languageCode, isUtf16: isUtf16);
  }

  @override
  String toString() => 'TextRecord($languageCode, "$text")';
}

/// A record holding a URI, stored with its common prefix abbreviated to a single byte.
class UriRecord {
  const UriRecord._(this.uri);

  /// The reassembled URI.
  final Uri uri;

  /// Builds a well-known URI record, abbreviating the longest matching prefix.
  static NdefRecord create(Uri uri) {
    final uriString = uri.normalizePath().toString();
    if (uriString.isEmpty) throw ArgumentError.value(uri, 'uri', 'is empty');

    // Index 0 is the empty prefix and matches everything, so the search starts at 1 and
    // falls back to 0. Later entries are not strictly longer than earlier ones, so take the
    // longest match rather than the first.
    var prefixIndex = 0;
    for (var i = 1; i < NdefRecord.uriPrefixList.length; i++) {
      final prefix = NdefRecord.uriPrefixList[i];
      if (uriString.startsWith(prefix) && prefix.length > NdefRecord.uriPrefixList[prefixIndex].length) {
        prefixIndex = i;
      }
    }

    return NdefRecord(
      typeNameFormat: NdefTypeNameFormat.wellKnown,
      type: NdefRecord.wellKnownTypeUri,
      identifier: Uint8List(0),
      payload: Uint8List.fromList([
        prefixIndex,
        ...utf8.encode(uriString.substring(NdefRecord.uriPrefixList[prefixIndex].length)),
      ]),
    );
  }

  /// Reads [record] as a URI record, or returns null when it is not one or is malformed.
  ///
  /// Also accepts [NdefTypeNameFormat.absoluteUri], where the URI is the type field and
  /// there is no prefix byte.
  static UriRecord? from(NdefRecord record) {
    if (record.typeNameFormat == NdefTypeNameFormat.absoluteUri) {
      final parsed = Uri.tryParse(utf8.decode(record.type, allowMalformed: true));
      return parsed == null ? null : UriRecord._(parsed);
    }

    if (record.typeNameFormat != NdefTypeNameFormat.wellKnown) return null;
    if (!_bytesEqual(record.type, NdefRecord.wellKnownTypeUri)) return null;
    if (record.payload.isEmpty) return null;

    final prefixIndex = record.payload[0];
    // A prefix index this version does not know cannot be resolved; the rest of the payload
    // alone would be a different URI, so report "not a URI record" rather than guess.
    if (prefixIndex >= NdefRecord.uriPrefixList.length) return null;

    final suffix = utf8.decode(record.payload.sublist(1), allowMalformed: true);
    final parsed = Uri.tryParse('${NdefRecord.uriPrefixList[prefixIndex]}$suffix');
    return parsed == null ? null : UriRecord._(parsed);
  }

  @override
  String toString() => 'UriRecord($uri)';
}

/// What a reader should do with a smart poster.
enum SmartPosterAction {
  /// Act on the URI: open it, dial it, send the mail.
  execute,

  /// Save the URI for later.
  save,

  /// Open the URI for editing.
  edit,
}

/// A smart poster: a URI with a human-readable title and an optional action, all packed
/// into one record whose payload is itself an NDEF message.
///
/// This is the record type a printed NFC poster uses. It needs the wire codec in both
/// directions, which is why it only became expressible once [NdefMessage] gained one.
class SmartPosterRecord {
  const SmartPosterRecord._({required this.uri, required this.titles, required this.action, required this.icon});

  /// The URI the poster points at.
  final Uri uri;

  /// Titles by language code. A poster may carry one per language.
  final Map<String, String> titles;

  /// What the reader should do, when the poster says.
  final SmartPosterAction? action;

  /// An icon, as raw bytes with its MIME type, when the poster carries one.
  final ({String mimeType, Uint8List data})? icon;

  /// The title in [languageCode], falling back to any title the poster has.
  String? title({String languageCode = 'en'}) =>
      titles[languageCode] ?? (titles.isEmpty ? null : titles.values.first);

  /// Builds a smart poster record.
  static NdefRecord create({
    required Uri uri,
    String? title,
    String titleLanguageCode = 'en',
    SmartPosterAction? action,
    String? iconMimeType,
    Uint8List? iconData,
  }) {
    if ((iconMimeType == null) != (iconData == null)) {
      throw ArgumentError('iconMimeType and iconData must be given together');
    }

    // The nested message must begin with the URI record; everything else is optional.
    final nested = <NdefRecord>[
      UriRecord.create(uri),
      if (title != null) TextRecord.create(title, languageCode: titleLanguageCode),
      if (action != null)
        NdefRecord(
          typeNameFormat: NdefTypeNameFormat.wellKnown,
          type: Uint8List.fromList(ascii.encode('act')),
          identifier: Uint8List(0),
          payload: Uint8List.fromList([action.index]),
        ),
      if (iconMimeType != null && iconData != null) MimeRecord.create(iconMimeType, iconData),
    ];

    return NdefRecord(
      typeNameFormat: NdefTypeNameFormat.wellKnown,
      type: NdefRecord.wellKnownTypeSmartPoster,
      identifier: Uint8List(0),
      payload: NdefMessage(nested).toBytes(),
    );
  }

  /// Reads [record] as a smart poster, or returns null when it is not one or is malformed.
  static SmartPosterRecord? from(NdefRecord record) {
    if (record.typeNameFormat != NdefTypeNameFormat.wellKnown) return null;
    if (!_bytesEqual(record.type, NdefRecord.wellKnownTypeSmartPoster)) return null;

    final NdefMessage nested;
    try {
      nested = NdefMessage.fromBytes(record.payload);
    } on FormatException {
      return null;
    }

    Uri? uri;
    final titles = <String, String>{};
    SmartPosterAction? action;
    ({String mimeType, Uint8List data})? icon;

    for (final inner in nested.records) {
      final asUri = UriRecord.from(inner);
      if (asUri != null && uri == null) {
        uri = asUri.uri;
        continue;
      }

      final asText = TextRecord.from(inner);
      if (asText != null) {
        titles[asText.languageCode] = asText.text;
        continue;
      }

      if (inner.typeNameFormat == NdefTypeNameFormat.wellKnown &&
          _bytesEqual(inner.type, Uint8List.fromList(ascii.encode('act'))) &&
          inner.payload.length == 1 &&
          inner.payload[0] < SmartPosterAction.values.length) {
        action = SmartPosterAction.values[inner.payload[0]];
        continue;
      }

      final asMime = MimeRecord.from(inner);
      if (asMime != null && icon == null && asMime.mimeType.startsWith('image/')) {
        icon = (mimeType: asMime.mimeType, data: asMime.data);
      }
    }

    // The URI is the one mandatory part; without it this is not a usable poster.
    if (uri == null) return null;
    return SmartPosterRecord._(uri: uri, titles: titles, action: action, icon: icon);
  }

  @override
  String toString() => 'SmartPosterRecord($uri, titles: $titles, action: ${action?.name})';
}

/// A record holding media data typed by a MIME type, as defined by RFC 2046.
class MimeRecord {
  const MimeRecord._({required this.mimeType, required this.data});

  /// The MIME type, lowercased, without any parameters.
  final String mimeType;

  /// The media content.
  final Uint8List data;

  /// Builds a media record. Parameters after `;` are dropped, since NDEF stores the bare
  /// type.
  static NdefRecord create(String mimeType, Uint8List data) {
    final normalized = mimeType.toLowerCase().trim().split(';').first;
    if (normalized.isEmpty) throw ArgumentError.value(mimeType, 'mimeType', 'is empty');

    final slashIndex = normalized.indexOf('/');
    if (slashIndex <= 0) throw ArgumentError.value(mimeType, 'mimeType', 'must have a major type');
    if (slashIndex == normalized.length - 1) throw ArgumentError.value(mimeType, 'mimeType', 'must have a minor type');

    return NdefRecord(
      typeNameFormat: NdefTypeNameFormat.media,
      type: ascii.encode(normalized),
      identifier: Uint8List(0),
      payload: data,
    );
  }

  /// Reads [record] as a media record, or returns null when it is not one.
  static MimeRecord? from(NdefRecord record) {
    if (record.typeNameFormat != NdefTypeNameFormat.media) return null;
    if (record.type.isEmpty) return null;
    return MimeRecord._(mimeType: ascii.decode(record.type, allowInvalid: true), data: record.payload);
  }

  @override
  String toString() => 'MimeRecord($mimeType, ${data.length} bytes)';
}

/// A record holding application-specific data, namespaced by a domain.
class ExternalRecord {
  const ExternalRecord._({required this.domain, required this.type, required this.data});

  /// The owning domain, such as `example.com`.
  final String domain;

  /// The type within that domain.
  final String type;

  /// The content.
  final Uint8List data;

  /// Builds an external record. The stored type is `domain:type`, lowercased.
  static NdefRecord create(String domain, String type, Uint8List data) {
    final normalizedDomain = domain.trim().toLowerCase();
    final normalizedType = type.trim().toLowerCase();
    if (normalizedDomain.isEmpty) throw ArgumentError.value(domain, 'domain', 'is empty');
    if (normalizedType.isEmpty) throw ArgumentError.value(type, 'type', 'is empty');

    return NdefRecord(
      typeNameFormat: NdefTypeNameFormat.external,
      type: Uint8List.fromList(utf8.encode('$normalizedDomain:$normalizedType')),
      identifier: Uint8List(0),
      payload: data,
    );
  }

  /// Reads [record] as an external record, or returns null when it is not one or carries no
  /// `domain:type` separator.
  static ExternalRecord? from(NdefRecord record) {
    if (record.typeNameFormat != NdefTypeNameFormat.external) return null;

    final combined = utf8.decode(record.type, allowMalformed: true);
    final separator = combined.indexOf(':');
    if (separator <= 0 || separator == combined.length - 1) return null;

    return ExternalRecord._(
      domain: combined.substring(0, separator),
      type: combined.substring(separator + 1),
      data: record.payload,
    );
  }

  @override
  String toString() => 'ExternalRecord($domain:$type, ${data.length} bytes)';
}

/// UTF-16 text records carry an optional byte order mark; without one the specification
/// says big endian.
String _decodeUtf16(Uint8List bytes) {
  if (bytes.length < 2) return '';

  var offset = 0;
  var bigEndian = true;
  if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
    offset = 2;
  } else if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
    offset = 2;
    bigEndian = false;
  }

  final units = <int>[];
  for (var i = offset; i + 1 < bytes.length; i += 2) {
    units.add(bigEndian ? (bytes[i] << 8) | bytes[i + 1] : (bytes[i + 1] << 8) | bytes[i]);
  }
  return String.fromCharCodes(units);
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _bytesHash(Uint8List bytes) => Object.hashAll(bytes);

String _hex(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
