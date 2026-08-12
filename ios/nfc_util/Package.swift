// swift-tools-version:5.9
import PackageDescription

// Sources live under Sources/nfc_util so that this package and the CocoaPods podspec can
// share one copy of the native code. A SwiftPM target cannot reach outside its package
// root, which is why they are not in ios/Classes.
let package = Package(
    name: "nfc_util",
    platforms: [
        .iOS("15.6"),
    ],
    products: [
        .library(name: "nfc-util", targets: ["nfc_util"]),
    ],
    dependencies: [
        // Staged next to this package by the Flutter tool at build time. It vends the
        // Flutter framework as a binary target, and requires Flutter 3.44.0 or newer --
        // hence the `flutter:` constraint in pubspec.yaml.
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "nfc_util",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ]
        ),
    ]
)
