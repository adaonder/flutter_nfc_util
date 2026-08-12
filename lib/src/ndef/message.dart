import 'dart:typed_data';

import 'record.dart';

// Header flag bits, in the first byte of every record.
const int _flagMessageBegin = 0x80;
const int _flagMessageEnd = 0x40;
const int _flagChunked = 0x20;
const int _flagShortRecord = 0x10;
const int _flagIdLengthPresent = 0x08;
const int _maskTypeNameFormat = 0x07;

/// An immutable NDEF message: an ordered list of records.
///
/// [toBytes] and [fromBytes] implement the NFC Forum wire format in Dart, so a message can
/// be built or parsed without a tag in range. That matters in three places: host card
/// emulation, where this side of the exchange has to produce the bytes itself; Android
/// intents, which hand over already-serialized messages; and tests, which can then cover
/// the codec without a device.
class NdefMessage {
  /// Constructs a message from [records].
  const NdefMessage(this.records);

  /// The records, in order.
  final List<NdefRecord> records;

  /// The number of bytes this message occupies when stored on a tag.
  int get byteLength => records.fold(0, (sum, record) => sum + record.byteLength);

  /// Encodes this message in the NFC Forum wire format.
  ///
  /// Chunking is never produced: every record is written whole, which is what real readers
  /// expect and what both platforms do.
  Uint8List toBytes() {
    final out = BytesBuilder(copy: false);

    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      final isShort = record.payload.length < 256;
      // The specification always writes the ID length byte for an empty record.
      final hasId = record.identifier.isNotEmpty || record.typeNameFormat == NdefTypeNameFormat.empty;

      var header = record.typeNameFormat.index & _maskTypeNameFormat;
      if (i == 0) header |= _flagMessageBegin;
      if (i == records.length - 1) header |= _flagMessageEnd;
      if (isShort) header |= _flagShortRecord;
      if (hasId) header |= _flagIdLengthPresent;

      out.addByte(header);
      out.addByte(record.type.length);

      if (isShort) {
        out.addByte(record.payload.length);
      } else {
        final length = record.payload.length;
        out.add([(length >> 24) & 0xFF, (length >> 16) & 0xFF, (length >> 8) & 0xFF, length & 0xFF]);
      }

      if (hasId) out.addByte(record.identifier.length);

      out.add(record.type);
      out.add(record.identifier);
      out.add(record.payload);
    }

    return out.takeBytes();
  }

  /// Decodes a message from the NFC Forum wire format.
  ///
  /// Chunked records are reassembled into one logical record, so a caller never sees
  /// [NdefTypeNameFormat.unchanged].
  ///
  /// Throws a [FormatException] on truncated or malformed input.
  factory NdefMessage.fromBytes(Uint8List bytes) {
    final records = <NdefRecord>[];
    var offset = 0;
    var sawMessageBegin = false;
    var sawMessageEnd = false;

    // State for a chunked record in progress.
    NdefTypeNameFormat? chunkFormat;
    Uint8List? chunkType;
    Uint8List? chunkIdentifier;
    BytesBuilder? chunkPayload;

    int readByte() {
      if (offset >= bytes.length) throw const FormatException('truncated NDEF message');
      return bytes[offset++];
    }

    Uint8List readBytes(int length) {
      if (offset + length > bytes.length) throw const FormatException('truncated NDEF message');
      final slice = Uint8List.sublistView(bytes, offset, offset + length);
      offset += length;
      // Copy: sublistView aliases the caller's buffer, and records are documented immutable.
      return Uint8List.fromList(slice);
    }

    while (offset < bytes.length) {
      final header = readByte();
      final isChunked = (header & _flagChunked) != 0;
      final isShort = (header & _flagShortRecord) != 0;
      final hasId = (header & _flagIdLengthPresent) != 0;
      // 0x07 is reserved by the specification and has no enum value; indexing on it blind
      // would raise a RangeError out of what is otherwise a well-defined parse failure.
      final formatIndex = header & _maskTypeNameFormat;
      if (formatIndex >= NdefTypeNameFormat.values.length) {
        throw const FormatException('reserved NDEF type name format 0x07');
      }
      final format = NdefTypeNameFormat.values[formatIndex];

      if ((header & _flagMessageBegin) != 0) {
        if (sawMessageBegin) throw const FormatException('second MB flag in one NDEF message');
        sawMessageBegin = true;
      } else if (records.isEmpty && chunkPayload == null) {
        throw const FormatException('NDEF message does not start with an MB record');
      }
      if (sawMessageEnd) throw const FormatException('record after the ME flag');

      final typeLength = readByte();
      final int payloadLength;
      if (isShort) {
        payloadLength = readByte();
      } else {
        final b0 = readByte(), b1 = readByte(), b2 = readByte(), b3 = readByte();
        payloadLength = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
        if (payloadLength < 0) throw const FormatException('NDEF payload length overflows');
      }
      final idLength = hasId ? readByte() : 0;

      final type = readBytes(typeLength);
      final identifier = readBytes(idLength);
      final payload = readBytes(payloadLength);

      if ((header & _flagMessageEnd) != 0) sawMessageEnd = true;

      if (chunkPayload != null) {
        // Middle or final chunk of a record already in progress.
        if (format != NdefTypeNameFormat.unchanged) {
          throw const FormatException('chunk continuation must use the UNCHANGED type name format');
        }
        if (typeLength != 0) throw const FormatException('chunk continuation must not carry a type');
        chunkPayload.add(payload);

        if (!isChunked) {
          records.add(
            NdefRecord.fromParts(
              typeNameFormat: chunkFormat!,
              type: chunkType!,
              identifier: chunkIdentifier!,
              payload: chunkPayload.takeBytes(),
            ),
          );
          chunkFormat = null;
          chunkType = null;
          chunkIdentifier = null;
          chunkPayload = null;
        }
        continue;
      }

      if (isChunked) {
        // First chunk: its type and identifier describe the whole logical record.
        if (format == NdefTypeNameFormat.unchanged) {
          throw const FormatException('unexpected UNCHANGED in first chunk or logical record');
        }
        chunkFormat = format;
        chunkType = type;
        chunkIdentifier = identifier;
        chunkPayload = BytesBuilder(copy: false)..add(payload);
        continue;
      }

      // UNCHANGED only ever means "the previous record's payload continues here". Reaching
      // this line means there was no chunk to continue, and letting it through would hand
      // the caller a record this library's own writer refuses to encode.
      if (format == NdefTypeNameFormat.unchanged) {
        throw const FormatException('UNCHANGED record outside a chunked sequence');
      }

      records.add(
        NdefRecord.fromParts(typeNameFormat: format, type: type, identifier: identifier, payload: payload),
      );
    }

    if (chunkPayload != null) throw const FormatException('NDEF message ends inside a chunked record');
    if (records.isNotEmpty && !sawMessageEnd) throw const FormatException('NDEF message has no ME record');

    return NdefMessage(records);
  }

  @override
  bool operator ==(Object other) {
    if (other is! NdefMessage || other.records.length != records.length) return false;
    for (var i = 0; i < records.length; i++) {
      if (other.records[i] != records[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(records);

  @override
  String toString() => 'NdefMessage(${records.length} records, $byteLength bytes)';
}
