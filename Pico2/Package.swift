// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiLyzer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PiLyzer", targets: ["PiLyzerApp"]),
        .library(name: "PiLyzerCore", targets: ["PiLyzerCore"]),
    ],
    targets: [
        // IOKit's USB device interfaces, wrapped so Swift sees an ordinary handle.
        .target(
            name: "CPiLyzerUSB",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "PiLyzerCore",
            dependencies: ["CPiLyzerUSB"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PiLyzerApp",
            dependencies: ["PiLyzerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PiLyzerCoreTests",
            dependencies: ["PiLyzerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
