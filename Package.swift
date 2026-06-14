// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SendspinKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "SendspinKit",
            targets: ["SendspinKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/alta/swift-opus.git", from: "0.0.2"),
        .package(url: "https://github.com/sbooth/flac-binary-xcframework.git", from: "0.1.0"),
        .package(url: "https://github.com/sbooth/ogg-binary-xcframework.git", from: "0.1.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3")
    ],
    targets: [
        .target(
            name: "SendspinKit",
            dependencies: [
                .product(name: "Opus", package: "swift-opus"),
                .product(name: "FLAC", package: "flac-binary-xcframework"),
                .product(name: "ogg", package: "ogg-binary-xcframework")
            ],
            exclude: [
                "Client/AGENTS.md"
            ]
        ),
        .testTarget(
            name: "SendspinKitTests",
            dependencies: ["SendspinKit"]
        )
    ]
)
