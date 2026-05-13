// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NuntingCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "NuntingCore", targets: ["NuntingCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "NuntingCore",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/NuntingCore"
        ),
        .testTarget(
            name: "NuntingCoreTests",
            dependencies: ["NuntingCore"],
            path: "Tests/NuntingCoreTests"
        ),
    ]
)
