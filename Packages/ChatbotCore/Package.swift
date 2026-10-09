// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChatbotCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ChatbotCore", targets: ["ChatbotCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
    ],
    targets: [
        .target(
            name: "ChatbotCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "ChatbotCoreTests",
            dependencies: ["ChatbotCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
