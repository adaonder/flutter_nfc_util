import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'nfc_util_platform_interface.dart';

/// An implementation of [NfcUtilPlatform] that uses method channels.
class MethodChannelNfcUtil extends NfcUtilPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('nfc_util');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
