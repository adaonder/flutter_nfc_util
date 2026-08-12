import '../api.dart';
import '../common.dart';
import '../mapping.dart';
import '../pigeon.g.dart';
import 'message.dart';

/// NDEF operations on a discovered tag, on either platform.
///
/// Acquire one with [Ndef.from]:
///
/// ```dart
/// final ndef = Ndef.from(tag);
/// if (ndef == null) return; // the tag does not hold NDEF
///
/// final message = await ndef.read();
/// if (ndef.isWritable) {
///   await ndef.write(NdefMessage([TextRecord.create('merhaba', languageCode: 'tr')]));
/// }
/// ```
///
/// The platform-only extras live next door: `NdefAndroid` reports the NFC Forum tag type
/// and whether the tag can be locked, `NdefIos` re-reads the status live.
class Ndef {
  const Ndef._(this._handle, {required this.isWritable, required this.maxSize, required this.cachedMessage});

  /// Returns an instance for [tag], or null when the tag does not hold NDEF.
  ///
  /// Also null when the session set `skipNdefCheck`, which skips the probe that fills this
  /// in.
  static Ndef? from(NfcTag tag) {
    final android = tag.data.ndefAndroid;
    if (android != null) {
      return Ndef._(
        tag.data.handle,
        isWritable: android.isWritable,
        maxSize: android.maxSize,
        cachedMessage: android.cachedMessage == null ? null : ndefMessageFromWire(android.cachedMessage!),
      );
    }

    final ios = tag.data.ndefIos;
    if (ios != null) {
      return Ndef._(
        tag.data.handle,
        // CoreNFC reports a status rather than a flag; only readWrite can be written.
        isWritable: ios.status == NdefStatusPigeon.readWrite,
        maxSize: ios.capacity,
        cachedMessage: ios.cachedMessage == null ? null : ndefMessageFromWire(ios.cachedMessage!),
      );
    }

    return null;
  }

  final String _handle;

  /// Whether the tag will accept a [write].
  ///
  /// Captured at discovery. A tag locked between discovery and the write still fails.
  final bool isWritable;

  /// The largest message the tag can hold, in bytes.
  final int maxSize;

  /// The message the tag held at discovery.
  ///
  /// Cheaper than [read] when the content is all you need, but it is a snapshot: call
  /// [read] after writing.
  final NdefMessage? cachedMessage;

  /// Reads the message currently on the tag.
  ///
  /// Returns null when the tag holds none. Both platforms report an empty tag this way, so
  /// treat it as "nothing written yet" rather than a failure.
  Future<NdefMessage?> read() async {
    final message = await nfcApi.ndefRead(_handle);
    return message == null ? null : ndefMessageFromWire(message);
  }

  /// Writes [message] to the tag.
  ///
  /// Throws when the tag is read-only, or when the message is larger than [maxSize].
  Future<void> write(NdefMessage message) => nfcApi.ndefWrite(_handle, ndefMessageToWire(message));

  /// Locks the tag read-only.
  ///
  /// Permanent and irreversible. On Android check `NdefAndroid.canMakeReadOnly` first --
  /// not every tag supports locking, and iOS offers no way to ask.
  Future<void> writeLock() => nfcApi.ndefWriteLock(_handle);
}
