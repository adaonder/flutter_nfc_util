import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'nfc_util_method_channel.dart';

abstract class NfcUtilPlatform extends PlatformInterface {
  /// Constructs a NfcUtilPlatform.
  NfcUtilPlatform() : super(token: _token);

  static final Object _token = Object();

  static NfcUtilPlatform _instance = MethodChannelNfcUtil();

  /// The default instance of [NfcUtilPlatform] to use.
  ///
  /// Defaults to [MethodChannelNfcUtil].
  static NfcUtilPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [NfcUtilPlatform] when
  /// they register themselves.
  static set instance(NfcUtilPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
