# Parser Abstraction — Pilot (Ppomppu + Bobae)

작성일: 2026-05-26
스코프: iOS 앱 (`nunting/Parsers/`) 만. Server는 이미 Go라 무관.

## 목표

`nunting/Parsers/*Parser.swift` 11개에 걸쳐 복붙된 본문 블록 워커(`collectBlocks` / `collectInlines` / `handleElement`) 를 공통 헬퍼로 분리. 이번 작업은 **파일럿** — `PpomppuParser` + `BobaeParser` 두 곳만 전환해 헬퍼 인터페이스 실전 검증 후, 향후 별개 작업으로 나머지 9개 파서 확산.

성공 기준:
- `ParserDetailTests`, `PpomppuParserSmokeTests`, `ParserDispatchTests` 모두 전환 전후 동일 결과.
- Ppomppu/Bobae 두 파일에서 본문 워커 코드 합산 ~200줄 감소.
- `BoardParser` protocol 자체는 건드리지 않음 — closure isolation 트랩(BoardParser.swift 1~19행 주석 참조) 회피.

## 비목표

- 11개 파서 전체 전환 (이번 작업 후 별도 결정)
- 페이지네이션 / 댓글 fetch / 디테일 메타 추출 추상화 (사이트별 차이가 진짜로 큼)
- 리스트 행 추출 추상화 (별도 작업)
- 베이스 protocol 자체 수정

## 아키텍처

### 신규 파일 1개

`nunting/Parsers/Support/ParserBlockWalker.swift`

```swift
public struct WalkerRules: Sendable {
    public var blockTags: Set<String>
    public var skipTags: Set<String>
    public var mediaTags: Set<String>

    public var resolveImageURL:  @Sendable (Element) throws -> URL?
    public var resolveVideoURL:  @Sendable (Element) throws -> URL?
    public var imageBlock:       @Sendable (URL) -> ContentBlock        // default: .image
    public var shouldEmitAnchor: @Sendable (URL) -> Bool                // default: { _ in true }

    public static let standard: WalkerRules
}

public struct ParserBlockWalker: Sendable {
    let parser: any BoardParser
    let rules: WalkerRules
    public func walk(_ root: Element) throws -> [ContentBlock]
}
```

`WalkerRules.standard` 기본값:
- `blockTags = ["p","div","li","blockquote","h1"..."h6","section","article","tr"]`
- `skipTags = ["script","style","noscript"]`
- `mediaTags = ["img","video","iframe"]`
- `resolveImageURL`: src → data-src → data-original 폴백
- `resolveVideoURL`: src → child `<source>`. media fragment 해시 strip 안 함(사이트별로 다름 → Bobae가 override).
- `imageBlock`: `.image($0)`
- `shouldEmitAnchor`: 항상 true

### 의존성

walker는 `parser: any BoardParser`를 명시 보유. 이유: base extension의 `anchor`, `isHidden`, `resolveHTTPURL`, `youtubeEmbedID`, `videoPoster`, `hasAnyDescendant` 가 site baseURL을 알아야 하는 instance method라 closure로 풀면 캡처가 부풀음. 명시적 의존성이 더 깔끔.

`parser`는 struct + Sendable이므로 참조 사이클/concurrency 위험 없음.

### Walker 동작 (단일 후위 순회)

- 자식 노드 순회 → Element/TextNode 분기
- Element 처리:
  - `isHidden(el)` → skip
  - `skipTags` 포함 → skip
  - `img` → `rules.resolveImageURL` → URL 있으면 inline flush 후 `rules.imageBlock(url)` 추가
  - `video` → `rules.resolveVideoURL` → URL 있으면 inline flush 후 `.video(url, posterURL: parser.videoPoster(...))` 추가
  - `iframe` → `parser.youtubeEmbedID(src)` 있으면 inline flush 후 `.embed(.youtube, id:)`
  - `a`:
    - 미디어 자식 가짐 → 재귀(자식이 미디어 블록으로 떠오름)
    - 미디어 없음 → `parser.anchor(from:)` 호출 → `rules.shouldEmitAnchor(url)` true 면 inline link 추가, false 면 누락
  - `br` → inline `\n`
  - 기타: 자식 재귀. 자식이 미디어 가지면 inline flush + 블록 재귀. 끝난 후 tag가 `blockTags` 면 `\n` stamp.
- TextNode → inline 텍스트 누적
- 종료 시 남은 inline 한 번 더 flush.

기존 Ppomppu 2-layer (`collectBlocks` + `collectInlines`) 구조를 1-layer로 통합. 검증은 `ParserDetailTests` 기존 fixture 결과 동일성.

## 호출자 적용

### Bobae

