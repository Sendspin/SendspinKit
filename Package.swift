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
        .package(url: "https://github.com/sbooth/flac-binary-xcframework.git", from: "0.1.0"),
        .package(url: "https://github.com/sbooth/ogg-binary-xcframework.git", from: "0.1.0"),
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.9.1"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3")
    ],
    targets: [
        .target(
            name: "CElligator",
            path: "Sources/CElligator",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("vendor"),
                .headerSearchPath("vendor/private"),
                .headerSearchPath("vendor/fe_25_5"),
                // The vendored libsodium sources emit "#warning undocumented method"
                // unless the build declares itself configured; SwiftPM has no
                // ./configure step, so declare it here.
                .define("CONFIGURED", to: "1")
            ]
        ),
        .target(
            name: "SendspinKit",
            dependencies: [
                .product(name: "FLAC", package: "flac-binary-xcframework"),
                .product(name: "ogg", package: "ogg-binary-xcframework"),
                "CElligator",
                .product(name: "Clibsodium", package: "swift-sodium")
            ],
            exclude: [
                "Client/AGENTS.md"
            ]
        ),
        .testTarget(
            name: "SendspinKitTests",
            dependencies: ["SendspinKit"],
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
