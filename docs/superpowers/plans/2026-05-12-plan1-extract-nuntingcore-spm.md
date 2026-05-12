# Plan 1 — NuntingCore SPM 패키지 추출

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 뽐뿌 파서·관련 모델을 로컬 SPM 패키지 `NuntingCore`로 추출해, 같은 monorepo의 iOS 앱과 (후속 PR에서 만들 Linux 서버)이 동일 소스를 import하여 사용하도록 한다. 기능 변화 0인 pure refactor.

**Architecture:** repo 루트에 `Shared/` 디렉터리 신설 → `Shared/Package.swift`가 `NuntingCore` library를 선언. iOS Xcode 프로젝트는 이 폴더를 Local Package로 의존. 7개 파일이 `nunting/Parsers`·`nunting/Models`에서 `Shared/Sources/NuntingCore/`로 이동, 나머지 iOS 코드/테스트는 `import NuntingCore`를 추가.

**Tech Stack:** Swift 5.9+, SwiftPM (Local Package), Xcode 16+, SwiftSoup (이미 사용 중인 외부 SPM 의존), XCTest.

**관련 스펙:** `docs/superpowers/specs/2026-05-12-ppomppu-keyword-push-design.md` — "디렉터리 / 패키지 구조" 절.

---

## 파일 구조 요약

**Create:**
- `Shared/Package.swift`
- `Shared/Sources/NuntingCore/` — 이동된 7개 파일이 들어갈 디렉터리
- `Shared/Tests/NuntingCoreTests/PpomppuParserSmokeTests.swift`

**Move (git mv, 경로만 변경, 내용 미수정):**
- `nunting/Parsers/BoardParser.swift`     → `Shared/Sources/NuntingCore/BoardParser.swift`
- `nunting/Parsers/PpomppuParser.swift`   → `Shared/Sources/NuntingCore/PpomppuParser.swift`
- `nunting/Models/Post.swift`             → `Shared/Sources/NuntingCore/Post.swift`
- `nunting/Models/Board.swift`            → `Shared/Sources/NuntingCore/Board.swift`
- `nunting/Models/BoardFilter.swift`      → `Shared/Sources/NuntingCore/BoardFilter.swift` (Board가 `[BoardFilter]`을 stored property로 가지므로 함께 이동 필수)
- `nunting/Models/Site.swift`             → `Shared/Sources/NuntingCore/Site.swift`
- `nunting/Models/Comment.swift`          → `Shared/Sources/NuntingCore/Comment.swift`

**Modify:**
- `nunting.xcodeproj/project.pbxproj` — 7개 파일 reference 제거 + Local Package(`../Shared`) 등록 + nunting target에 NuntingCore 의존 추가
- iOS 측 `import NuntingCore` 추가 (Task 7에서 일괄 적용)
- 테스트 11개 파일 `import NuntingCore` 추가 (Task 8에서 일괄 적용)

---

### Task 1: `Shared/` 디렉터리 + 최소 `Package.swift` 만들기

**Files:**
- Create: `Shared/Package.swift`
- Create: `Shared/Sources/NuntingCore/Placeholder.swift` (한 시점에만 잠시 존재. 다음 task에서 실제 파일이 들어오면 삭제)

- [ ] **Step 1: `Shared/Package.swift` 작성**

```swift
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
```

- [ ] **Step 2: 일시 placeholder 소스 만들기 (target에 소스가 0개면 SwiftPM이 거부)**

`Shared/Sources/NuntingCore/Placeholder.swift`:

```swift
// Removed in Task 3 once real files arrive.
@_documentation(visibility: private)
internal enum _NuntingCoreScaffold {}
```

- [ ] **Step 3: 빌드 검증**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Shared
swift build
```

기대: `Build complete!` (SwiftSoup이 한 번 fetch됨, 약 5~10초). 실패 시 `Package.swift` 문법/들여쓰기 점검.

- [ ] **Step 4: 커밋**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git add Shared/Package.swift Shared/Sources/NuntingCore/Placeholder.swift
git commit -m "chore(shared): NuntingCore SPM 패키지 골격 추가"
```

