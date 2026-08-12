import 'package:meta/meta.dart';

import 'pigeon.g.dart';

// The generated host API objects are stateless wrappers around a channel name, so one of
// each is enough for the process.
//
// They are variables rather than finals so a test can put a fake in their place: the
// generated classes are concrete, and their methods are overridable, so a subclass that
// answers without touching a channel is all a test needs. That is what makes the session
// logic reachable without a device.

/// Methods both platforms implement.
NfcHostApi nfcApi = NfcHostApi();

/// Methods only Android implements. Calling one on iOS throws.
NfcAndroidHostApi androidApi = NfcAndroidHostApi();

/// Methods only iOS implements. Calling one on Android throws.
NfcIosHostApi iosApi = NfcIosHostApi();

/// Replaces the host APIs with fakes, and returns a function that puts the real ones back.
///
/// ```dart
/// late void Function() restore;
/// setUp(() => restore = debugReplaceApis(nfc: FakeHost()));
/// tearDown(() => restore());
/// ```
@visibleForTesting
void Function() debugReplaceApis({NfcHostApi? nfc, NfcAndroidHostApi? android, NfcIosHostApi? ios}) {
  final previousNfc = nfcApi;
  final previousAndroid = androidApi;
  final previousIos = iosApi;

  if (nfc != null) nfcApi = nfc;
  if (android != null) androidApi = android;
  if (ios != null) iosApi = ios;

  return () {
    nfcApi = previousNfc;
    androidApi = previousAndroid;
    iosApi = previousIos;
  };
}
