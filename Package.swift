// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DPScope",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DPScope", targets: ["DPScopeApp"]),
        .library(name: "DPScopeCore", targets: ["DPScopeCore"]),
    ],
    targets: [
        .target(
            name: "DPScopeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DPScopeApp",
            dependencies: ["DPScopeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DPScopeCoreTests",
            dependencies: ["DPScopeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
