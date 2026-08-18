// The nfc_util example.
//
// Every button maps to one method on the package, and the code for it sits under the
// ACTIONS banner below in the same order the buttons appear:
//
//   Build & decode NDEF -> NdefMessage.toBytes / fromBytes   (no tag, no radio)
//   Capabilities (Android) -> the probes, plus checkTagIntentSetup  (no tag, no radio)
//   Read                -> NfcUtil.startSession + Ndef.from(tag)
//   Write text          -> Ndef.write / NdefFormatable.format
//   Write poster        -> SmartPosterRecord.create
//   Inspect tag         -> every X.from(tag) the running platform offers
//   Scan many           -> invalidateAfterFirstReadIos: false
//   Barcode  (Android)  -> discoverNfcBarcodeAndroid: true
//   Emulate card (Android) -> HostCardEmulation  (changes persistent device state)
//   Observe reader (Android) -> HostCardEmulation observe mode + polling frames (API 35)
//   Wallet pass (iOS)   -> NfcUtilIos.vasSessionBegin
//
// The four imports below are the package's four public libraries; nothing else is needed.
//
// [_session] is the only place this file calls `NfcUtil.startSession`, and it spells every
// parameter the way the package spells it: delete the underscore and you have the real
// call. It and [_write] are the only two abstractions the demo invents.
//
// What makes this run is not all in Dart. The manifest entries, the Info.plist keys and the
// entitlement live in android/app/src/main/AndroidManifest.xml, ios/Runner/Info.plist and
// ios/Runner/Runner.entitlements, each commented in place.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nfc_util/android.dart' as android;
import 'package:nfc_util/ios.dart' as ios;
import 'package:nfc_util/ndef.dart';
import 'package:nfc_util/nfc_util.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'NFC Util',
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    home: const HomePage(),
  );

  /// Compact buttons, because up to nine actions have to sit above the log without
  /// crowding it. The tap target keeps its default minimum -- only the visual box shrinks.
  static ThemeData _theme(Brightness brightness) {
    final base = ThemeData(colorSchemeSeed: Colors.indigo, brightness: brightness);
    const style = ButtonStyle(
      visualDensity: VisualDensity.compact,
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
    );
    return base.copyWith(
      filledButtonTheme: const FilledButtonThemeData(style: style),
      outlinedButtonTheme: const OutlinedButtonThemeData(style: style),
    );
  }
}

/// Thrown when the tag is the problem rather than the code.
///
/// The message is written for a person, because it is what reaches the iOS system sheet.
/// Everything else that goes wrong is a bug and reaches the log instead.
class TagProblem implements Exception {
  const TagProblem(this.message);

  final String message;

  @override
  String toString() => message;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Oldest first, so an indented child line reads under the parent that wrote it.
  final _log = <({String text, bool isError})>[];

  /// A continuous scan would otherwise append for as long as it runs.
  static const int _logLimit = 300;

  NfcAvailability? _availability;
  StreamSubscription<NfcAdapterState>? _adapterState;

  /// Null while idle; otherwise the sentence the busy strip shows.
  ///
  /// One field rather than a state enum: the package does not expose a session phase, and
  /// inventing one here would teach a model that does not exist. Four places clear it --
  /// [_stopSession], the start-failure catch, [_onSessionError] once the session is over,
  /// and the body-throw path, which routes through [_stopSession].
  String? _busy;

