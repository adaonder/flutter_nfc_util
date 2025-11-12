import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_util/nfc_util.dart';
import 'package:nfc_util/nfc_util_platform_interface.dart';
import 'package:nfc_util/nfc_util_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockNfcUtilPlatform
    with MockPlatformInterfaceMixin
    implements NfcUtilPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final NfcUtilPlatform initialPlatform = NfcUtilPlatform.instance;

  test('$MethodChannelNfcUtil is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelNfcUtil>());
  });

  test('getPlatformVersion', () async {
    NfcUtil nfcUtilPlugin = NfcUtil();
    MockNfcUtilPlatform fakePlatform = MockNfcUtilPlatform();
    NfcUtilPlatform.instance = fakePlatform;

    expect(await nfcUtilPlugin.getPlatformVersion(), '42');
  });
}
