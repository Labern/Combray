// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Combray",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CombrayCore", targets: ["CombrayCore"]),
        .executable(name: "Combray", targets: ["Combray"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CombrayCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "Combray",
            dependencies: ["CombrayCore"]
        ),
        .testTarget(
            name: "CombrayCoreTests",
            dependencies: ["CombrayCore"]
        ),
    ]
)
