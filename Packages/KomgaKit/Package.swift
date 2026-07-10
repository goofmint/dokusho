// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KomgaKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "KomgaKit",
            targets: ["KomgaKit"]
        ),
    ],
    targets: [
        .target(
            name: "KomgaKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "KomgaKitTests",
            dependencies: ["KomgaKit"]
        ),
    ]
)
