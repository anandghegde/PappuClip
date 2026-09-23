// swift-tools-version: 6.0
import PackageDescription

// Layering (architecture §15).
// - PappuCore imports no AppKit and depends on nothing, so the CLI and registry CI can use it.
// - PappuAX is the Accessibility seam alone: the protocol, the value types and the actor that owns
//   the queue. It sits below PappuSelection and PappuAnalysis because both read AX and neither may
//   depend on the other (§3.1: ContextProbe does not depend on PappuSelection).
// - PappuJSHost is the sandboxed helper's side and must never depend on an app-side module.
// - PappuHarness and PappuDevTools are development tooling. The shipping app never links them,
//   which is why measurement types that name apps live there and not in PappuDiagnostics (DIA-4).

let core: Target.Dependency = "PappuCore"

let libraries: [(name: String, dependencies: [Target.Dependency])] = [
    ("PappuCore", []),
    ("PappuAX", []),
    ("PappuSelection", [core, "PappuAX"]),
    ("PappuAnalysis", [core, "PappuAX"]),
    ("PappuExtensions", [core]),
    ("PappuJSBridge", [core]),
    ("PappuJSHost", [core, "PappuJSBridge"]),
    // ActionResolver (§6.3) is here because it is the only module allowed to hold the analysis, the
    // context and the extension store at once: PappuAnalysis may not know the store (§15) and
    // PappuSelection and PappuAnalysis may not know each other.
    ("PappuRuntime", [core, "PappuAX", "PappuSelection", "PappuAnalysis", "PappuExtensions", "PappuJSBridge"]),
    ("PappuRegistry", [core, "PappuExtensions"]),
    ("PappuDiagnostics", [core]),
    ("PappuTestSupport", [core, "PappuAX", "PappuAnalysis", "PappuSelection"]),
]

let package = Package(
    name: "PappuKit",
    // Every string the app shows is looked up, never written in place (PRD §7.12). English ships;
    // the other languages are P2.
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: libraries.map { .library(name: $0.name, targets: [$0.name]) } + [
        .library(name: "PappuSurfaces", targets: ["PappuSurfaces"]),
        .library(name: "PappuSettings", targets: ["PappuSettings"]),
        .library(name: "PappuApp", targets: ["PappuApp"]),
        .library(name: "PappuHarness", targets: ["PappuHarness"]),
        .executable(name: "pappu-dev", targets: ["pappu-dev"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: libraries.map { .target(name: $0.name, dependencies: $0.dependencies) } + [
        // The bar takes what the coordinator hands it (PappuSelection) and owns the strings it shows.
        .target(
            name: "PappuSurfaces",
            dependencies: [core, "PappuAX", "PappuSelection"],
            resources: [.process("Resources")]
        ),
        // The Settings window writes what the stores remember, so it needs the modules those stores
        // live in: the shortcut is PappuSelection's and the bar position is PappuSurfaces'. It is a
        // surface and owns the words it says, so it has a catalogue of its own.
        .target(
            name: "PappuSettings",
            dependencies: [core, "PappuExtensions", "PappuSelection", "PappuSurfaces"],
            resources: [.process("Resources")]
        ),
        // The one module allowed to hold a surface and the runtime at once (architecture §15).
        // PappuSurfaces declares what the bar needs answered and PappuRuntime can answer it, but
        // neither may depend on the other, so the bridge between them lives above both — and with it
        // the assembly, the status item and everything else that is only true of the shipping app.
        .target(
            name: "PappuApp",
            dependencies: [
                core, "PappuAX", "PappuSelection", "PappuAnalysis",
                "PappuSurfaces", "PappuRuntime", "PappuSettings",
            ],
            resources: [.process("Resources")]
        ),
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
        .testTarget(name: "PappuCoreTests", dependencies: [core, "PappuTestSupport", "PappuDevTools"]),
        .testTarget(name: "PappuSelectionTests", dependencies: ["PappuSelection", "PappuTestSupport", "PappuDevTools"]),
        .testTarget(name: "PappuAnalysisTests", dependencies: ["PappuAnalysis", "PappuTestSupport", "PappuDevTools"]),
        .testTarget(name: "PappuRuntimeTests", dependencies: ["PappuRuntime", "PappuAnalysis", "PappuTestSupport"]),
        .testTarget(name: "PappuAppTests", dependencies: ["PappuApp", "PappuTestSupport", "PappuDevTools"]),
        .testTarget(name: "PappuSurfacesTests", dependencies: ["PappuSurfaces", core, "PappuTestSupport"]),
        .testTarget(name: "PappuSettingsTests", dependencies: ["PappuSettings", "PappuTestSupport", "PappuDevTools"]),
        .testTarget(name: "PappuHarnessTests", dependencies: ["PappuHarness", "PappuTestSupport"]),
        .testTarget(name: "PappuDevToolsTests", dependencies: ["PappuDevTools"]),
    ]
)
