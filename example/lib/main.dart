import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nfc_util/android.dart' as android;
import 'package:nfc_util/ios.dart' as ios;
import 'package:nfc_util/ndef.dart';
import 'package:nfc_util/nfc_util.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'nfc_util',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _log = <String>[];
  NfcAvailability? _availability;
  StreamSubscription<NfcAdapterState>? _adapterState;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;
  bool get _isIos => !kIsWeb && Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _refreshAvailability();

    if (_isAndroid) {
      _adapterState = android.NfcUtilAndroid.instance.onAdapterStateChanged.listen((state) {
        _write('adapter: ${state.name}');
        _refreshAvailability();
      });
      // A tag can launch the app; see the README for the manifest this needs.
      android.NfcUtilAndroid.instance.onTagFromIntent = (tag) async => _write('intent tag: $tag');
      _checkInitialTag();
    }

    if (_isIos) {
      ios.NfcUtilIos.instance.onNdefFromBackground = (message) =>
          _write('background NDEF: ${message.records.length} records');
    }
  }

  @override
  void dispose() {
    _adapterState?.cancel();
    super.dispose();
  }

  Future<void> _refreshAvailability() async {
    final availability = await NfcUtil.instance.checkAvailability();
    if (mounted) setState(() => _availability = availability);
  }

  Future<void> _checkInitialTag() async {
    final tag = await android.NfcUtilAndroid.instance.takeInitialTag();
    if (tag != null) _write('app was launched by tag: $tag');
  }

  void _write(String line) {
    if (!mounted) return;
    setState(() => _log.insert(0, line));
  }

  void _clear() => setState(_log.clear);

  /// Runs [body] inside a session, reporting whatever it throws instead of losing it.
  Future<void> _session(Future<void> Function(NfcTag tag) body, {String? alertMessage}) async {
    try {
      await NfcUtil.instance.startSession(
        alertMessageIos: alertMessage ?? 'Hold your phone near a tag',
        onDiscovered: (tag) async {
          try {
            await body(tag);
            await NfcUtil.instance.stopSession(alertMessageIos: 'Done');
          } on Object catch (e) {
            _write('failed: $e');
            await NfcUtil.instance.stopSession(errorMessageIos: '$e');
          }
        },
        // Both platforms raise this now; in 2.x only iOS did.
        onError: (error) async => _write('session ended: $error'),
      );
    } on Object catch (e) {
      _write('could not start: $e');
    }
  }

  // -------------------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------------------

  Future<void> _readTag() => _session((tag) async {
    _write('tag: $tag');

    final ndef = Ndef.from(tag);
    if (ndef == null) {
      _write('  not an NDEF tag');
      return;
    }

    _write('  writable: ${ndef.isWritable}, capacity: ${ndef.maxSize}');
    final message = await ndef.read();
    if (message == null) {
      _write('  nothing written yet');
      return;
    }

    for (final record in message.records) {
      _write('  ${_describe(record)}');
    }
  });

  /// Shows the typed record views: each one both builds and parses.
  String _describe(NdefRecord record) {
    final text = TextRecord.from(record);
    if (text != null) return 'text[${text.languageCode}]: ${text.text}';

    final uri = UriRecord.from(record);
    if (uri != null) return 'uri: ${uri.uri}';

    final poster = SmartPosterRecord.from(record);
    if (poster != null) return 'poster: ${poster.title()} -> ${poster.uri}';

    final mime = MimeRecord.from(record);
    if (mime != null) return 'mime ${mime.mimeType}: ${mime.data.length} bytes';

    final external = ExternalRecord.from(record);
    if (external != null) return 'external ${external.domain}:${external.type}';

    return '${record.typeNameFormat.name}: ${record.payload.length} bytes';
  }

  Future<void> _writeText() => _session((tag) async {
    final ndef = Ndef.from(tag);
    if (ndef == null || !ndef.isWritable) {
      throw 'Tag is not NDEF writable';
    }
    await ndef.write(NdefMessage([TextRecord.create('merhaba dünya', languageCode: 'tr')]));
    _write('wrote a text record');
  }, alertMessage: 'Hold still while writing');

  /// A smart poster is one record holding a URI, a title and an action, with a nested NDEF
  /// message as its payload. This is what a printed NFC poster carries.
  Future<void> _writeSmartPoster() => _session((tag) async {
    final ndef = Ndef.from(tag);
    if (ndef == null || !ndef.isWritable) throw 'Tag is not NDEF writable';

    final message = NdefMessage([
      SmartPosterRecord.create(
        uri: Uri.parse('https://pub.dev/packages/nfc_util'),
        title: 'nfc_util',
        action: SmartPosterAction.execute,
      ),
    ]);

    if (message.byteLength > ndef.maxSize) {
      throw 'Message is ${message.byteLength} bytes, tag holds ${ndef.maxSize}';
    }
    await ndef.write(message);
    _write('wrote a smart poster (${message.byteLength} bytes)');
  });

  /// Exercises the platform tag classes on whichever platform is running.
  Future<void> _tagIo() => _session((tag) async {
    _write('tag: $tag');

    if (_isAndroid) {
      final classic = android.MifareClassic.from(tag);
      if (classic != null) {
        _write('  MifareClassic ${classic.type.name}, ${classic.sectorCount} sectors, ${classic.size} bytes');
        // The factory default key; a personalised card will refuse it.
        final key = Uint8List.fromList(List.filled(6, 0xFF));
        final ok = await classic.authenticateSectorWithKeyA(sectorIndex: 0, key: key);
        _write('  sector 0 auth with default key: $ok');
        if (ok) {
          final block = await classic.sectorToBlock(sectorIndex: 0);
          _write('  block $block: ${_hex(await classic.readBlock(blockIndex: block))}');
        }
      }

      final ultralight = android.MifareUltralight.from(tag);
      if (ultralight != null) {
        _write('  MifareUltralight ${ultralight.type.name}');
        _write('  pages 0-3: ${_hex(await ultralight.readPages(pageOffset: 0))}');
      }

      final nfcA = android.NfcA.from(tag);
      if (nfcA != null) {
        _write('  NfcA atqa=${_hex(nfcA.atqa)} sak=${nfcA.sak}');
        _write('  live max transceive: ${await nfcA.getMaxTransceiveLength()}');
      }

      final isoDep = android.IsoDep.from(tag);
      if (isoDep != null) {
        _write('  IsoDep, extended APDU: ${isoDep.isExtendedLengthApduSupported}');
      }
    }

    if (_isIos) {
      final card = ios.Iso7816.from(tag);
      if (card != null) {
        _write('  Iso7816, selected AID ${card.initialSelectedAID}');
        // SELECT by name, no data: harmless on any card that answers APDUs.
        final response = await card.sendCommand(
          instructionClass: 0x00,
          instructionCode: 0xA4,
          p1Parameter: 0x04,
          p2Parameter: 0x00,
          data: Uint8List(0),
          expectedResponseLength: 256,
        );
        _write('  SELECT -> ${response.statusWord.toRadixString(16)} (ok: ${response.isSuccess})');
      }

      final mifare = ios.MiFare.from(tag);
      if (mifare != null) _write('  MiFare family ${mifare.family.name}');

      final felica = ios.FeliCa.from(tag);
      if (felica != null) _write('  FeliCa IDm ${_hex(felica.currentIDm)}');

      final ndefIos = ios.NdefIos.from(tag);
      if (ndefIos != null) {
        final live = await ndefIos.queryStatus();
        _write('  live NDEF status: ${live.status.name}, capacity ${live.capacity}');
      }
    }
  });

  /// Barcode tags are only ever discovered when the session asks for them.
  Future<void> _readBarcode() async {
    try {
      await NfcUtil.instance.startSession(
        discoverNfcBarcodeAndroid: true,
        skipNdefCheck: true,
        onDiscovered: (tag) async {
          final barcode = android.NfcBarcode.from(tag);
          _write(barcode == null ? 'not a barcode tag' : 'barcode ${barcode.type.name}: ${_hex(barcode.barcode)}');
          await NfcUtil.instance.stopSession();
        },
        onError: (error) async => _write('session ended: $error'),
      );
    } on Object catch (e) {
      _write('could not start: $e');
    }
  }

  /// One session, many tags: iOS restarts polling only after this callback returns.
  Future<void> _continuousScan() async {
    var count = 0;
    try {
      await NfcUtil.instance.startSession(
        invalidateAfterFirstReadIos: false,
        alertMessageIos: 'Scan as many tags as you like',
        skipNdefCheck: true,
        onDiscovered: (tag) async {
          count++;
          _write('#$count ${tag.id == null ? "no id" : _hex(tag.id)}');
          if (_isIos) await ios.NfcUtilIos.instance.tagSessionSetAlertMessage('$count tags scanned');
        },
        onError: (error) async => _write('session ended: $error'),
      );
    } on Object catch (e) {
      _write('could not start: $e');
    }
  }

  /// Apple Wallet passes rather than NFC tags. iOS only.
  Future<void> _readWalletPass() async {
    try {
      await ios.NfcUtilIos.instance.vasSessionBegin(
        alertMessage: 'Hold your phone near the reader',
        configurations: const [
          // Replace with a pass type your app is entitled to read.
          ios.VasCommandConfiguration(passTypeIdentifier: 'pass.com.example.loyalty'),
        ],
        onResponse: (responses) {
          for (final response in responses) {
            _write('pass ${response.status.name}: ${response.vasData.length} bytes');
          }
          ios.NfcUtilIos.instance.vasSessionInvalidate(alertMessage: 'Done');
        },
        onError: (error) async => _write('vas ended: $error'),
      );
    } on Object catch (e) {
      _write('could not start: $e');
    }
  }

  /// The phone answers a reader as if it were a card. Android only.
  Future<void> _startCardEmulation() async {
    final hce = android.HostCardEmulation.instance;

    if (!await hce.isSupported()) {
      _write('this device cannot emulate a card');
      return;
    }

    hce.onApduReceived = (apdu) {
      _write('reader sent ${_hex(apdu)}');
      // A real card would parse the APDU; this answers SELECT with success and everything
      // else with "instruction not supported".
      final isSelect = apdu.length > 1 && apdu[1] == 0xA4;
      hce.respond(Uint8List.fromList(isSelect ? [0x90, 0x00] : [0x6D, 0x00]));
    };
    hce.onDeactivated = (reason) => _write('reader gone (reason $reason)');

    final registered = await hce.registerAids(['F0010203040506']);
    await hce.setPreferredService(true);
    _write(registered ? 'emulating a card: tap a reader' : 'AID registration was refused');
  }

  Future<void> _stopCardEmulation() async {
    final hce = android.HostCardEmulation.instance;
    await hce.setPreferredService(false);
    await hce.unregisterAids();
    hce.onApduReceived = null;
    _write('card emulation stopped');
  }

  static String _hex(Uint8List? bytes) =>
      bytes == null ? '(none)' : bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  // -------------------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final availability = _availability;
    final ready = availability == NfcAvailability.enabled;

    return Scaffold(
      appBar: AppBar(
        title: const Text('nfc_util'),
        actions: [IconButton(onPressed: _clear, icon: const Icon(Icons.delete_outline))],
      ),
      body: Column(
        children: [
          _AvailabilityBanner(availability: availability, onRetry: _refreshAvailability),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              children: [
                FilledButton(onPressed: ready ? _readTag : null, child: const Text('Read')),
                FilledButton(onPressed: ready ? _writeText : null, child: const Text('Write text')),
                FilledButton(onPressed: ready ? _writeSmartPoster : null, child: const Text('Write poster')),
                FilledButton(onPressed: ready ? _tagIo : null, child: const Text('Tag I/O')),
                FilledButton(onPressed: ready ? _continuousScan : null, child: const Text('Continuous')),
                if (_isAndroid) ...[
                  FilledButton(onPressed: ready ? _readBarcode : null, child: const Text('Barcode')),
                  FilledButton(onPressed: ready ? _startCardEmulation : null, child: const Text('Emulate card')),
                  OutlinedButton(onPressed: ready ? _stopCardEmulation : null, child: const Text('Stop emulating')),
                ],
                if (_isIos) FilledButton(onPressed: ready ? _readWalletPass : null, child: const Text('Wallet pass')),
                OutlinedButton(
                  onPressed: () => NfcUtil.instance.stopSession(),
                  child: const Text('Stop session'),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: _log.isEmpty
                ? const Center(child: Text('Tap an action, then hold a tag to the phone.'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _log.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: SelectableText(
                        _log[index],
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _AvailabilityBanner extends StatelessWidget {
  const _AvailabilityBanner({required this.availability, required this.onRetry});

  final NfcAvailability? availability;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (message, color) = switch (availability) {
      NfcAvailability.enabled => ('NFC is on', Colors.green),
      // Only Android can tell these two apart, which is the point of checkAvailability.
      NfcAvailability.disabled => ('NFC is off — turn it on in settings', Colors.orange),
      NfcAvailability.unsupported => ('This device has no NFC', Colors.red),
      null => ('Checking…', Colors.grey),
    };

    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.12),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(child: Text(message, style: TextStyle(color: color.shade900))),
          TextButton(onPressed: onRetry, child: const Text('Recheck')),
        ],
      ),
    );
  }
}