```swift
private func extractBlocks(in doc: Document) throws -> [ContentBlock] {
    let candidates: [Element?] = [
        try doc.select("article.article .article-body").first(),
        try doc.select(".article-body").first(),
        try doc.select("#body_frame").first(),
        try doc.select("article.article").first(),
    ]
    guard let wrap = candidates.compactMap({ $0 }).first else { return [] }

    var rules = WalkerRules.standard
    // resolveImageURL 은 standard 기본값(src → data-src → data-original) 과 정확히 일치 → override 불필요
    rules.resolveVideoURL = videoURL(from:)   // `#t=...` media fragment strip 들어간 로컬 헬퍼 유지
    return try ParserBlockWalker(parser: self, rules: rules).walk(wrap)
}
```

`collectBlocks` / `handleElement` / `flushInline` 삭제 (~65줄 ↓). `realImageURL` 도 standard 기본값으로 흡수되니 제거 가능. `videoURL`, `extractComments`, `extractTitle/Author/Date/Recommend/ViewCount` 는 그대로.

### Ppomppu

```swift
public func parseDetail(html: String, post: Post) throws -> PostDetail {
    let doc = try SwiftSoup.parse(html)
    guard let view = try doc.select("div.bbs.view, div.bbs_view, div.view").first() else {
        throw ParserError.structureChanged("bbs.view 없음")
    }
    guard let content = try view.select("div.cont#KH_Content, div#KH_Content, div.cont").first() else {
        throw ParserError.structureChanged("KH_Content 없음")
    }

    let dealAnchor = try dealAnchor(from: view)
    var blocks: [ContentBlock] = []
    if let dealAnchor {
        blocks.append(.dealLink(dealAnchor.url, label: dealAnchor.label))
    }

    let skipURL = dealAnchor?.url
    var rules = WalkerRules.standard
    rules.resolveImageURL  = imageURL(from:)
    rules.resolveVideoURL  = videoURL(from:)
    rules.imageBlock       = imageOrVideoBlock(for:)
    rules.shouldEmitAnchor = { url in url != skipURL }

    let body = try ParserBlockWalker(parser: self, rules: rules).walk(content)
    blocks.append(contentsOf: body)

    // ... 나머지 header/viewCount 추출 그대로
}
```

`collectBlocks` / `collectInlines` 삭제 (~140줄 ↓). `imageURL`, `videoURL`, `imageOrVideoBlock`, `dealAnchor`, 댓글/페이지네이션 로직 모두 유지.

## 마이그레이션 커밋 단위

1. `ParserBlockWalker` 신규 파일 추가 (호출자 0). 빌드 통과.
2. Bobae 전환. `ParserDetailTests` Bobae 케이스 통과.
3. Ppomppu 전환. `ParserDetailTests` + `PpomppuParserSmokeTests` 통과.
4. `nuntingTests/Parsers/ParserBlockWalkerTests.swift` 추가.

각 커밋 독립 revert 가능. 1번은 호출자 0이라 revert해도 무피해.

## 테스트 전략

**기존 회귀 안전망 (1차 합격선)**:
- `nuntingTests/ParserDetailTests.swift` — fixture 기반 detail 파싱 검증. 전환 전후 결과 동일 필수.
- `nuntingTests/PpomppuParserSmokeTests.swift` — 라이브 HTML 스냅샷 list+detail.
- `nuntingTests/ParserDispatchTests.swift` — `any BoardParser` existential dispatch 검증.

**신규 단위 테스트** — `nuntingTests/Parsers/ParserBlockWalkerTests.swift`:

1. 텍스트만 있는 트리 → 단일 `.richText`
2. `<br>` → richText 안 `\n`
3. `<img>` 만나면 직전 richText flush + image 블록 (순서 보존)
4. `<a>`가 `<img>` 감싸면 anchor 라벨 무시, 이미지 블록만 출력
5. `<iframe>` YouTube → `.embed(.youtube, id:)`
6. `display:none` 안의 이미지 가지치기
7. blockTags 자식 후 `\n` stamp
8. `shouldEmitAnchor` false → 해당 anchor 누락, 텍스트 흐름 유지
9. `imageBlock` custom → `.video`로 변환 (Ppomppu .mov 케이스 시뮬)
10. `resolveImageURL` nil → img 블록 생성 안 함

~150줄 예상.

**검증 명령**: `xcodebuild test -scheme nunting -destination 'platform=iOS Simulator,name=...'`.

## 위험 신호 / 중단 조건

- Bobae 전환 후 `ParserDetailTests` ContentBlock 배열이 미묘하게 다름 (richText segment 경계, blank line 개수) → walker flush 타이밍 점검. Ppomppu 2-layer / Bobae 1-layer가 다르게 짜여 있어서 통합 시 어긋날 가능성.
- closure capture로 자기참조 cycle: parser가 struct라 불가능하지만, walker 내부에서 inout 상태를 closure가 캡처하면 컴파일 거부. 발견 시 인터페이스 재검토.
- walker가 사이트별 기존 quirk을 흡수 못 함 → 그 사이트는 전환 대상에서 제외하고 walker 인터페이스 추가 hook 검토.

## YAGNI — 지금 안 만드는 것

- `customElementHandler: (Element) -> WalkerAction?` 같은 generic escape hatch. Aagag/Etoland로 확산할 때 필요해지면 그때 추가.
- 리스트 행 추출 / 디테일 메타 추출 / 댓글 워커 추상화.
- 베이스 protocol 신설 / 변경.
