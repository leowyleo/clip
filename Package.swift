// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Clip",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Clip", targets: ["ClipApp"]),
        .library(name: "ClipCore", targets: ["ClipCore"]),
        .library(name: "ClipCapture", targets: ["ClipCapture"]),
        .library(name: "ClipScroll", targets: ["ClipScroll"])
    ],
    targets: [
        .target(name: "ClipCore"),
        .target(
            name: "ClipCapture",
            dependencies: ["ClipCore"]
        ),
        .target(
            name: "ClipScroll",
            dependencies: ["ClipCore"]
        ),
        .executableTarget(
            name: "ClipApp",
            dependencies: ["ClipCore", "ClipCapture", "ClipScroll"]
        ),
        .testTarget(
            name: "ClipCoreTests",
            dependencies: ["ClipCore"]
        ),
        .testTarget(
            name: "ClipCaptureTests",
            dependencies: ["ClipCapture", "ClipCore"]
        ),
        .testTarget(
            name: "ClipScrollTests",
            dependencies: ["ClipScroll", "ClipCore"]
        ),
        .testTarget(
            name: "ClipAppTests",
            dependencies: ["ClipApp"]
        )
    ]
)
