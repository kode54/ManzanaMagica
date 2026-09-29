// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-2.0-only
import PackageDescription

let package = Package(
    name: "ManzanaMagica",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MagicaCore", targets: ["MagicaCore"]),
        .library(name: "MagicaCapture", targets: ["MagicaCapture"]),
        .library(name: "MagicaPlayback", targets: ["MagicaPlayback"]),
        .executable(name: "magica", targets: ["magica"]),
    ],
    targets: [
        // libusb 1.0.30, macOS backend only, built from source so the app
        // doesn't depend on Homebrew (LGPL-2.1-or-later, see vendor/libusb).
        .target(
            name: "CLibUSB",
            path: "vendor/libusb",
            exclude: ["COPYING", "AUTHORS", "README.vendor"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("src/os"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        // The em28xx bridge and SAA7113 decoder driver, ported from Linux
        .target(
            name: "MagicaCore",
            dependencies: ["CLibUSB"],
            path: "src",
            exclude: ["cli"],
            sources: ["core"],
            publicHeadersPath: "include"
        ),
        // Command-line probe and raw capture
        .executableTarget(
            name: "magica",
            dependencies: ["MagicaCore"],
            path: "src/cli"
        ),
        // Swift face of the device: hot-plug, fields → pixel buffers, audio input
        .target(
            name: "MagicaCapture",
            dependencies: ["MagicaCore"]
        ),
        // GPU deinterlacing, live display and recording
        .target(
            name: "MagicaPlayback",
            dependencies: ["MagicaCapture"]
        ),
        // Headless recording through the app's pipeline
        .executableTarget(
            name: "mgtool",
            dependencies: ["MagicaCapture", "MagicaPlayback"]
        ),
        .testTarget(
            name: "MagicaCoreTests",
            dependencies: ["MagicaCore"]
        ),
    ],
    cLanguageStandard: .gnu11
)
