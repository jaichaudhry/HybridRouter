// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChatUI",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "ChatUI", targets: ["ChatUI"]),
    ],
    dependencies: [
        .package(path: "../HybridRouterKit"),
    ],
    targets: [
        .target(name: "ChatUI", dependencies: [
            "HybridRouterKit",
            .product(name: "HybridRouterKitVoice", package: "HybridRouterKit"),
        ]),
        .testTarget(
            name: "ChatUITests",
            dependencies: ["ChatUI", .product(name: "HybridRouterKitTesting", package: "HybridRouterKit")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
