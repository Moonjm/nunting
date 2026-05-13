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
            // 알아낸 트랩: iOS 타겟이 `SWIFT_APPROACHABLE_CONCURRENCY=YES`로
            // `@Sendable` 클로저 파라미터의 기본 isolation을
            // `nonisolated(nonsending)`로 두는데, 패키지 기본값은 `@concurrent`라
            // BoardParser 프로토콜의 `fetchAllComments` witness가 iOS 측 구현과
            // 매치되지 않아 default extension impl이 dispatch됨. 두 컴파일 컨텍스트의
            // 기본 isolation 규칙을 정렬해야 한다.
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
