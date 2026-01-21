#import "NfcUtilPlugin.h"

#if __has_include(<nfc_util/nfc_util-Swift.h>)
#import <nfc_util/nfc_util-Swift.h>
#else
#import "nfc_util-Swift.h"
#endif

@implementation NfcUtilPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftNfcUtilPlugin registerWithRegistrar:registrar];
}
@end
