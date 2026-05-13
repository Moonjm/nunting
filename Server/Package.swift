// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NuntingServer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "NuntingServer", targets: ["NuntingServer"]),
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .brew(["sqlite3"]),
                .apt(["libsqlite3-dev"]),
            ]
        ),
        .executableTarget(
            name: "NuntingServer",
            dependencies: [
                "CSQLite",
                .product(name: "NuntingCore", package: "Shared"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/NuntingServer",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "NuntingServerTests",
            dependencies: [
                "NuntingServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/NuntingServerTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
