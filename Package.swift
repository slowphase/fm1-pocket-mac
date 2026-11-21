// swift-tools-version:5.9
// FM-1 Pocket for macOS: a native player for FM-1 .rfm1 firmware.
//
//   CWasm3     wasm3 v0.5.0 (MIT), the WebAssembly interpreter (Sources/CWasm3/README.md)
//   FM1Host    C: runs one .rfm1 on wasm3 (a port of FM-1 Pocket Player's src/rfm1.js)
//   CFM1Emu    C header for upstream fm1-emu (MIT), linked from Vendor/fm1emu (scripts/build-emu.sh): runs an
//              author's original .fwsc package (the emulator engine)
//   PocketKit  Swift: the catalogue, downloads, the firmware wrapper, audio, saved state
//   FM1Pocket  the SwiftUI app
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// wasm3's interpreter relies on the optimiser's tail calls, so its C is always built optimised, debug builds too
let fastC: [CSetting] = [
    .define("NASSERTS"),
    .unsafeFlags(["-O3", "-UDEBUG", "-fomit-frame-pointer", "-fno-stack-check", "-fno-stack-protector"]),
]

let package = Package(
    name: "FM1Pocket",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FM1Pocket", targets: ["FM1Pocket"]),
    ],
    targets: [
        .target(
            name: "CWasm3",
            path: "Sources/CWasm3",
            exclude: ["README.md", "LICENSE"],
            sources: ["source"],
            publicHeadersPath: "include",
            cSettings: fastC + [.headerSearchPath("include"), .unsafeFlags(["-w"])]
        ),
        .target(
            name: "FM1Host",
            dependencies: ["CWasm3"],
            path: "Sources/FM1Host",
            publicHeadersPath: "include",
            cSettings: fastC + [.headerSearchPath("../CWasm3/source")]
        ),
        .target(
            name: "CFM1Emu",
            path: "Sources/CFM1Emu",
            publicHeadersPath: "include",
            linkerSettings: [.unsafeFlags(["-L\(root)/Vendor/fm1emu", "-lfm1emu_pocket"])]
        ),
        .target(
            name: "PocketKit",
            dependencies: ["FM1Host", "CFM1Emu"],
            path: "Sources/PocketKit",
            linkerSettings: [.linkedFramework("AVFoundation")]
        ),
        .executableTarget(
            name: "FM1Pocket",
            dependencies: ["PocketKit"],
            path: "Sources/FM1Pocket"
        ),
        .testTarget(
            name: "PocketKitTests",
            dependencies: ["PocketKit"],
            path: "Tests/PocketKitTests"
        ),
        .testTarget(
            name: "FM1PocketTests",
            dependencies: ["FM1Pocket", "PocketKit"],
            path: "Tests/FM1PocketTests"
        ),
    ],
    cLanguageStandard: .gnu11
)
