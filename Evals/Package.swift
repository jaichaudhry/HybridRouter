// swift-tools-version: 6.2
import PackageDescription

// Routing evals: routing_cases.json run through the real router, the classifier benchmark, and
// the answer-quality benchmark (opt-in; it calls Claude).
let package = Package(
    name: "Evals",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    dependencies: [
        .package(path: "../Packages/HybridRouterKit"),
    ],
    targets: [
        .testTarget(
            name: "RoutingEvalTests",
            dependencies: [
                .product(name: "HybridRouterKit", package: "HybridRouterKit"),
                .product(name: "HybridRouterKitTesting", package: "HybridRouterKit"),
            ],
            path: ".",
            exclude: ["Package.swift", "results"],
            sources: ["RoutingEvalTests.swift", "AppleEvaluationTests.swift", "QualityEvalTests.swift", "QualityChart.swift", "MultiTurnDatasetTests.swift"],
            resources: [.copy("routing_cases.json"), .copy("classifier_benchmark.json"), .copy("quality_benchmark.json"), .copy("quality_testset.json"), .copy("multiturn_benchmark.json")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
