// swift-tools-version: 6.2
import PackageDescription

// Lets other apps depend on RouterKit with this repository's URL:
//
//     .package(url: "https://github.com/jaichaudhry/HybridRouter", from: "0.1.0")
//
// The targets live in Packages/RouterKit, which the app and its tests use directly. Keep this
// manifest in step with Packages/RouterKit/Package.swift; CI builds both.
let package = Package(
    name: "RouterKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "RouterKit", targets: ["RouterKit"]),
        // Fake models and providers for tests and previews.
        .library(name: "RouterKitTesting", targets: ["RouterKitTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/anthropics/ClaudeForFoundationModels", from: "0.2.2"),
    ],
    targets: [
        .target(
            name: "RouterKit",
            dependencies: [
                .product(name: "ClaudeForFoundationModels", package: "ClaudeForFoundationModels"),
            ],
            path: "Packages/RouterKit/Sources/RouterKit",
            resources: [.process("Resources")]
        ),
        .target(
            name: "RouterKitTesting",
            dependencies: ["RouterKit"],
            path: "Packages/RouterKit/Sources/RouterKitTesting"
        ),
        .testTarget(
            name: "RouterKitTests",
            dependencies: ["RouterKit", "RouterKitTesting"],
            path: "Packages/RouterKit/Tests/RouterKitTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
