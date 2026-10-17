// swift-tools-version: 6.2
import PackageDescription

// Lets other apps depend on HybridRouterKit with this repository's URL:
//
//     .package(url: "https://github.com/jaichaudhry/HybridRouter", from: "0.4.0")
//
// The targets live in Packages/HybridRouterKit, which the app and its tests use directly. Keep this
// manifest in step with Packages/HybridRouterKit/Package.swift; CI builds both.
let package = Package(
    name: "HybridRouterKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "HybridRouterKit", targets: ["HybridRouterKit"]),
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
            path: "Packages/HybridRouterKit/Sources/HybridRouterKit",
            resources: [.process("Resources")]
        ),
        .target(
            name: "HybridRouterKitTesting",
            dependencies: ["HybridRouterKit"],
            path: "Packages/HybridRouterKit/Sources/HybridRouterKitTesting"
        ),
        .testTarget(
            name: "HybridRouterKitTests",
            dependencies: ["HybridRouterKit", "HybridRouterKitTesting"],
            path: "Packages/HybridRouterKit/Tests/HybridRouterKitTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
