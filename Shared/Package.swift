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
            path: "Sources/NuntingCore",
            // BoardParser의 `fetchAllComments(... fetcher:)` 클로저 파라미터에
            // `nonisolated(nonsending)`을 명시 annotate하므로 default isolation
            // 설정에 의존하지 않는다. 이 upcoming feature는 더 이상 witness binding
            // alignment 용도로 필요 없지만, 패키지가 import되는 모든 모듈에서
            // 동일한 closure isolation 기본값을 갖게 해 향후 코드 변경 시
            // 비명시 케이스에서도 안전하도록 유지한다.
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "NuntingCoreTests",
            dependencies: ["NuntingCore"],
            path: "Tests/NuntingCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
