// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FujiTransfer",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "FujiCore", targets: ["FujiCore"]),
        .executable(name: "fuji-probe", targets: ["fuji-probe"])
    ],
    targets: [
        // MIT-licensed PTP/IP core library (without libusb dependency, portable to macOS & iOS)
        .target(
            name: "CLibPict",
            path: "vendor/libfuji/libpict",
            sources: [
                "src/operations.c",
                "src/packet.c",
                "src/enums.c",
                "src/data.c",
                "src/enum_dump.c",
                "src/lib.c",
                "src/canon.c",
                "src/liveview.c",
                "src/ml.c",
                "src/conv.c",
                "src/generic.c",
                "src/transport.c",
                "src/ip.c",
                "src/no_usb.c"
            ],
            // Avoid generating a Clang module for internal sub-headers (cl_ops.h, cl_backend.h)
            publicHeadersPath: "docs",
            cSettings: [
                .headerSearchPath("src"),
                .define("VERBOSE", to: "1")
            ]
        ),
        // MIT-licensed Fujifilm Wi-Fi PTP/IP protocol implementation
        .target(
            name: "CLibFuji",
            dependencies: ["CLibPict"],
            path: "vendor/libfuji",
            sources: [
                "lib/fuji.c",
                "lib/data.c",
                "lib/exif.c"
            ],
            // Avoid exposing lib/module.h (which depends on external libpak headers)
            publicHeadersPath: "docs",
            cSettings: [
                .headerSearchPath("lib"),
                .headerSearchPath("libpict/src")
            ]
        ),
        // Clean C bridge exposing an ergonomic, Swift-safe API over libfuji + libpict
        .target(
            name: "CFujiBridge",
            dependencies: ["CLibFuji", "CLibPict"],
            path: "Sources/CFujiBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../vendor/libfuji/lib"),
                .headerSearchPath("../../vendor/libfuji/libpict/src")
            ]
        ),
        // Reusable Swift core (Wi-Fi PTP/IP + CoreBluetooth BLE) for macOS CLI and future iOS app
        .target(
            name: "FujiCore",
            dependencies: ["CFujiBridge"],
            path: "Sources/FujiCore",
            linkerSettings: [
                .linkedFramework("CoreBluetooth")
            ]
        ),
        // macOS CLI probe tool for Phase 1 feasibility testing against a real Fujifilm X-T4
        .executableTarget(
            name: "fuji-probe",
            dependencies: ["FujiCore"],
            path: "Sources/fuji-probe"
        ),
        .testTarget(
            name: "FujiCoreTests",
            dependencies: ["FujiCore", "CFujiBridge"],
            path: "Tests/FujiCoreTests"
        )
    ]
)
