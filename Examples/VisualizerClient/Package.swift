// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VisualizerClient",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "SendspinKit", path: "../..")
    ],
    targets: [
        .target(
            name: "VisualizerClientCore",
            dependencies: [
                .product(name: "SendspinKit", package: "SendspinKit")
            ]
        ),
        .executableTarget(
            name: "VisualizerClient",
            dependencies: [
                "VisualizerClientCore",
                .product(name: "SendspinKit", package: "SendspinKit")
            ]
        ),
        .testTarget(
            name: "VisualizerClientCoreTests",
            dependencies: [
                "VisualizerClientCore",
                .product(name: "SendspinKit", package: "SendspinKit")
            ]
        )
    ]
)
