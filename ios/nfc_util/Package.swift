// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "nfc_util",
    platforms: [
        .iOS("15.6"),
    ],
    products: [
        .library(name: "nfc_util", targets: ["nfc_util"]),
    ],
    targets: [
        .target(
            name: "nfc_util",
            path: ".",
            sources: ["Classes"],
            resources: [
                .process("Resources"),
            ],
            publicHeadersPath: "Classes"
        ),
    ]
)
