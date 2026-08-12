#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint nfc_util.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'nfc_util'
  s.version          = '3.0.1'
  s.summary          = 'A Flutter plugin providing access to NFC features on Android and iOS.'
  s.description      = <<-DESC
A Flutter plugin providing access to NFC features on Android and iOS, covering NDEF plus the
FeliCa, ISO7816, ISO15693 and MiFare tag technologies.
                       DESC
  s.homepage         = 'https://github.com/adaonder/flutter_nfc_util'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Önder ADA' => 'ondertel@gmail.com' }
  s.source           = { :path => '.' }
  # Shared with Package.swift; see the note there for why the sources live under
  # nfc_util/Sources rather than Classes/.
  s.source_files = 'nfc_util/Sources/nfc_util/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '15.6'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'

  # Keep this in sync with Package.swift, which already processes Resources/. Without it,
  # CocoaPods builds ship without the privacy manifest while SwiftPM builds include it.
  # See https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  s.resource_bundles = {'nfc_util_privacy' => ['nfc_util/Sources/nfc_util/PrivacyInfo.xcprivacy']}
end
