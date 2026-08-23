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
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/sqlcipher/SQLCipher.swift.git",
            exact: "4.18.0"
        )
    ],
    targets: [
        .target(name: "MoneyUpCore"),
        .target(
            name: "MoneyUpPersistence",
            dependencies: [
                "MoneyUpCore",
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
            dependencies: ["MoneyUpCore", "MoneyUpPersistence"]
        )
    ]
)
