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
        // NuntingServerTests testTarget는 Task 2에서 첫 테스트 파일이 생길 때
        // 함께 선언한다. 빈 디렉터리 + testTarget 선언은 매 빌드마다 SPM warning
        // 을 찍어 실제 경고를 가린다.
    ]
)
