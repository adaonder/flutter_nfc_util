import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_util/ios.dart';
import 'package:nfc_util/src/pigeon.g.dart';
import 'package:nfc_util/testing.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

/// A stand-in iOS host that records which ISO 15693 call it answered, and with what.
///
/// One recorder rather than a field per command. Every one of these methods does nothing but
/// marshal its arguments, so the only thing a test has to say about one is which call it
/// became and what it carried -- and saying that the same way for all twelve is what keeps a
/// slip between two adjacent commands visible, since a `fastReadMultipleBlocks` that reached
/// `extendedFastReadMultipleBlocks` would otherwise answer exactly the same blocks.
class _RecordingIosHost extends FakeNfcIosHostApi {
  String? lastCall;
  List<Object?> lastArguments = const [];

  /// The last configuration to reach the platform, already converted to the wire's seconds.
  Iso15693CommandConfigurationPigeon? lastConfiguration;

  /// What every response-flag command answers with, so a test describes the tag's side once
  /// and then picks whichever of the four commands it wants to read it through.
  Iso15693ResponsePigeon response = Iso15693ResponsePigeon(flags: const [], data: Uint8List(0));

  T _record<T>(String call, List<Object?> arguments, T result) {
    lastCall = call;
    lastArguments = arguments;
    return result;
  }

  @override
  Future<Iso15693ResponsePigeon> iso15693SendRequest(
    String handle,
    int flags,
    int commandCode,
    Uint8List? data,
  ) async => _record('sendRequest', [handle, flags, commandCode, data], response);

  @override
  Future<List<Uint8List>> iso15693FastReadMultipleBlocks(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
  ) async => _record('fastReadMultipleBlocks', [handle, flags, blockNumber, numberOfBlocks], _numbered(numberOfBlocks));

  @override
  Future<List<Uint8List>> iso15693ExtendedFastReadMultipleBlocks(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
  ) async => _record('extendedFastReadMultipleBlocks', [
    handle,
    flags,
    blockNumber,
    numberOfBlocks,
  ], _numbered(numberOfBlocks));

  @override
  Future<void> iso15693ExtendedWriteMultipleBlocks(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
    List<Uint8List> dataBlocks,
  ) async => _record('extendedWriteMultipleBlocks', [handle, flags, blockNumber, numberOfBlocks, dataBlocks], null);

  @override
  Future<List<int>> iso15693ExtendedGetMultipleBlockSecurityStatus(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int blockNumber,
    int numberOfBlocks,
  ) async => _record('extendedGetMultipleBlockSecurityStatus', [
    handle,
    flags,
    blockNumber,
    numberOfBlocks,
  ], List.generate(numberOfBlocks, (index) => index));

  @override
  Future<Iso15693ResponsePigeon> iso15693Authenticate(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int cryptoSuiteIdentifier,
    Uint8List message,
  ) async => _record('authenticate', [handle, flags, cryptoSuiteIdentifier, message], response);

  @override
  Future<Iso15693ResponsePigeon> iso15693KeyUpdate(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int keyIdentifier,
    Uint8List message,
  ) async => _record('keyUpdate', [handle, flags, keyIdentifier, message], response);

  @override
  Future<void> iso15693Challenge(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
    int cryptoSuiteIdentifier,
    Uint8List message,
  ) async => _record('challenge', [handle, flags, cryptoSuiteIdentifier, message], null);

  @override
  Future<Iso15693ResponsePigeon> iso15693ReadBuffer(String handle, List<Iso15693RequestFlagPigeon> flags) async =>
      _record('readBuffer', [handle, flags], response);

  @override
  Future<Iso15693SystemInfoPigeon> iso15693GetSystemInfoAndUid(
    String handle,
    List<Iso15693RequestFlagPigeon> flags,
  ) async => _record('getSystemInfoAndUid', [handle, flags], _uidSystemInfo);

  @override
  Future<List<Uint8List>> iso15693ReadMultipleBlocksWithConfiguration(
    String handle,
    int blockNumber,
    int numberOfBlocks,
    int chunkSize,
    Iso15693CommandConfigurationPigeon configuration,
  ) async {
    lastConfiguration = configuration;
    return _record('readMultipleBlocksWithConfiguration', [
      handle,
      blockNumber,
      numberOfBlocks,
      chunkSize,
    ], _numbered(numberOfBlocks));
  }

  @override
  Future<Uint8List> iso15693CustomCommandWithConfiguration(
    String handle,
    int manufacturerCode,
    int customCommandCode,
    Uint8List customRequestParameters,
    Iso15693CommandConfigurationPigeon configuration,
  ) async {
    lastConfiguration = configuration;
    return _record('customCommandWithConfiguration', [
      handle,
      manufacturerCode,
      customCommandCode,
      customRequestParameters,
    ], bytes([0xDE, 0xAD]));
  }
}

