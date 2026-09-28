// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Moria",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "MoriaApp", targets: ["MoriaApp"]),
        .executable(name: "moria", targets: ["moria"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MoriaCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
        ),
        .executableTarget(
            name: "moria",
            dependencies: [
                "MoriaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            path: "Sources/MoriaCLI"
        ),
        .executableTarget(
            name: "MoriaApp",
            dependencies: ["MoriaCore"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "MoriaCoreTests",
            dependencies: ["MoriaCore"]
        ),
        .testTarget(
            name: "MoriaAppTests",
            dependencies: ["MoriaApp"]
        ),
    ]
)
