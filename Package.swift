// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoneyUp",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "MoneyUpCore",
            targets: ["MoneyUpCore"]
        ),
        .library(
            name: "MoneyUpPersistence",
            targets: ["MoneyUpPersistence"]
        ),
        .library(
            name: "MoneyUpIntelligence",
            targets: ["MoneyUpIntelligence"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/sqlcipher/SQLCipher.swift.git",
            revision: "f879fffaaa3ad3541a77830daad4a28726dfa927"
        )
    ],
    targets: [
        .target(name: "MoneyUpCore"),
        .target(
            name: "MoneyUpIntelligence",
            dependencies: ["MoneyUpCore"]
        ),
        .target(
            name: "MoneyUpPersistence",
            dependencies: [
                "MoneyUpCore",
                "MoneyUpIntelligence",
                .product(name: "SQLCipher", package: "SQLCipher.swift")
            ],
            cSettings: [
                .define("SQLITE_HAS_CODEC")
            ]
        ),
        .testTarget(
            name: "MoneyUpCoreTests",
            dependencies: ["MoneyUpCore"]
        ),
        .testTarget(
            name: "MoneyUpPersistenceTests",
            dependencies: [
                "MoneyUpCore",
                "MoneyUpIntelligence",
                "MoneyUpPersistence"
            ]
        ),
        .testTarget(
            name: "MoneyUpIntelligenceTests",
            dependencies: ["MoneyUpCore", "MoneyUpIntelligence"]
        )
    ]
)