/// Blocks that say which one they are, so a test can tell an answer that kept the platform's
/// order from one that was rebuilt in some other.
List<Uint8List> _numbered(int count) => List.generate(count, (index) => Uint8List.fromList(List.filled(4, index)));

/// A tag that reported its UID, which is the whole difference between the two
/// system-information commands.
Iso15693SystemInfoPigeon get _uidSystemInfo => Iso15693SystemInfoPigeon(
  applicationFamilyIdentifier: 0x12,
  blockSize: 4,
  dataStorageFormatIdentifier: 0x34,
  icReference: 0x56,
  totalBlocks: 64,
  uid: bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0xE0]),
);

void main() {
  late _RecordingIosHost host;
  late Iso15693 tag;
  late void Function() restore;

  setUp(() {
    host = _RecordingIosHost();
    restore = debugReplaceApis(ios: host);
    tag = Iso15693.from(fakeNfcTag(techs: [FakeTech.iso15693()]))!;
  });

  tearDown(() => restore());

  group('commands that carry a request flag set', () {
    test('fastReadMultipleBlocks asks for the range it was given', () async {
      final blocks = await tag.fastReadMultipleBlocks(
        requestFlags: {Iso15693RequestFlag.highDataRate},
        blockNumber: 4,
        numberOfBlocks: 3,
      );

      expect(host.lastCall, 'fastReadMultipleBlocks');
      expect(host.lastArguments, [
        'fake-tag',
        [Iso15693RequestFlagPigeon.highDataRate],
        4,
        3,
      ]);
      expect(blocks, _numbered(3));
    });

    test('extendedFastReadMultipleBlocks is a different command, not the same one twice', () async {
      // The two differ only in how wide a block number they can address, which makes them
      // the likeliest pair in this class to be wired to each other by accident.
      await tag.extendedFastReadMultipleBlocks(
        requestFlags: {Iso15693RequestFlag.address},
        blockNumber: 300,
        numberOfBlocks: 2,
      );

      expect(host.lastCall, 'extendedFastReadMultipleBlocks');
      expect(host.lastArguments, [
        'fake-tag',
        [Iso15693RequestFlagPigeon.address],
        300,
        2,
      ]);
    });

    test('extendedWriteMultipleBlocks sends the blocks in the order they were given', () async {
      final blocks = [
        bytes([0x0A, 0x0B, 0x0C, 0x0D]),
        bytes([0x01, 0x02, 0x03, 0x04]),
      ];

      await tag.extendedWriteMultipleBlocks(
        requestFlags: {Iso15693RequestFlag.option},
        blockNumber: 512,
        numberOfBlocks: 2,
        dataBlocks: blocks,
      );

      expect(host.lastCall, 'extendedWriteMultipleBlocks');
      expect(host.lastArguments, [
        'fake-tag',
        [Iso15693RequestFlagPigeon.option],
        512,
        2,
        blocks,
      ]);
    });

    test('extendedGetMultipleBlockSecurityStatus answers one status per block', () async {
      final status = await tag.extendedGetMultipleBlockSecurityStatus(
        requestFlags: {},
        blockNumber: 260,
        numberOfBlocks: 4,
      );

      expect(host.lastCall, 'extendedGetMultipleBlockSecurityStatus');
      expect(host.lastArguments, ['fake-tag', <Iso15693RequestFlagPigeon>[], 260, 4]);
      expect(status, [0, 1, 2, 3], reason: 'the entries pair up with the blocks asked for, in order');
    });

    test('every request flag reaches the platform as its own constant', () async {
      const pairs = <(Iso15693RequestFlag, Iso15693RequestFlagPigeon)>[
        (Iso15693RequestFlag.address, Iso15693RequestFlagPigeon.address),
        (Iso15693RequestFlag.dualSubCarriers, Iso15693RequestFlagPigeon.dualSubCarriers),
        (Iso15693RequestFlag.highDataRate, Iso15693RequestFlagPigeon.highDataRate),
        (Iso15693RequestFlag.option, Iso15693RequestFlagPigeon.option),
        (Iso15693RequestFlag.protocolExtension, Iso15693RequestFlagPigeon.protocolExtension),
        (Iso15693RequestFlag.select, Iso15693RequestFlagPigeon.select),
      ];

      // Sent one at a time rather than as one set of six: a set carrying all of them still
      // arrives complete when two of the mappings are swapped, and a swapped flag is a
      // different request that the tag answers rather than refuses.
      expect(pairs.map((pair) => pair.$1), unorderedEquals(Iso15693RequestFlag.values));

      for (final (flag, wire) in pairs) {
        await tag.readBuffer(requestFlags: {flag});
        expect(host.lastArguments[1], [wire], reason: flag.name);
      }
    });

    test('challenge takes the crypto suite and the message untouched', () async {
      // It answers nothing of its own -- readBuffer collects what it computed -- so the
      // arguments are the entire contract.
      await tag.challenge(
        requestFlags: {Iso15693RequestFlag.highDataRate},
        cryptoSuiteIdentifier: 0x01,
        message: bytes([0xAA, 0xBB]),
      );

      expect(host.lastCall, 'challenge');
      expect(host.lastArguments, [
        'fake-tag',
        [Iso15693RequestFlagPigeon.highDataRate],
        0x01,
        bytes([0xAA, 0xBB]),
      ]);
    });

    test('authenticate and keyUpdate name their own identifier', () async {
      // Both take a byte between the flags and the message, and they are not the same byte:
      // one picks the crypto suite, the other picks which key is being replaced.
      await tag.authenticate(requestFlags: {}, cryptoSuiteIdentifier: 0x02, message: bytes([0x01]));
      expect(host.lastCall, 'authenticate');
      expect(host.lastArguments[2], 0x02);

      await tag.keyUpdate(requestFlags: {}, keyIdentifier: 0x07, message: bytes([0x02]));
      expect(host.lastCall, 'keyUpdate');
      expect(host.lastArguments[2], 0x07);
    });
  });

  group('sendRequest', () {
    test('passes the flag byte through as a byte', () async {
      // The point of the method: bit 8 is command-specific and no Iso15693RequestFlag names
      // it, so a set could not express this request at all.
      final response = await tag.sendRequest(requestFlags: 0x82, commandCode: 0x35, data: bytes([0x01, 0x02]));

      expect(host.lastCall, 'sendRequest');
      expect(host.lastArguments, [
        'fake-tag',
        0x82,
        0x35,
        bytes([0x01, 0x02]),
      ]);
      expect(response.data, isEmpty);
    });

    test('a command that takes no data sends none, rather than an empty frame', () async {
      // Null and empty are different on the wire: one is a request with no data field, the
      // other is a data field of length zero.
      await tag.sendRequest(requestFlags: 0x02, commandCode: 0x3A);

      expect(host.lastArguments, ['fake-tag', 0x02, 0x3A, null]);
    });
  });

  group('the response flag a tag answers with', () {
    // The four commands CoreNFC hands the raw flag byte to, rather than reading it itself.
    final readers = <String, Future<Iso15693Response> Function(Iso15693 tag)>{
      'sendRequest': (tag) => tag.sendRequest(requestFlags: 0x02, commandCode: 0x3A),
      'authenticate': (tag) => tag.authenticate(requestFlags: {}, cryptoSuiteIdentifier: 0, message: Uint8List(0)),
      'keyUpdate': (tag) => tag.keyUpdate(requestFlags: {}, keyIdentifier: 0, message: Uint8List(0)),
      'readBuffer': (tag) => tag.readBuffer(requestFlags: {}),
    };

    test('every bit CoreNFC names has a name on this side', () async {
      const pairs = <(Iso15693ResponseFlagPigeon, Iso15693ResponseFlag)>[
        (Iso15693ResponseFlagPigeon.error, Iso15693ResponseFlag.error),
        (Iso15693ResponseFlagPigeon.responseBufferValid, Iso15693ResponseFlag.responseBufferValid),
        (Iso15693ResponseFlagPigeon.finalResponse, Iso15693ResponseFlag.finalResponse),
        (Iso15693ResponseFlagPigeon.protocolExtension, Iso15693ResponseFlag.protocolExtension),
        (Iso15693ResponseFlagPigeon.blockSecurityStatusBit5, Iso15693ResponseFlag.blockSecurityStatusBit5),
        (Iso15693ResponseFlagPigeon.blockSecurityStatusBit6, Iso15693ResponseFlag.blockSecurityStatusBit6),
        (Iso15693ResponseFlagPigeon.waitTimeExtension, Iso15693ResponseFlag.waitTimeExtension),
      ];

      // The mapper is an exhaustive switch, so a value added to either side fails the build
      // rather than a test. What is left for a test is the pairing itself: two bits swapped
      // compile perfectly and report the opposite of what the tag said.
      expect(pairs.map((pair) => pair.$1), unorderedEquals(Iso15693ResponseFlagPigeon.values));

      for (final (wire, expected) in pairs) {
        host.response = Iso15693ResponsePigeon(flags: [wire], data: Uint8List(0));
        expect((await tag.readBuffer(requestFlags: {})).flags, {expected});
      }
    });

    test('all four commands that report one decode it the same way', () async {
      host.response = Iso15693ResponsePigeon(
        flags: [Iso15693ResponseFlagPigeon.finalResponse, Iso15693ResponseFlagPigeon.responseBufferValid],
        data: bytes([0x5A]),
      );

      for (final entry in readers.entries) {
        final response = await entry.value(tag);
        expect(
          response.flags,
          {Iso15693ResponseFlag.finalResponse, Iso15693ResponseFlag.responseBufferValid},
          reason: entry.key,
        );
        expect(response.data, bytes([0x5A]), reason: entry.key);
      }
    });

    test('a rejection arrives as a flag and a code, not as a throw', () async {
      // The tag answering "no" is an answer. Turning it into an exception would hide the
      // ISO 15693-3 error code, which is the only thing that says why.
      host.response = Iso15693ResponsePigeon(flags: [Iso15693ResponseFlagPigeon.error], data: bytes([0x0F]));

      final response = await tag.sendRequest(requestFlags: 0x02, commandCode: 0x35);

      expect(response.flags, contains(Iso15693ResponseFlag.error));
      expect(response.data, bytes([0x0F]));
    });

    test('a tag with nothing to report answers an empty set rather than a null one', () async {
      expect((await tag.readBuffer(requestFlags: {})).flags, isEmpty);
    });
  });

  group('Iso15693CommandConfiguration', () {
    test('a sub-second retry interval survives as a fraction of a second', () async {
      // CoreNFC counts this in seconds as a double, and every interval worth setting is
      // shorter than one -- rounding to whole seconds would turn 250ms into no wait at all.
      await tag.readMultipleBlocksWithConfiguration(
        blockNumber: 0,
        numberOfBlocks: 2,
        chunkSize: 1,
        configuration: const Iso15693CommandConfiguration(
          maximumRetries: 3,
          retryInterval: Duration(milliseconds: 250),
        ),
      );

      expect(host.lastCall, 'readMultipleBlocksWithConfiguration');
      expect(host.lastArguments, ['fake-tag', 0, 2, 1]);
      expect(host.lastConfiguration!.maximumRetries, 3);
      expect(host.lastConfiguration!.retryIntervalSeconds, 0.25);
    });

    test('the default interval is no wait at all', () async {
      await tag.readMultipleBlocksWithConfiguration(
        blockNumber: 0,
        numberOfBlocks: 1,
        chunkSize: 1,
        configuration: const Iso15693CommandConfiguration(maximumRetries: 0),
      );

      expect(host.lastConfiguration!.retryIntervalSeconds, 0.0);
    });

    test('customCommandWithConfiguration carries a configuration of its own', () async {
      final payload = await tag.customCommandWithConfiguration(
        manufacturerCode: 0x04,
        customCommandCode: 0xA0,
        customRequestParameters: bytes([0x01]),
        configuration: const Iso15693CommandConfiguration(maximumRetries: 1, retryInterval: Duration(seconds: 2)),
      );

      expect(host.lastCall, 'customCommandWithConfiguration');
      expect(host.lastArguments, [
        'fake-tag',
        0x04,
        0xA0,
        bytes([0x01]),
      ]);
      expect(host.lastConfiguration!.retryIntervalSeconds, 2.0);
      expect(payload, bytes([0xDE, 0xAD]));
    });

    test('the chunk size reaches the platform unchanged, beside the block count', () async {
      // CoreNFC cuts the range into requests of this many blocks; the number of blocks and
      // the chunk size are separate arguments and swapping them reads as a working call.
      final blocks = await tag.readMultipleBlocksWithConfiguration(
        blockNumber: 8,
        numberOfBlocks: 6,
        chunkSize: 2,
        configuration: const Iso15693CommandConfiguration(maximumRetries: 0),
      );

      expect(host.lastArguments, ['fake-tag', 8, 6, 2]);
      expect(blocks, hasLength(6));
    });
  });

  group('system information', () {
    test('getSystemInfoAndUid reports the UID the tag sent with the rest', () async {
      final info = await tag.getSystemInfoAndUid(requestFlags: {Iso15693RequestFlag.highDataRate});

      expect(host.lastCall, 'getSystemInfoAndUid');
      expect(host.lastArguments, [
        'fake-tag',
        [Iso15693RequestFlagPigeon.highDataRate],
      ]);
      expect(info.uid, bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0xE0]));
      expect(info.applicationFamilyIdentifier, 0x12);
      expect(info.dataStorageFormatIdentifier, 0x34);
      expect(info.icReference, 0x56);
      expect(info.blockSize, 4);
      expect(info.totalBlocks, 64);
    });

    test('the deprecated getSystemInfo still answers, with no UID to report', () async {
      // Deprecating it did not remove it: an app that has not migrated yet keeps working,
      // and the selector behind it never reported a UID in the first place.
      // ignore: deprecated_member_use_from_same_package
      final info = await tag.getSystemInfo(requestFlags: {});

      expect(info.uid, isNull);
      expect(info.blockSize, 4);
      expect(info.totalBlocks, 64);
    });
  });
}
