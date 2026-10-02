// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChatUI",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "ChatUI", targets: ["ChatUI"]),
    ],
    dependencies: [
        .package(path: "../RouterKit"),
    ],
    targets: [
        .target(name: "ChatUI", dependencies: ["RouterKit"]),
        .testTarget(
            name: "ChatUITests",
            dependencies: ["ChatUI", .product(name: "RouterKitTesting", package: "RouterKit")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