---

### Task 2: 모델 5개 이동 (Post, Board, BoardFilter, Site, Comment)

이 파일들은 Foundation/CoreGraphics만 import하므로 NuntingCore의 iOS+macOS+Linux 호환 컴파일에 문제 없음. `Board`가 `[BoardFilter]`를 stored property로 가지므로 `BoardFilter`도 함께 이동. `git mv`로 옮겨 git 히스토리 보존.

**Files:**
- Move: `nunting/Models/Post.swift` → `Shared/Sources/NuntingCore/Post.swift`
- Move: `nunting/Models/Board.swift` → `Shared/Sources/NuntingCore/Board.swift`
- Move: `nunting/Models/BoardFilter.swift` → `Shared/Sources/NuntingCore/BoardFilter.swift`
- Move: `nunting/Models/Site.swift` → `Shared/Sources/NuntingCore/Site.swift`
- Move: `nunting/Models/Comment.swift` → `Shared/Sources/NuntingCore/Comment.swift`

- [ ] **Step 1: git mv 다섯 번 + 내용은 그대로 둔다 (한 글자도 수정 X)**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git mv nunting/Models/Post.swift        Shared/Sources/NuntingCore/Post.swift
git mv nunting/Models/Board.swift       Shared/Sources/NuntingCore/Board.swift
git mv nunting/Models/BoardFilter.swift Shared/Sources/NuntingCore/BoardFilter.swift
git mv nunting/Models/Site.swift        Shared/Sources/NuntingCore/Site.swift
git mv nunting/Models/Comment.swift     Shared/Sources/NuntingCore/Comment.swift
```

- [ ] **Step 2: 옮긴 파일의 internal 접근 한정자가 NuntingCore 모듈 밖(iOS 앱)에서 보이도록 `public`으로 승격**

각 파일에서 `struct Post`, `struct Board`, `struct BoardFilter`, `enum Site`, `struct Comment`, 그리고 그 안의 모든 멤버(properties, methods, nested types)를 `public`으로 표시. iOS 앱이 다른 모듈로서 이 타입들을 쓰려면 명시적 public이 필요.

가장 안전한 방법: 각 파일 열고 다음 패턴을 일괄 치환:

| 기존 | 변경 |
|------|------|
| `struct Post:` | `public struct Post:` |
| `struct ContentBlock:` | `public struct ContentBlock:` |
| `enum EmbedProvider:` | `public enum EmbedProvider:` |
| `enum InlineSegment:` | `public enum InlineSegment:` |
| `struct PostSource:` | `public struct PostSource:` |
| `struct PostDetail` | `public struct PostDetail` |
| `struct Board:` | `public struct Board:` |
| `struct BoardFilter:` | `public struct BoardFilter:` |
| `enum Site:` | `public enum Site:` |
| `struct Comment:` | `public struct Comment:` |
| `extension Board {` | `extension Board {` (확장 내부 멤버에 `public` 추가) |
| `let xxx:` 가 타입 내부 stored property면 → `public let xxx:` |
| `var xxx:` 가 타입 내부 stored property면 → `public var xxx:` |
| `init(...)` 모든 명시적 이니셜라이저 → `public init(...)` |
| `func xxx(...)` 모든 메소드 → `public func xxx(...)` |
| `static let / static func` → `public static let / public static func` |

이 작업은 기계적이지만 빠짐 없이 해야 함. 점검 도구: Task 6 끝에서 Xcode build 돌리면 누락된 부분이 "Cannot find 'X' in scope" 류 에러로 확인됨.

- [ ] **Step 3: Shared 패키지 단독 빌드로 검증**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Shared
swift build
```

기대: 성공 (Foundation/CoreGraphics만 의존, public 키워드 누락 시 그 자체로는 컴파일됨 — public 누락은 iOS 앱 쪽 빌드에서 잡힘).

- [ ] **Step 4: 커밋**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git add Shared/Sources/NuntingCore/Post.swift Shared/Sources/NuntingCore/Board.swift \
        Shared/Sources/NuntingCore/BoardFilter.swift \
        Shared/Sources/NuntingCore/Site.swift Shared/Sources/NuntingCore/Comment.swift \
        nunting/Models/
git commit -m "refactor(models): Post/Board/BoardFilter/Site/Comment NuntingCore로 이동 + public 노출"
```

---

### Task 3: `BoardParser.swift` 이동 (protocol + `ParserText` 유틸)

`BoardParser.swift`는 protocol과 함께 `ParserText` 유틸 enum (line 238 근방)을 포함. 둘 다 NuntingCore로 이동, public 승격 동일.

**Files:**
- Move: `nunting/Parsers/BoardParser.swift` → `Shared/Sources/NuntingCore/BoardParser.swift`
- Delete: `Shared/Sources/NuntingCore/Placeholder.swift` (Task 1의 일시 파일)

- [ ] **Step 1: 이동 + placeholder 삭제**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git mv nunting/Parsers/BoardParser.swift Shared/Sources/NuntingCore/BoardParser.swift
git rm Shared/Sources/NuntingCore/Placeholder.swift
```

- [ ] **Step 2: BoardParser.swift public 승격**

다음 심볼들을 모두 `public`으로:

- `protocol BoardParser` (멤버 메소드 시그니처도 public)
- `enum ParserText`와 그 안의 `static func cleanTitle(...)` 등 모든 정적 멤버
- 그 외 같은 파일에 정의된 어떤 타입/함수/extension이라도 외부 사용 가능성 있으면 public

- [ ] **Step 3: Shared 패키지 빌드 검증**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Shared
swift build
```

기대: 성공. 만약 `Cannot find type 'Post' in scope` 같은 에러가 나면 Task 2에서 Post의 public 승격 누락 → 보강.

- [ ] **Step 4: 커밋**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git add Shared/Sources/NuntingCore/BoardParser.swift Shared/Sources/NuntingCore/Placeholder.swift nunting/Parsers/
git commit -m "refactor(parsers): BoardParser protocol과 ParserText 유틸 NuntingCore로 이동"
```

---

### Task 4: `PpomppuParser.swift` 이동

**Files:**
- Move: `nunting/Parsers/PpomppuParser.swift` → `Shared/Sources/NuntingCore/PpomppuParser.swift`

- [ ] **Step 1: git mv**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git mv nunting/Parsers/PpomppuParser.swift Shared/Sources/NuntingCore/PpomppuParser.swift
```

- [ ] **Step 2: PpomppuParser public 승격**

다음 심볼을 `public`으로:

- `struct PpomppuParser: BoardParser` → `public struct PpomppuParser: BoardParser`
- `init()` → `public init()`
- BoardParser protocol에서 요구하는 메소드들 (`parseList`, `parseDetail`, `fetchAllComments` 등)은 protocol이 public이면 자동으로 외부 호출 가능하지만, 구현체에 명시적 public을 두는 게 가독성 + 안전.
- 기존 `nonisolated`, `private`, `private static`은 그대로 유지 (내부 헬퍼는 비공개여도 됨).

- [ ] **Step 3: Shared 단독 빌드 검증**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Shared
swift build
```

기대: 성공.

- [ ] **Step 4: 커밋**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git add Shared/Sources/NuntingCore/PpomppuParser.swift nunting/Parsers/
git commit -m "refactor(parsers): PpomppuParser NuntingCore로 이동"
```

---

### Task 5: NuntingCoreTests에 PpomppuParser 스모크 테스트 1개

가장 작은 HTML fixture로 `parseList`가 동작하는지 확인 — 추후 Plan 2 ~ Plan 3에서 서버가 같은 파서를 import할 때의 first-line-of-defense.

**Files:**
- Create: `Shared/Tests/NuntingCoreTests/PpomppuParserSmokeTests.swift`

- [ ] **Step 1: 테스트 작성**

Board의 실제 designated initializer:
```swift
init(id: String, site: Site, name: String, path: String, filters: [BoardFilter] = [], searchQueryName: String? = nil, pageQueryName: String? = nil)
```

이를 그대로 사용:

```swift
import XCTest
@testable import NuntingCore

final class PpomppuParserSmokeTests: XCTestCase {
    /// Minimal Ppomppu list HTML — one row with title, link, comment count.
    /// Pinning the smallest legal DOM against the parser keeps `parseList`
    /// honest across SwiftSoup or selector changes.
    func testParseListExtractsSingleRow() throws {
        let html = """
        <html><body>
            <ul class="bbsList_new">
                <li class="">
                    <a href="https://www.ppomppu.co.kr/zboard/view.php?id=ppomppu&no=999999">
                        <li class="title"><span class="cont">테스트 글 제목</span></li>
                    </a>
                    <span class="rp">3</span>
                    <time>10:30:00</time>
                </li>
            </ul>
        </body></html>
        """
        let board = Board(
            id: "ppomppu",
            site: .ppomppu,
            name: "뽐뿌게시판",
            path: "/zboard/zboard.php?id=ppomppu"
        )
        let posts = try PpomppuParser().parseList(html: html, board: board)
        XCTAssertEqual(posts.count, 1, "minimal fixture should yield exactly one Post")
        XCTAssertEqual(posts.first?.title, "테스트 글 제목")
    }
}
```

- [ ] **Step 2: 빌드 + 테스트 실행**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Shared
swift test --filter PpomppuParserSmokeTests
```

기대: 처음 시도 시 컴파일 에러(`Cannot find 'Board' in scope` 또는 `'PpomppuParser' initializer is inaccessible`)가 나면 Task 2~4의 public 승격 누락 → 보강. 컴파일은 되는데 테스트 fail이면 fixture HTML이 selector를 못 맞춘 것 — 파서의 `parseList` 코드(`ul.bbsList_new > li` selector)를 다시 보고 fixture 조정.

- [ ] **Step 3: 통과할 때까지 fixture/접근자 조정**

빌드 + 테스트 모두 통과할 때까지 반복.

- [ ] **Step 4: 통과 확인**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Shared
swift test --filter PpomppuParserSmokeTests
```

기대: PASS, 1 test passed.

- [ ] **Step 5: 커밋**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git add Shared/Tests/NuntingCoreTests/PpomppuParserSmokeTests.swift
git commit -m "test(core): PpomppuParser parseList 최소 fixture 스모크"
```

---

### Task 6: Xcode 프로젝트에서 이동된 파일 reference 제거 + Local Package 추가

이 단계가 plan에서 가장 위험. Xcode가 아직 7개 파일을 옛 경로에서 찾고 있으므로 빌드 실패 상태. 두 방향이 있으니 둘 중 자신 있는 쪽으로:

**경로 A — Xcode UI 사용 (권장, 사람 손)**

1. Xcode에서 `nunting.xcodeproj` 열기.
2. 프로젝트 네비게이터에서 이동된 7개 파일 — 빨갛게 미싱 표시될 것 — 모두 우클릭 → Delete → "Remove References" (Move to Trash 아님).
3. File → Add Package Dependencies… → 좌하단 "Add Local…" 버튼 → `Shared/` 디렉터리 선택 → "Add Package" 클릭.
4. 다음 화면에서 `NuntingCore` library 옆 "Add to Target" 드롭다운에서 `nunting` (메인 타겟) 선택. "Add Package" 클릭.
5. `nunting` 타겟의 General 탭 → "Frameworks, Libraries, and Embedded Content"에 `NuntingCore`가 나타나는지 확인.

**경로 B — `project.pbxproj` 직접 수정 (LLM agent 또는 자동화 시)**

1. `nunting.xcodeproj/project.pbxproj` 열기.
2. 다음 7개 파일의 `PBXFileReference`, `PBXBuildFile`, `PBXGroup` children 항목을 검색해 모두 삭제:
   - `Post.swift`, `Board.swift`, `BoardFilter.swift`, `Site.swift`, `Comment.swift`
   - `BoardParser.swift`, `PpomppuParser.swift`
   
   각 파일마다 보통 3군데 등장 (FileRef 정의, BuildFile 정의, Group의 children 리스트). 모두 일관되게 제거.
3. `XCRemoteSwiftPackageReference` 섹션 위치에 새로 `XCLocalSwiftPackageReference` 추가 — 패턴:
   ```
   /* Begin XCLocalSwiftPackageReference section */
       AAAAAAAA0000000000000001 /* XCLocalSwiftPackageReference "Shared" */ = {
           isa = XCLocalSwiftPackageReference;
           relativePath = Shared;
       };
   /* End XCLocalSwiftPackageReference section */
   ```
   (UUID는 임의의 24-hex; 기존 ID와 충돌만 안 되면 됨.)
4. Project의 `packageReferences` 배열에 위에서 만든 ID 추가.
5. 새 `XCSwiftPackageProductDependency` 추가:
   ```
       AAAAAAAA0000000000000002 /* NuntingCore */ = {
           isa = XCSwiftPackageProductDependency;
           package = AAAAAAAA0000000000000001 /* XCLocalSwiftPackageReference "Shared" */;
           productName = NuntingCore;
       };
   ```
6. `nunting` 메인 타겟의 `packageProductDependencies` 배열에 위 ID 추가.
7. `PBXBuildFile` 섹션에 `NuntingCore in Frameworks` 항목 추가:
   ```
       AAAAAAAA0000000000000003 /* NuntingCore in Frameworks */ = {
           isa = PBXBuildFile;
           productRef = AAAAAAAA0000000000000002 /* NuntingCore */;
       };
   ```
8. `nunting` 메인 타겟의 `Frameworks` build phase의 `files` 배열에 위 ID 추가.

(경로 B는 기존 SwiftSoup 등 remote 패키지가 등록된 패턴을 참조하면 구조가 명확함. `XCRemoteSwiftPackageReference` 대신 `XCLocalSwiftPackageReference`라는 점만 다름.)

- [ ] **Step 1: 위 경로 A 또는 B로 pbxproj 수정**

- [ ] **Step 2: 빌드 검증 (이 시점에선 import 누락으로 다수 컴파일 에러 예상)**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
xcodebuild -scheme nunting -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head -30
```

기대: BUILD FAILED, 에러는 "Cannot find 'Board' in scope" / "Cannot find type 'BoardParser'" / "Cannot find 'Post' in scope" 류 — Task 7에서 `import NuntingCore` 추가로 해결.

만약 에러가 "package 'Shared' not found" 류면 pbxproj의 Local Package 설정 자체가 잘못된 것 — Step 1로 돌아가 수정.

- [ ] **Step 3: 커밋 (다음 Task가 빌드를 통과시키므로 이 시점 커밋은 WIP 의도)**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git add nunting.xcodeproj/project.pbxproj
git commit -m "chore(xcode): NuntingCore Local Package 등록 + 이동된 파일 reference 제거"
```

---

### Task 7: iOS 앱 callsite에 `import NuntingCore` 추가

Task 6 후 빌드가 실패할 텐데, "Cannot find X in scope" 에러가 나는 모든 `.swift` 파일에 `import NuntingCore` 한 줄을 추가하면 해결. 대상은 NuntingCore의 심볼(`Post`, `Board`, `Site`, `Comment`, `BoardParser`, `ParserText`, `PpomppuParser`)을 사용하는 iOS-side 모든 파일.

대상 파일 (사전 추정 — 빌드 에러 보고 더 추가될 수 있음):

- `nunting/Parsers/AagagParser.swift` ~ `nunting/Parsers/SLRParser.swift` (이동 안 한 10개 파서)
- `nunting/Parsers/ParserFactory.swift`
- `nunting/Models/BoardFilter.swift`, `BoardGroup.swift`, `DrawerSection.swift`, `Site+Color.swift`
- `nunting/Services/SiteCatalog.swift`, `PostDetailLoader.swift`, `BoardListLoader.swift`, `DetailOverlayController.swift`, 기타 service 다수
- `nunting/Views/PostDetailView.swift`, `BoardListView.swift`, `ImageViewer.swift`, 기타 view 다수
- `nunting/ContentView.swift`
- `nunting/nuntingApp.swift`

- [ ] **Step 1: NuntingCore 심볼 사용 파일 자동 발견**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
grep -rl --include='*.swift' -E '\b(Post|Board|BoardFilter|Site|Comment|BoardParser|ParserText|PpomppuParser|ContentBlock|EmbedProvider|InlineSegment|PostSource|PostDetail)\b' nunting/ | sort -u
```

이 목록에 나오는 모든 파일이 후보. (단, `Post.swift` 자신 같은 NuntingCore 안 파일은 제외 — 현 단계에선 이미 이동했으므로 grep 결과에 없음.)

- [ ] **Step 2: 각 후보 파일의 상단 `import Foundation` 등의 import 블록 끝에 `import NuntingCore` 한 줄 추가**

방법 a: 한 파일씩 Edit 도구로 추가.
방법 b: `awk`/`sed`로 일괄 — 그러나 import 블록 위치가 파일마다 다르므로 한 파일씩 확인이 더 안전.

기준선: 파일 첫 줄이 `import Foundation`이면 그 다음 줄에 `import NuntingCore` 삽입.

- [ ] **Step 3: 빌드 검증**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
xcodebuild -scheme nunting -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | grep -E "error:" | head -20
```

기대: 점차 에러가 줄어듦. 남은 에러는 추가 누락 파일 시그널 — 그 파일에도 `import NuntingCore` 추가.

`error:`가 0개 되면 다음으로.

- [ ] **Step 4: BUILD SUCCEEDED 확인**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
xcodebuild -scheme nunting -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
```

기대: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: 커밋**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git add nunting/
git commit -m "refactor(ios): import NuntingCore 추가 — 이동된 타입을 쓰는 모든 iOS callsite"
```

---

### Task 8: `nuntingTests/*.swift`에 `import NuntingCore` 추가 + 테스트 통과 확인

Task 7과 동형이지만 대상은 테스트 11개 파일.

- [ ] **Step 1: 테스트 빌드 시도**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
xcodebuild -scheme nunting -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug test-without-building 2>&1 | grep -E "error:" | head -10
```

(또는 `build-for-testing`으로 빌드만)

기대: 테스트 파일에서 "Cannot find 'Post' in scope" 류 에러.

- [ ] **Step 2: 모든 테스트 파일 상단에 `import NuntingCore` 추가**

다음 11개 파일에 `import nunting` 다음 줄 또는 `@testable import nunting` 다음 줄에 `import NuntingCore` 한 줄 추가:

- `nuntingTests/BoardCatalogStoreTests.swift`
- `nuntingTests/BoardListLoaderTests.swift`
- `nuntingTests/BoardSelectionTests.swift`
- `nuntingTests/BoardURLTests.swift`
- `nuntingTests/DetailOverlayControllerTests.swift`
- `nuntingTests/FavoritesStoreTests.swift`
- `nuntingTests/NetworkingTests.swift`
- `nuntingTests/ParserDetailTests.swift`
- `nuntingTests/ParserListTests.swift`
- `nuntingTests/PostDetailLoaderTests.swift`
- `nuntingTests/SmokeTests.swift`

- [ ] **Step 3: 테스트 빌드 + 실행**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
xcodebuild -scheme nunting -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug test 2>&1 | tail -20
```

기대: `** TEST SUCCEEDED **`, 모든 케이스 PASS.

만약 시뮬레이터 이름이 환경에 따라 다르면 `xcrun simctl list devices available | head -10`으로 사용 가능한 이름 확인 후 그걸로 교체.

- [ ] **Step 4: 커밋**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git add nuntingTests/
git commit -m "test(ios): import NuntingCore 추가 — 이동된 타입 참조하는 모든 테스트"
```

---

### Task 9: 최종 통합 검증

이전 단계에서 각 단위는 통과했지만, 한 번 더 깨끗한 환경에서 전체 빌드/테스트.

- [ ] **Step 1: DerivedData/SPM 캐시 정리 후 재빌드 (Shared만)**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Shared
swift package clean
swift build
swift test
```

기대: 둘 다 성공, NuntingCoreTests 1 case PASS.

- [ ] **Step 2: iOS 앱 전체 빌드 + 테스트**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
xcodebuild -scheme nunting -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug clean test 2>&1 | tail -10
```

기대: `** TEST SUCCEEDED **`.

- [ ] **Step 3: 변경된 파일 / 디렉터리 구조 확인**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git log --oneline main..HEAD
git diff --stat main..HEAD
ls Shared/Sources/NuntingCore/
```

기대 출력 (예시):
- main 대비 6~7개 커밋 (각 Task 단위)
- diff stat에 `Shared/` 신규 추가, `nunting/Models/` `nunting/Parsers/`에서 7개 파일 삭제, 다수 파일에 `import NuntingCore` 추가
- `Shared/Sources/NuntingCore/` 안에 6개 `.swift` 파일

---

### Task 10: PR 생성

- [ ] **Step 1: 브랜치 푸시 + PR**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git push -u origin <현재 브랜치명>
gh pr create --base main --title "refactor(core): NuntingCore SPM 패키지로 파서·모델 추출" --body "$(cat <<'EOF'
## Summary
- 뽐뿌 키워드 푸시 알림 백엔드(별도 PR)가 같은 파서를 import해서 쓸 수 있도록, \`PpomppuParser\`/\`BoardParser\`/관련 모델을 Local SPM 패키지 \`NuntingCore\`(루트의 \`Shared/\`)로 추출.
- iOS 앱은 \`import NuntingCore\` 한 줄로 동일 타입 사용. 기능 변화 0인 pure refactor.

## Test plan
- [ ] \`cd Shared && swift test\` — NuntingCoreTests PASS
- [ ] \`xcodebuild -scheme nunting ... test\` — 기존 iOS 테스트 전부 PASS
- [ ] 시뮬레이터에서 보드 리스트, 글 상세, 댓글 로딩 (이전과 동일하게 동작하는지)
- [ ] Spec: \`docs/superpowers/specs/2026-05-12-ppomppu-keyword-push-design.md\` "디렉터리 / 패키지 구조" 절과 일치

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

푸시 명령은 사용자 명시 승인 후에만 실행 (memory rule: no-auto-push).

---

## Self-Review 체크리스트

플랜 실행자가 한 번 더 점검할 항목:

- [ ] `Shared/Package.swift`의 `swift-tools-version`이 5.9 이상인지 (iOS 17 platform 명시 위함).
- [ ] `Post`, `Board`, `Site`, `Comment`, `BoardParser`, `ParserText`, `PpomppuParser`의 모든 외부 사용 멤버가 `public`. (private/internal 내부 헬퍼는 그대로.)
- [ ] iOS 앱과 테스트가 `import NuntingCore` 누락 없이 빌드/테스트 통과.
- [ ] Plan 1은 기능 변화 0. 시뮬레이터에서 기존 동작(보드 리스트, 상세, 영상 인라인) 그대로.
- [ ] `git log --oneline main..HEAD`로 7개 안팎의 명확한 커밋 메시지.
