// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS("14.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeNotch",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClaudeNotchTests",
            dependencies: ["ClaudeNotch"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
