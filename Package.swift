// swift-tools-version:5.9
import PackageDescription
import Foundation

// SWITCHIT_APPSTORE=1 builds the App Store edition: sandboxed, no Sparkle (later), no diary (later).
// The APPSTORE compile flag hides what the Store forbids. Same scheme as Keepit's KEEPIT_APPSTORE.
let appStore = ProcessInfo.processInfo.environment["SWITCHIT_APPSTORE"] == "1"

let package = Package(
    name: "Switchit",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        // Detector layer, no AppKit and no Carbon: key codes, layout tables, the word buffer and
        // (from stage 1) the language models. Everything here is testable with `swift test` on CI;
        // the real input sources and the event tap live in the app target only.
        .target(
            name: "SwitchitCore",
            path: "Sources/SwitchitCore",
            // model-<lang>.txt and short-<lang>.txt, written by Scripts/export_model.py.
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "Switchit",
            dependencies: ["SwitchitCore"],
            path: "Sources/Switchit",
            swiftSettings: appStore ? [.define("APPSTORE")] : [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "SwitchitTests",
            dependencies: ["SwitchitCore"],
            path: "Tests/SwitchitTests",
            // golden.tsv: decisions of the Python reference; GoldenTests opens it by path.
            exclude: ["Fixtures"]
        ),
    ]
)
