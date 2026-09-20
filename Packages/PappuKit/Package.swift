// swift-tools-version: 6.0
import PackageDescription

// Layering (architecture §15).
// - PappuCore imports no AppKit and depends on nothing, so the CLI and registry CI can use it.
// - PappuJSHost is the sandboxed helper's side and must never depend on an app-side module.
// - PappuHarness and PappuDevTools are development tooling. The shipping app never links them,
//   which is why measurement types that name apps live there and not in PappuDiagnostics (DIA-4).

let core: Target.Dependency = "PappuCore"

let libraries: [(name: String, dependencies: [Target.Dependency])] = [
    ("PappuCore", []),
    ("PappuSelection", [core]),
    ("PappuAnalysis", [core]),
    ("PappuExtensions", [core]),
    ("PappuJSBridge", [core]),
    ("PappuJSHost", [core, "PappuJSBridge"]),
    ("PappuRuntime", [core, "PappuSelection", "PappuExtensions", "PappuJSBridge"]),
    ("PappuSurfaces", [core]),
    ("PappuSettings", [core, "PappuExtensions"]),
    ("PappuRegistry", [core, "PappuExtensions"]),
    ("PappuDiagnostics", [core]),
    ("PappuTestSupport", [core]),
]

let package = Package(
    name: "PappuKit",
    platforms: [.macOS(.v15)],
    products: libraries.map { .library(name: $0.name, targets: [$0.name]) } + [
        .library(name: "PappuHarness", targets: ["PappuHarness"]),
        .executable(name: "pappu-dev", targets: ["pappu-dev"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: libraries.map { .target(name: $0.name, dependencies: $0.dependencies) } + [
        .target(
            name: "PappuHarness",
            dependencies: [core],
            resources: [.process("Resources")]
        ),
        .target(
            name: "PappuDevTools",
            dependencies: [core, "PappuHarness", .product(name: "Yams", package: "Yams")]
        ),
        .executableTarget(
            name: "pappu-dev",
            dependencies: [
                "PappuDevTools",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "PappuCoreTests", dependencies: [core, "PappuTestSupport"]),
        .testTarget(name: "PappuHarnessTests", dependencies: ["PappuHarness", "PappuTestSupport"]),
        .testTarget(name: "PappuDevToolsTests", dependencies: ["PappuDevTools"]),
    ]
)
