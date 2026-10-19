// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HybridRouterKit",
    // macOS is here so tests and evals run with `swift test` on a Mac; there is no macOS app.
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "HybridRouterKit", targets: ["HybridRouterKit"]),
        // On-device speech-to-text. Separate so apps without voice don't reference microphone APIs.
        .library(name: "HybridRouterKitVoice", targets: ["HybridRouterKitVoice"]),
        // Fake models and providers for tests and previews.
        .library(name: "HybridRouterKitTesting", targets: ["HybridRouterKitTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/anthropics/ClaudeForFoundationModels", from: "0.2.2"),
    ],
    targets: [
        .target(
            name: "HybridRouterKit",
            dependencies: [
                .product(name: "ClaudeForFoundationModels", package: "ClaudeForFoundationModels"),
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "HybridRouterKitVoice",
            dependencies: ["HybridRouterKit"]
        ),
        .target(
            name: "HybridRouterKitTesting",
            dependencies: ["HybridRouterKit"]
        ),
        .testTarget(
            name: "HybridRouterKitTests",
            dependencies: ["HybridRouterKit", "HybridRouterKitTesting", "HybridRouterKitVoice"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
