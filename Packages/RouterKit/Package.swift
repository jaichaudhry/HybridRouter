// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RouterKit",
    // macOS is here so tests and evals run with `swift test` on a Mac; there is no macOS app.
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "RouterKit", targets: ["RouterKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/anthropics/ClaudeForFoundationModels", from: "0.2.2"),
    ],
    targets: [
        .target(
            name: "RouterKit",
            dependencies: [
                .product(name: "ClaudeForFoundationModels", package: "ClaudeForFoundationModels"),
            ]
        ),
        .testTarget(
            name: "RouterKitTests",
            dependencies: ["RouterKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
