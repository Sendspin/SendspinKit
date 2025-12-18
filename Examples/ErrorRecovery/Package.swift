// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ErrorRecovery",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "ErrorRecovery",
            dependencies: [
                .product(name: "SendspinKit", package: "SendspinKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