  bool _emulating = false;
  bool _observing = false;

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
    }

    if (_isIos) {
      ios.NfcUtilIos.instance.onNdefFromBackground = (message) =>
          _write('background NDEF: ${message.records.length} records');
    }

    _checkLaunchTag();
  }

  @override
  void dispose() {
    _adapterState?.cancel();
    // registerAids changed state that survives the process being killed, the phone
    // rebooting and the app being updated, and unregisterAids is the only way back. Best
    // effort only: a hard kill still leaves the device enrolled.
    if (_emulating) unawaited(_stopCardEmulation(quiet: true));
    // Observe mode does not survive the process, but the polling-loop filter does -- it is
    // stored against the service the same way the AID group is.
    if (_observing) unawaited(_stopObserveMode(quiet: true));
    super.dispose();
  }

  Future<void> _refreshAvailability() async {
    final availability = await NfcUtil.instance.checkAvailability();
    if (mounted) setState(() => _availability = availability);
  }

  /// The two ways a tag can reach an app that was not running, one per platform.
  ///
  /// Both are read outside any session, which is why they hand back the tag's discovery
  /// snapshot rather than a live handle.
  Future<void> _checkLaunchTag() async {
    if (_isAndroid) {
      final tag = await android.NfcUtilAndroid.instance.takeInitialTag();
      if (tag != null) {
        _write('launched by tag: $tag');
        final cached = Ndef.from(tag)?.cachedMessage;
        if (cached != null) _write('  it held ${cached.records.length} records');
      }
    }

    if (_isIos) {
      final message = await ios.NfcUtilIos.instance.takeInitialNdefMessage();
      if (message != null) _write('launched by an NDEF tag holding ${message.records.length} records');
    }
  }

  void _write(String line, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _log.add((text: line, isError: isError));
      if (_log.length > _logLimit) _log.removeRange(0, _log.length - _logLimit);
    });
  }

  void _clear() => setState(_log.clear);

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _log.map((entry) => entry.text).join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Log copied')));
    }
  }

  void _setBusy(String label) {
    if (mounted) setState(() => _busy = label);
  }

  void _setIdle() {
    if (mounted) setState(() => _busy = null);
  }

  // -------------------------------------------------------------------------------------
  // THE SESSION
  // -------------------------------------------------------------------------------------

  /// The one place this example calls [NfcUtil.startSession].
  ///
  /// Every forwarded parameter is spelled the way the package spells it, so a call here is
  /// the real call with an underscore in front of it. Copy the body, not the wrapper.
  ///
  /// Do the tag I/O inside `onDiscovered`. The native handle is released as soon as that
  /// future completes, so a tag kept for a later screen fails; `tag.id`, `tag.techList` and
  /// `Ndef.from(tag)?.cachedMessage` are the parts that outlive the callback.
  ///
  /// Stopping is deliberately *not* done here. On iOS `invalidateAfterFirstReadIos` ends the
  /// session for you; on Android nothing does but an explicit `stopSession`, and hiding that
  /// difference behind one flag would hide the thing most worth seeing.
  Future<void> _session({
    required String busyLabel,
    required Future<void> Function(NfcTag tag) onDiscovered,
    Set<NfcPollingOption>? pollingOptions,
    bool skipNdefCheck = false,
    bool invalidateAfterFirstReadIos = true,
    bool discoverNfcBarcodeAndroid = false,
    String? alertMessageIos,
  }) async {
    _setBusy(busyLabel);
    try {
      await NfcUtil.instance.startSession(
        pollingOptions: pollingOptions,
        skipNdefCheck: skipNdefCheck,
        invalidateAfterFirstReadIos: invalidateAfterFirstReadIos,
        discoverNfcBarcodeAndroid: discoverNfcBarcodeAndroid,
        alertMessageIos: alertMessageIos ?? 'Hold your phone near a tag',
        onBecameActiveIos: () => _setBusy('Hold a tag to the phone'),
        onDiscovered: (tag) async {
          try {
            await onDiscovered(tag);
          } on Exception catch (e) {
            _write('failed: $e', isError: true);
            // A TagProblem was written for the person holding the phone; anything else was
            // not, so it must not reach the system sheet.
            await _stopSession(errorMessageIos: e is TagProblem ? e.message : 'Could not read this tag');
          }
        },
        onError: _onSessionError,
      );
    } on PlatformException catch (e) {
      _setIdle();
      _reportStartFailure(e);
    }
  }

  /// `stopSession` never throws and is safe to call twice. The busy label is this app's own
  /// bookkeeping, so it is cleared here rather than by the package.
  Future<void> _stopSession({String? alertMessageIos, String? errorMessageIos}) async {
    await NfcUtil.instance.stopSession(alertMessageIos: alertMessageIos, errorMessageIos: errorMessageIos);
    _setIdle();
  }

  /// [NfcError.sessionEnded] is the field that decides whether starting again is safe.
  ///
  /// Every CoreNFC failure ends the session. On Android a tag that could not be read leaves
  /// reader mode polling, and a session started on top of that one is refused.
  Future<void> _onSessionError(NfcError error) async {
    final code = error.iosCode?.name ?? error.androidCode?.name ?? 'unclassified';

    if (!error.sessionEnded) {
      _write('error, still polling [${error.source.name}/$code] ${error.message}');
      if (error.androidCode == NfcAndroidErrorCode.tagLost) {
        _write('  hold the tag still -- do not start another session');
      }
      return;
    }

    // A dismissed sheet is a decision, not a fault.
    final cancelled = error.iosCode == NfcReaderErrorCode.userCanceled;
    _write('session ended [${error.source.name}/$code] ${error.message}', isError: !cancelled);
    _setIdle();
  }

  /// The three codes a refused start can carry. They are constants rather than literals
  /// precisely so this switch can be written.
  void _reportStartFailure(PlatformException e) => _write(switch (e.code) {
    NfcErrorCodes.sessionAlreadyExists =>
      'A session is already running. Stop it first -- both platforms refuse to replace one.',
    NfcErrorCodes.unavailable => 'The platform refused: no radio, or NFC is switched off.',
    NfcErrorCodes.noActivity => 'Android has no activity attached right now.',
    _ => 'startSession failed [${e.code}] ${e.message}',
  }, isError: true);

  // -------------------------------------------------------------------------------------
  // ACTIONS
  // -------------------------------------------------------------------------------------

  /// Pure Dart: no tag, no session, no radio, so this one runs on a simulator.
  ///
  /// This is the whole NDEF wire format. It is also how a payload is built for anything
  /// else that carries NDEF, host card emulation included.
  void _codecRoundTrip() {
    _write('-- Build & decode NDEF --');

    final message = NdefMessage([
      TextRecord.create('merhaba dünya', languageCode: 'tr'),
      // create abbreviates the longest matching scheme, so 'https://' costs one byte
      // instead of eight.
      UriRecord.create(Uri.parse('https://pub.dev/packages/nfc_util')),
      MimeRecord.create('application/json', utf8.encode('{"seat":"14A"}')),
      ExternalRecord.create('example.com', 'seat', Uint8List.fromList([0x0E, 0x41])),
      SmartPosterRecord.create(
        uri: Uri.parse('https://pub.dev/packages/nfc_util'),
        title: 'nfc_util',
        action: SmartPosterAction.execute,
      ),
    ]);

    final bytes = message.toBytes();
    _write('  toBytes() -> ${bytes.length} bytes, byteLength said ${message.byteLength}');

    final decoded = NdefMessage.fromBytes(bytes);
    _write('  fromBytes(bytes) == message -> ${decoded == message}', isError: decoded != message);
    for (final record in decoded.records) {
      _write('  ${_describe(record)}');
    }
  }

  Future<void> _readTag() => _session(
    busyLabel: 'Waiting for a tag to read',
    onDiscovered: (tag) async {
      _write('-- Read --');
      _write('tag: $tag');

      final ndef = Ndef.from(tag);
      if (ndef == null) {
        _write('  holds no NDEF (or the session set skipNdefCheck)');
        await _stopSession(alertMessageIos: 'Done');
        return;
      }

      _write('  writable: ${ndef.isWritable}, capacity: ${ndef.maxSize}');

      // Discovery already fetched this, so there is no second round trip to the tag.
      // read() is only worth it when the content may have changed since.
      final message = ndef.cachedMessage;
      if (message == null) {
        _write('  nothing written yet');
      } else {
        for (final record in message.records) {
          _write('  ${_describe(record)}');
        }
      }

      await _stopSession(alertMessageIos: 'Done');
    },
  );

  Future<void> _writeText() => _session(
    busyLabel: 'Hold still while writing',
    alertMessageIos: 'Hold still while writing',
    onDiscovered: (tag) async {
      _write('-- Write text --');
      await _writeMessage(tag, NdefMessage([TextRecord.create('merhaba dünya', languageCode: 'tr')]));
      await _stopSession(alertMessageIos: 'Written');
    },
  );

  /// A smart poster is one record holding a URI, a title and an action, with a nested NDEF
  /// message as its payload. This is what a printed NFC poster carries.
  Future<void> _writeSmartPoster() => _session(
    busyLabel: 'Hold still while writing',
    alertMessageIos: 'Hold still while writing',
    onDiscovered: (tag) async {
      _write('-- Write poster --');
      await _writeMessage(
        tag,
        NdefMessage([
          SmartPosterRecord.create(
            uri: Uri.parse('https://pub.dev/packages/nfc_util'),
            title: 'nfc_util',
            action: SmartPosterAction.execute,
          ),
        ]),
      );
      await _stopSession(alertMessageIos: 'Written');
    },
  );

  /// The one write path, shared by both write actions.
  Future<void> _writeMessage(NfcTag tag, NdefMessage message) async {
    final ndef = Ndef.from(tag);

    if (ndef == null) {
      // Not "unwritable": a tag straight out of the packet holds no NDEF yet, so Ndef.from
      // returns null for it. Android prepares and writes it in one call. CoreNFC has no
      // equivalent, so this is null on iOS.
      final formatable = android.NdefFormatable.from(tag);
      if (formatable == null) {
        throw const TagProblem('This tag holds no NDEF and cannot be formatted from here.');
      }
      await formatable.format(message);
      _write('  formatted a blank tag and wrote ${message.byteLength} bytes');
      return;
    }

    if (!ndef.isWritable) throw const TagProblem('This tag is locked read-only.');
    if (message.byteLength > ndef.maxSize) {
      throw TagProblem('The message is ${message.byteLength} bytes; this tag holds ${ndef.maxSize}.');
    }

    await ndef.write(message);
    // cachedMessage is the discovery snapshot and is stale now, so this is the one place
    // read() earns its round trip.
    final written = await ndef.read();
    _write('  wrote ${message.byteLength} bytes; the tag now holds ${written?.records.length ?? 0} records');
  }

  /// Every typed view the running platform offers, tried in turn.
  ///
  /// Each line is a real `X.from(tag)`; the helper only formats the ones that matched.
  Future<void> _inspectTag() => _session(
    busyLabel: 'Waiting for a tag to inspect',
    onDiscovered: (tag) async {
      _write('-- Inspect tag --');
      _write('tag: $tag');

      if (_isAndroid) {
        _probe('NfcA', android.NfcA.from(tag), (t) async => 'atqa=${_hex(t.atqa)} sak=${t.sak}');
        _probe('NfcB', android.NfcB.from(tag), (t) async => 'appData=${_hex(t.applicationData)}');
        _probe('NfcF', android.NfcF.from(tag), (t) async => 'systemCode=${_hex(t.systemCode)}');
        _probe('NfcV', android.NfcV.from(tag), (t) async => 'dsfId=${t.dsfId} responseFlags=${t.responseFlags}');
        _probe('NdefAndroid', android.NdefAndroid.from(tag), (t) async {
          // canMakeReadOnly is the pre-check for Ndef.writeLock(), which is permanent.
          return '${t.type}, lockable: ${t.canMakeReadOnly}';
        });
        _probe('NdefFormatable', android.NdefFormatable.from(tag), (t) async => 'blank, can be formatted');

        await _probeAsync('MifareClassic', android.MifareClassic.from(tag), (t) async {
          final head = '${t.type.name}, ${t.sectorCount} sectors, ${t.size} bytes';
          // The factory default key; a personalised card will refuse it.
          final key = Uint8List.fromList(List.filled(6, 0xFF));
          final ok = await t.authenticateSectorWithKeyA(sectorIndex: 0, key: key);
          if (!ok) return '$head; sector 0 refused the default key';
          final block = await t.sectorToBlock(sectorIndex: 0);
          return '$head; block $block = ${_hex(await t.readBlock(blockIndex: block))}';
        });

        await _probeAsync(
          'MifareUltralight',
          android.MifareUltralight.from(tag),
          (t) async => '${t.type.name}, pages 0-3 = ${_hex(await t.readPages(pageOffset: 0))}',
        );

        await _probeAsync('IsoDep', android.IsoDep.from(tag), (t) async {
          // SELECT by name with no data: harmless on any card that answers APDUs, and the
          // Android counterpart of Iso7816.sendCommand below.
          final response = await t.transceive(Uint8List.fromList([0x00, 0xA4, 0x04, 0x00, 0x00]));
          return 'extended APDU: ${t.isExtendedLengthApduSupported}, SELECT -> ${_hex(response)}';
        });
      }

      if (_isIos) {
        _probe('MiFare', ios.MiFare.from(tag), (t) async => 'family ${t.family.name}');
        _probe('FeliCa', ios.FeliCa.from(tag), (t) async => 'IDm ${_hex(t.currentIDm)}');

        await _probeAsync('Iso7816', ios.Iso7816.from(tag), (t) async {
          final response = await t.sendCommand(
            instructionClass: 0x00,
            instructionCode: 0xA4,
            p1Parameter: 0x04,
            p2Parameter: 0x00,
            data: Uint8List(0),
            expectedResponseLength: 256,
          );
          return 'AID ${t.initialSelectedAID}, SELECT -> '
              '${response.statusWord.toRadixString(16)} (ok: ${response.isSuccess})';
        });

        await _probeAsync('Iso15693', ios.Iso15693.from(tag), (t) async {
          final info = await t.getSystemInfo(requestFlags: {ios.Iso15693RequestFlag.highDataRate});
          return 'IC ${t.icManufacturerCode}/${_hex(t.icSerialNumber)}, '
              '${info.totalBlocks} blocks of ${info.blockSize}';
        });

        await _probeAsync('NdefIos', ios.NdefIos.from(tag), (t) async {
          final live = await t.queryStatus();
          return '${live.status.name}, capacity ${live.capacity}';
        });
      }

      await _stopSession(alertMessageIos: 'Done');
    },
  );

  /// Reports [view] when the tag answered to it, and stays quiet when it did not.
  void _probe<T>(String name, T? view, Future<String> Function(T) describe) {
    if (view != null) unawaited(describe(view).then((text) => _write('  $name: $text')));
  }

  /// The awaited form, for probes that talk to the tag.
  Future<void> _probeAsync<T>(String name, T? view, Future<String> Function(T) describe) async {
    if (view == null) return;
    try {
      _write('  $name: ${await describe(view)}');
    } on Exception catch (e) {
      _write('  $name: matched, but the exchange failed: $e', isError: true);
    }
  }

  /// One session, many tags. iOS restarts polling only after `onDiscovered` returns.
  Future<void> _scanMany() {
    var count = 0;
    return _session(
      busyLabel: 'Scanning -- hold tags to the phone',
      alertMessageIos: 'Scan as many tags as you like',
      invalidateAfterFirstReadIos: false,
      skipNdefCheck: true,
      // Named explicitly rather than left to the default, because on iOS the default asks
      // for FeliCa too, and CoreNFC refuses to start a FeliCa session unless
      // com.apple.developer.nfc.readersession.felica.systemcodes lists the system codes.
      // The cost of naming it: this action will not discover FeliCa or ISO 15693 tags.
      pollingOptions: {NfcPollingOption.iso14443},
      onDiscovered: (tag) async {
        count++;
        _write('#$count ${tag.id == null ? "no id" : _hex(tag.id)} (ISO 14443 only)');
        _setBusy('$count tags scanned');
        if (_isIos) await ios.NfcUtilIos.instance.tagSessionSetAlertMessage('$count tags scanned');
      },
    );
  }

  /// Barcode tags are only ever discovered when the session asks for them.
  Future<void> _readBarcode() => _session(
    busyLabel: 'Waiting for a barcode tag',
    discoverNfcBarcodeAndroid: true,
    // Skips the discovery probe, so Ndef.from(tag) would return null -- which is fine here.
    skipNdefCheck: true,
    onDiscovered: (tag) async {
      _write('-- Barcode --');
      final barcode = android.NfcBarcode.from(tag);
      _write(barcode == null ? 'not a barcode tag' : 'barcode ${barcode.type.name}: ${_hex(barcode.barcode)}');
      await _stopSession();
    },
  );

  /// Apple Wallet passes rather than NFC tags. A separate session object from the reader
  /// one, with its own begin and its own invalidate.
  Future<void> _readWalletPass() async {
    if (!await ios.NfcUtilIos.instance.vasSessionReadingAvailable()) {
      _write('VAS is unavailable: it needs the pass-reading entitlement in Runner.entitlements', isError: true);
      return;
    }

    _setBusy('Hold your phone near the reader');
    try {
      await ios.NfcUtilIos.instance.vasSessionBegin(
        alertMessage: 'Hold your phone near the reader',
        configurations: const [
          // Replace with a pass type your app is entitled to read.
          ios.VasCommandConfiguration(passTypeIdentifier: 'pass.com.example.loyalty'),
        ],
        onResponse: (responses) {
          _write('-- Wallet pass --');
          for (final response in responses) {
            // vasData is empty unless the status is success, so the byte count only means
            // something on that branch.
            final ok = response.status == ios.VasResponseErrorCode.success;
            _write(
              ok ? 'pass read: ${response.vasData.length} bytes' : 'pass not read: ${response.status.name}',
              isError: !ok,
            );
          }
          unawaited(ios.NfcUtilIos.instance.vasSessionInvalidate(alertMessage: 'Done'));
          _setIdle();
        },
        onError: (error) async {
          _write('vas ended: ${error.message}', isError: error.iosCode != NfcReaderErrorCode.userCanceled);
          _setIdle();
        },
      );
    } on PlatformException catch (e) {
      _setIdle();
      _reportStartFailure(e);
    }
  }

  /// The phone answers a reader as if it were a card. Android only.
  Future<void> _startCardEmulation() async {
    final hce = android.HostCardEmulation.instance;

    if (!await hce.isSupported()) {
      _write('this device cannot emulate a card', isError: true);
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

    // This changes state that outlives the app: the registration survives the process being
    // killed, the phone rebooting and the app being updated, and unregisterAids is the only
    // way back. 'F0010203040506' is this example's placeholder -- two apps that both ship it
    // will collide, and the second registration is the one Android refuses.
    final registered = await hce.registerAids(['F0010203040506']);
    if (!registered) {
      _write('AID registration was refused -- another app probably owns it', isError: true);
      return;
    }

    _emulating = true;
    await hce.setPreferredService(true);
    _write('emulating a card: tap a reader');
  }

  /// Everything the running device says it can do, in one place. Android only, no tag.
  ///
  /// Every one of these is a capability *probe*: it answers false or null on a device too
  /// old rather than throwing, which is what lets an app decide what to offer before it
  /// offers it. The matching actions are the ones that throw `unsupported_api_level`.
  Future<void> _checkCapabilities() async {
    final nfc = android.NfcUtilAndroid.instance;
    final hce = android.HostCardEmulation.instance;

    _write('capabilities');
    _write('  secure NFC supported: ${await nfc.isSecureNfcSupported()}');
    _write('  host card emulation: ${await hce.isSupported()}');
    _write('  observe mode (API 35): ${await hce.isObserveModeSupported()}');
    _write('  tag-scan allowlist (API 36): ${await nfc.isTagIntentAppPreferenceSupported()}');

    final antenna = await nfc.getAntennaInfo();
    _write('  antenna geometry (API 34): ${antenna ?? 'not published by this device'}');

    // The two silent failures, in the order they were introduced. Neither logs anything on
    // the device itself: a tap simply does nothing.
    final setup = await nfc.checkTagIntentSetup();
    _write('  tag intents reachable: ${setup.isHealthy}');
    if (!setup.tagIntentAllowed) {
      _write('    the user has switched this app off "Launch via NFC"', isError: true);
    }
    for (final activity in setup.unguardedActivities) {
      _write('    $activity has an NFC filter but no DISPATCH_NFC_MESSAGE', isError: true);
    }
  }

  /// Watches a reader's polling loop without answering it. Android 15 and above.
  ///
  /// The order matters and is the thing worth copying: register a filter, become the
  /// preferred service, and only then switch observe mode on. Only the preferred service
  /// may change it, so doing this the other way round returns false.
  Future<void> _startObserveMode() async {
    final hce = android.HostCardEmulation.instance;

    if (!await hce.isObserveModeSupported()) {
      _write('this device cannot observe polling loops (needs Android 15)', isError: true);
      return;
    }

    hce.onPollingFrames = (frames) {
      for (final frame in frames) {
        _write('  frame ${frame.type.name}${frame.data.isEmpty ? '' : ': ${_hex(frame.data)}'}');
      }
    };

    // Not a regular expression: the platform takes hex digits first, then `*` and `?`, and
    // rejects '.*' or a bare '*' outright. '6A*' is the NFC-A poll family, which is broad
    // enough to see something on any reader and narrow enough to be a real filter -- a real
    // app names the reader it cares about, so the phone is not woken by every terminal it
    // passes.
    await hce.registerPollingLoopPatternFilter(pattern: '6A*');
    await hce.setPreferredService(true);

    if (!await hce.setObserveModeEnabled(true)) {
      _write('observe mode was refused -- this app is not the preferred service', isError: true);
      await _stopObserveMode(quiet: true);
      return;
    }

    _observing = true;
    if (mounted) setState(() {});
    _write('observing: hold the phone to a reader, nothing will be answered');
  }

  Future<void> _stopObserveMode({bool quiet = false}) async {
    final hce = android.HostCardEmulation.instance;
    await hce.setObserveModeEnabled(false);
    await hce.removePollingLoopPatternFilter('6A*');
    if (!_emulating) await hce.setPreferredService(false);
    hce.onPollingFrames = null;
    _observing = false;
    if (mounted) setState(() {});
    if (!quiet) _write('stopped observing');
  }

  Future<void> _stopCardEmulation({bool quiet = false}) async {
    final hce = android.HostCardEmulation.instance;
    await hce.setPreferredService(false);
    final removed = await hce.unregisterAids();
    hce.onApduReceived = null;
    hce.onDeactivated = null;
    _emulating = false;

    if (quiet) return;
    _write(
      removed
          ? 'unregistered the AID; the device is no longer enrolled'
          : 'unregisterAids returned false -- check Settings > Tap & pay',
      isError: !removed,
    );
  }

  /// Shows the typed record views. The build side of the same types is in [_codecRoundTrip].
  String _describe(NdefRecord record) {
    final text = TextRecord.from(record);
    if (text != null) return 'text[${text.languageCode}${text.isUtf16 ? ', utf16' : ''}]: ${text.text}';

    final uri = UriRecord.from(record);
    if (uri != null) return 'uri: ${uri.uri}';

    final poster = SmartPosterRecord.from(record);
    if (poster != null) return 'poster: ${poster.title()} -> ${poster.uri} (action ${poster.action?.name ?? 'none'})';

    final mime = MimeRecord.from(record);
    if (mime != null) return 'mime ${mime.mimeType}: ${mime.data.length} bytes';

    final external = ExternalRecord.from(record);
    if (external != null) return 'external ${external.domain}:${external.type}';

    return '${record.typeNameFormat.name}: ${record.payload.length} bytes';
  }

  static String _hex(Uint8List? bytes) =>
      bytes == null ? '(none)' : bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  // -------------------------------------------------------------------------------------
  // UI -- app plumbing, not the API
  // -------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final busy = _busy != null;
    // An action needs the radio and needs the radio free. The codec action needs neither.
    final ready = _availability == NfcAvailability.enabled && !busy;

    return Scaffold(
      appBar: AppBar(
        title: const Text('NFC Util'),
        actions: [
          IconButton(onPressed: _log.isEmpty ? null : _copyAll, icon: const Icon(Icons.copy_all_outlined)),
          IconButton(onPressed: _log.isEmpty ? null : _clear, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: Column(
        children: [
          _AvailabilityBanner(availability: _availability, onRetry: _refreshAvailability),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Grouped by what the action does to the tag, because that is the
                // distinction worth seeing before tapping: reading is free, writing is not,
                // and emulation outlives the app.
                _ActionGroup(
                  caption: 'No tag needed',
                  children: [
                    // Never gated on availability: it is pure Dart, so it is the one thing
                    // that works on a simulator or a phone with no NFC.
                    FilledButton.tonal(
                      onPressed: busy ? null : _codecRoundTrip,
                      child: const Text('Build & decode NDEF'),
                    ),
                    // Also never gated on availability: the probes answer on a phone with
                    // the radio switched off, which is exactly when you want to know what
                    // the device could do.
                    if (_isAndroid)
                      FilledButton.tonal(
                        onPressed: busy ? null : _checkCapabilities,
                        child: const Text('Capabilities'),
                      ),
                  ],
                ),
                _ActionGroup(
                  caption: 'Read',
                  children: [
                    FilledButton(onPressed: ready ? _readTag : null, child: const Text('Read')),
                    FilledButton(onPressed: ready ? _inspectTag : null, child: const Text('Inspect tag')),
                    FilledButton(onPressed: ready ? _scanMany : null, child: const Text('Scan many')),
                    if (_isAndroid) FilledButton(onPressed: ready ? _readBarcode : null, child: const Text('Barcode')),
                  ],
                ),
                _ActionGroup(
                  caption: 'Write — changes the tag',
                  children: [
                    FilledButton(onPressed: ready ? _writeText : null, child: const Text('Write text')),
                    FilledButton(onPressed: ready ? _writeSmartPoster : null, child: const Text('Write poster')),
                  ],
                ),
                if (_isAndroid)
                  _ActionGroup(
                    caption: 'Emulation — changes device state',
                    children: [
                      FilledButton(
                        onPressed: ready && !_emulating ? _startCardEmulation : null,
                        child: const Text('Emulate card'),
                      ),
                      OutlinedButton(
                        onPressed: _emulating ? () => _stopCardEmulation() : null,
                        child: const Text('Stop emulating'),
                      ),
                      // Observe mode is the opposite of emulating: the phone watches the
                      // reader instead of answering it. Separate buttons because they are
                      // separate decisions, and an app can want either without the other.
                      FilledButton(
                        onPressed: ready && !_observing ? _startObserveMode : null,
                        child: const Text('Observe reader'),
                      ),
                      OutlinedButton(
                        onPressed: _observing ? () => _stopObserveMode() : null,
                        child: const Text('Stop observing'),
                      ),
                    ],
                  ),
                if (_isIos)
                  _ActionGroup(
                    caption: 'Wallet',
                    children: [
                      FilledButton(onPressed: ready ? _readWalletPass : null, child: const Text('Wallet pass')),
                    ],
                  ),
              ],
            ),
          ),
          // Only while a session is live. Stopping one that never started says nothing, and
          // putting the control here rather than among the actions is what makes the strip
          // worth the space: on Android, where there is no system sheet, this band and the
          // dimmed buttons are the only sign the app heard the tap.
          if (busy)
            _BusyStrip(
              label: _busy!,
              onStop: () => _stopSession(alertMessageIos: 'Stopped'),
            ),
          const Divider(height: 1),
          Expanded(child: _LogView(entries: _log)),
        ],
      ),
    );
  }
}

