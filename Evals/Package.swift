// swift-tools-version: 6.2
import PackageDescription

// Routing evals (SPEC §12): routing_cases.json run through the real router.
let package = Package(
    name: "Evals",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    dependencies: [
        .package(path: "../Packages/RouterKit"),
    ],
    targets: [
        .testTarget(
            name: "RoutingEvalTests",
            dependencies: [
                .product(name: "RouterKit", package: "RouterKit"),
                .product(name: "RouterKitTesting", package: "RouterKit"),
            ],
            path: ".",
            exclude: ["Package.swift"],
            sources: ["RoutingEvalTests.swift"],
            resources: [.copy("routing_cases.json")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
