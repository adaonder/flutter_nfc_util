import 'package:flutter/material.dart';

import 'nfc_util_platform_interface.dart';

class NfcUtil {
  Future<String?> getPlatformVersion() {
    return NfcUtilPlatform.instance.getPlatformVersion();
  }

  void sayHello() {
    debugPrint('Hello from sdk!');
  }
}