/// One row of related actions under a caption naming what they have in common.
class _ActionGroup extends StatelessWidget {
  const _ActionGroup({required this.caption, required this.children});

  final String caption;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              caption.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.8,
              ),
            ),
          ),
          Wrap(spacing: 8, runSpacing: 8, children: children),
        ],
      ),
    );
  }
}

/// Shown only while a session is running: what the app is waiting for, and the way out.
class _BusyStrip extends StatelessWidget {
  const _BusyStrip({required this.label, required this.onStop});

  final String label;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const LinearProgressIndicator(minHeight: 2),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
            TextButton(onPressed: onStop, child: const Text('Stop session')),
          ],
        ),
      ),
    ],
  );
}

class _LogView extends StatelessWidget {
  const _LogView({required this.entries});

  final List<({String text, bool isError})> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Tap "Build & decode NDEF" to see the package work without a tag,\n'
            'or an NFC action and then hold a tag to the phone.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final errorColor = Theme.of(context).colorScheme.error;

    // reverse: true keeps the newest line in view without a ScrollController, while the
    // list itself stays oldest-first so indented lines read under their parent.
    return SelectionArea(
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[entries.length - 1 - index];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              entry.text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: entry.isError ? errorColor : null,
              ),
            ),
          );
        },
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
    final scheme = Theme.of(context).colorScheme;

    // Scheme roles rather than fixed colours, so the banner survives the dark theme.
    final (message, background, foreground) = switch (availability) {
      NfcAvailability.enabled => ('NFC is on', scheme.primaryContainer, scheme.onPrimaryContainer),
      // Only Android can tell these two apart, which is the point of checkAvailability.
      NfcAvailability.disabled => (
        'NFC is off -- turn it on in settings',
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      NfcAvailability.unsupported => (
        'No NFC radio here. "Build & decode NDEF" still works.',
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      null => ('Checking…', scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };

    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(message, style: TextStyle(color: foreground)),
          ),
          TextButton(onPressed: onRetry, child: const Text('Recheck')),
        ],
      ),
    );
  }
}
