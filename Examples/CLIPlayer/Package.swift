// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CLIPlayer",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(name: "SendspinKit", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "CLIPlayer",
            dependencies: [
                .product(name: "SendspinKit", package: "SendspinKit")
            ]
        )
    ]
)
