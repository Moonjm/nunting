import Foundation
import FoundationModels
import Observation

/// 온디바이스 요약 프롬프트 조립 — 순수 로직이라 모델 없이 테스트된다.
///
/// 예산 근거: 온디바이스 모델 컨텍스트가 작다(iOS 26 기준 ~4K 토큰, 한국어
/// ~1.5-2자/토큰). instructions + 프롬프트 + 출력이 다 그 안에 들어야 하므로
/// 본문 3,500자 + 베스트 댓글 5개×150자로 입력을 자른다 — 초과 입력은
/// 세션이 exceededContextWindowSize 로 통째로 실패한다.
nonisolated enum PostSummaryPrompt {
    static let maxBodyChars = 3_500
    static let maxComments = 5
    static let maxCommentChars = 150

    /// 세션 instructions. 프롬프트가 아니라 세션 생성 시 1회 주입 — 모델이
    /// 유저 컨텐츠(프롬프트)보다 우선하도록 프레임워크가 보장하는 자리다.
    static let instructions = """
    당신은 한국 커뮤니티 글을 요약하는 도우미입니다. 주어진 글(과 있다면 \
    베스트 댓글)을 한국어로 요약하세요. 핵심 내용을 2~4문장으로 간결하게 \
    정리하고, 댓글이 있으면 전체적인 반응을 한 문장 덧붙이세요. 과장하거나 \
    없는 내용을 지어내지 마세요.
    """

    /// 자동 요약 최소 본문 길이(글자). 미만이면 요약 UI 자체를 만들지
    /// 않는다 — 한눈에 읽히는 글에서 요약은 노이즈고, 자동 실행 구조라
    /// 짧은 글마다 3~6초 생성을 도는 낭비도 크다.
    static let autoSummarizeMinChars = 600

    /// 본문 텍스트 길이 기준 자동 요약 대상 판정. 미디어 블록은 길이에
    /// 안 섞인다 — 이미지 위주 글은 요약할 프로즈가 없다.
    static func qualifiesForAutoSummary(_ detail: PostDetail) -> Bool {
        bodyText(from: detail.blocks).count >= autoSummarizeMinChars
    }

    static func build(detail: PostDetail) -> String {
        let title = detail.fullTitle ?? detail.post.title
        let body = String(bodyText(from: detail.blocks).prefix(maxBodyChars))

        var prompt = """
        제목: \(title)

        본문:
        \(body)
        """

        let top = representativeComments(detail.comments)
        if !top.isEmpty {
            prompt += "\n\n베스트 댓글:"
            for c in top {
                prompt += "\n- (공감 \(c.likeCount)) \(String(c.content.prefix(maxCommentChars)))"
            }
        }
        return prompt
    }

    /// 요약에 실을 대표 댓글 `maxComments` 개. **공감 내림차순**으로
    /// 돌려준다(동점은 원본 순서 유지) — 모델이 프롬프트 앞줄을 대표로
    /// 인용하는 경향이 있어서, 고르게 뽑아 놓고 시간순으로 실었더니 결국
    /// 첫 댓글이 다시 요약을 대표했다. 앞줄이 곧 가장 공감받은 댓글이게 한다.
    ///
    /// 단순 "공감 내림차순 prefix" 였을 때의 버그: 공감이 전부 0인 스레드
    /// (aagag 이슈판이 대표적)는 전 항목이 동점이라 정렬이 사실상
    /// no-op 이고, 그러면 **첫 5개 댓글**만 실려 요약의 "반응" 문장이 맨 위
    /// 댓글 몇 개만 대표했다. 그래서 두 단계로 뽑는다:
    /// 1. 공감이 붙은 댓글을 공감순으로 — 신호가 있으면 그게 대표다.
    /// 2. 남는 자리는 나머지에서 **고르게** 샘플링 — 앞에서 자르지 않는다.
    static func representativeComments(_ comments: [PostComment]) -> [PostComment] {
        let candidates = comments.filter { !$0.content.isEmpty }
        guard candidates.count > maxComments else { return byLikesDescending(candidates) }

        let liked = candidates.filter { $0.likeCount > 0 }
            .sorted { $0.likeCount > $1.likeCount }
            .prefix(maxComments)
        let pickedIDs = Set(liked.map(\.id))
        let rest = candidates.filter { !pickedIDs.contains($0.id) }
        let fill = evenSample(rest, count: maxComments - liked.count)

        let chosen = pickedIDs.union(fill.map(\.id))
        return byLikesDescending(candidates.filter { chosen.contains($0.id) })
    }

    /// 공감 내림차순 정렬. Swift 의 sort 는 unstable 이라 동점 순서를
    /// 보장하지 않는데, 공감이 전부 0인 스레드에서는 **동점이 곧 전부**라
    /// 고르게 뽑아 둔 표본이 뒤섞인다 — 인덱스로 동점을 깨 원본 순서를
    /// 유지한다.
    private static func byLikesDescending(_ comments: [PostComment]) -> [PostComment] {
        comments.enumerated()
            .sorted { a, b in
                a.element.likeCount == b.element.likeCount
                    ? a.offset < b.offset
                    : a.element.likeCount > b.element.likeCount
            }
            .map(\.element)
    }

    /// 배열 전체에 고르게 퍼진 `count` 개를 원본 순서로 뽑는다 — 앞/뒤
    /// 어느 쪽으로도 치우치지 않게 각 구간의 중앙을 집는다.
    private static func evenSample(_ items: [PostComment], count: Int) -> [PostComment] {
        guard count > 0 else { return [] }
        guard items.count > count else { return items }
        return (0..<count).map { i in
            items[(2 * i + 1) * items.count / (2 * count)]
        }
    }

    /// 본문 블록에서 요약 입력용 텍스트만 추출 — richText 의 텍스트/링크
    /// 라벨을 잇고 미디어(image/video/embed)는 건너뛴다.
    static func bodyText(from blocks: [ContentBlock]) -> String {
        blocks.compactMap { block -> String? in
            guard case .richText(let segments) = block.kind else { return nil }
            let joined = segments.map { seg in
                switch seg {
                case .text(let s): s
                case .link(_, let label): label
                }
            }.joined()
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n")
    }
}

/// 상세 화면의 온디바이스 요약 상태 머신. FoundationModels 세션을 감싸
/// 스트리밍 스냅샷을 `text` 로 흘리고, 뷰는 `state` 만 렌더한다.
///
/// 프로토타입 노트: 모델 가용성(기기 티어·Apple Intelligence 설정·모델
/// 다운로드 상태)은 `SystemLanguageModel.default.availability` 가 판별한다.
/// 미지원 환경에서는 버튼 자체를 숨긴다.
@Observable
@MainActor
final class PostSummarizer {
    enum State: Equatable {
        case idle
        /// 스트리밍 중 — associated value 가 누적 스냅샷 텍스트.
        case streaming(String)
        case done(String)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// post.id → 완성 요약 캐시. 오버레이 keep-alive 로 이 인스턴스가 세션
    /// 내내 살아 있으므로, 목록↔상세 재진입마다 같은 글의 3~6초 생성을
    /// 반복하지 않게 한다. 실패는 캐시하지 않는다(재진입이 재시도 기회).
    private var completed: [String: String] = [:]
    /// 캐시 상한 — 초과 시 통째 비움. LRU 를 갖출 만큼 크지 않은 프로토타입.
    private static let cacheCap = 50

    /// 세대 토큰 — 글 전환/무효화마다 증가. keep-alive 로 살아남은 낡은
    /// 태스크(폴링 대기·모델 스트리밍 중)가 전환 이후에 상태/캐시를 밀어
    /// 넣는 레이스를 막는다: 모든 await 재개 지점에서 자기 세대를 비교해,
    /// 밀렸으면 어떤 쓰기도 없이 조용히 종료한다.
    private var generation = 0
    /// 마지막으로 요약을 시작한 글. 뷰의 reset 태스크와 카드 태스크는 실행
    /// 순서가 보장되지 않으므로, 전환 감지를 외부 reset 에 맡기지 않고
    /// `summarizeIfNeeded` 가 postID 변화로 직접 한다 — reset 이 늦게 와도
    /// (혹은 안 와도) 새 글 태스크가 이전 non-idle 상태에 막혀 "요약 중"
    /// 으로 멈추는 일이 없다.
    private var currentPostID: String?

    /// 생성 시임 — `(프롬프트, 스냅샷 콜백) → 완성 요약`. 프로덕션은 아래
    /// `liveGenerate`(FoundationModels 세션), 테스트는 결정적 fake 를 주입해
    /// 모델 없이 라이프사이클 레이스를 검증한다.
    typealias Generate = @MainActor (
        _ prompt: String,
        _ onSnapshot: @MainActor (String) -> Void
    ) async throws -> String

    private let generate: Generate
    /// 요청 글 detail 커밋 + 댓글 병합을 기다리는 폴 간격/횟수. 기본
    /// 700ms×11 ≈ 7.7s — 로드가 그보다 느리면 자동 요약을 포기한다
    /// (재진입이 다음 기회). 테스트는 짧게 주입.
    private let pollInterval: Duration
    private let maxPolls: Int

    init(
        generate: @escaping Generate = PostSummarizer.liveGenerate,
        pollInterval: Duration = .milliseconds(700),
        maxPolls: Int = 11
    ) {
        self.generate = generate
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
    }

    /// 요약 카드 노출 여부. unavailable 사유는 프로토타입에선 구분 없이 숨김
    /// (deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady).
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// 카드가 렌더할 상태 — 요청 글과 `currentPostID` 가 일치할 때만 실제
    /// 상태를 노출한다. 긴 글→긴 글 전환 시 새 카드의 첫 렌더는 .task 의
    /// 자체 전환보다 먼저라, 공유 인스턴스에 남은 이전 글의 done/failed 를
    /// 그대로 렌더하면 이전 글 요약/에러 UI 가 새 글에 잠깐 보인다 —
    /// 불일치면 idle("요약 중" 자리)로 렌더하고, 곧 태스크의 자체 전환이
    /// 실제 상태로 채운다.
    func displayState(for postID: String) -> State {
        currentPostID == postID ? state : .idle
    }

    /// 카드 마운트 게이트 — 로드된 detail 이 **현재 글**이고 임계 길이를
    /// 넘을 때만. keep-alive 전환 중 로더는 이전 글 detail 을 노출하는데,
    /// 그 스냅샷으로 마운트하면 새 글 로드가 느리거나 실패할 때 "요약 중…"
    /// 카드가 영구히 남는다(폴 소진 후 idle, 같은 task id 라 재발화 없음).
    /// 현재 글 detail 커밋 시점에 카드가 처음 마운트되며 .task 가 발화하므로
    /// 그 경로 자체가 사라진다.
    nonisolated static func shouldShowCard(post: Post, loadedDetail: PostDetail?) -> Bool {
        guard let loadedDetail, loadedDetail.post.id == post.id else { return false }
        return PostSummaryPrompt.qualifiesForAutoSummary(loadedDetail)
    }

    /// 자동 실행 진입점 — 카드 `.task` 가 부른다. 캐시 히트면 생성 없이
    /// 복원, idle 이 아니면(이미 스트리밍/완료) 아무것도 안 한다.
    ///
    /// `latestDetail` 클로저 + 폴링인 이유 두 가지:
    /// - keep-alive 재진입 직후엔 로더가 **이전 글의** detail 을 노출한다
    ///   (새 로드 커밋 전) — 그대로 쓰면 이전 글 요약이 새 postID 로
    ///   캐시된다. 요청 글(post.id == postID)의 detail 이 커밋될 때까지
    ///   기다렸다 생성한다.
    /// - 본문 commit 직후엔 댓글이 병합 전이라, 한 박자 뒤 최신 스냅샷을
    ///   읽어야 반응 요약까지 실린다.
    func summarizeIfNeeded(postID: String, latestDetail: () -> PostDetail?) async {
        // 글 전환 자체 감지 — 이전 글의 non-idle 상태/진행 중 태스크를
        // 무효화하고 새 글로 넘어간다 (`currentPostID` 주석 참조).
        if currentPostID != postID {
            currentPostID = postID
            generation += 1
            state = .idle
        }
        if let cached = completed[postID] {
            state = .done(cached)
            return
        }
        guard state == .idle else { return }
        let gen = generation
        state = .streaming("")

        var matched: PostDetail?
        for _ in 0..<maxPolls {
            try? await Task.sleep(for: pollInterval)
            // 카드가 사라지거나 id 가 바뀌면 SwiftUI 가 .task 를 취소한다 —
            // sleep 의 throw 를 try? 로 삼키므로 여기서 명시적으로 끊는다.
            // 현재 세대면 idle 로 되돌린다: streaming("") 을 남기면 같은 글
            // 재진입 시(긴 글→짧은 글→다시 긴 글, currentPostID 불변) 새
            // 태스크가 non-idle 가드에 막혀 "요약 중…" 이 영구 표시된다.
            if Task.isCancelled {
                if gen == generation { state = .idle }
                return
            }
            guard gen == generation else { return } // 글 전환됨 — 쓰기 금지
            guard let d = latestDetail(), d.post.id == postID else { continue }
            matched = d
            // 목록이 댓글 존재(commentCount>0)를 예고했는데 아직 병합 전이면
            // 조금 더 기다린다 — 댓글 leg 는 본문 commit 뒤에 병합되므로 첫
            // 매칭 스냅샷으로 확정하면 "반응 한 줄"이 영구히 빠진다. 윈도를
            // 소진하면(느린 다페이지 댓글·leg 실패) 마지막 스냅샷, 즉 본문
            // 만으로라도 생성한다.
            if d.comments.isEmpty && d.post.commentCount > 0 { continue }
            break
        }
        guard let detail = matched else {
            // 요청 글 detail 이 폴 윈도 안에 안 왔다 — 조용히 포기.
            if gen == generation { state = .idle }
            return
        }

        await run(detail: detail, gen: gen)
        cacheIfDone(postID: postID, gen: gen)
    }

    /// 실패 카드의 "다시 시도" — 화면에 떠 있는 카드의 detail 로 즉시 재생성.
    /// 성공하면 summarizeIfNeeded 와 동일하게 캐시한다 — 안 하면 다른 글
    /// 갔다 재진입할 때 같은 글을 또 생성한다.
    func retry(detail: PostDetail) async {
        guard state != .idle, !isStreaming else { return }
        let gen = generation
        state = .streaming("")
        await run(detail: detail, gen: gen)
        cacheIfDone(postID: detail.post.id, gen: gen)
    }

    /// pull-to-refresh 등으로 같은 post.id 의 본문/댓글이 교체된 경우 —
    /// 캐시를 버리고 다음 summarizeIfNeeded 가 새 detail 로 재생성하게 한다.
    /// 세대/상태 리셋은 **현재 글일 때만**: 글 A 의 늦은 새로고침 완료가
    /// B 로 전환된 뒤 도착하면 A 캐시만 지워야지, 무조건 리셋하면 B 의
    /// 진행 중 생성을 죽이고 B 의 .task 는 재발화가 없어 카드가 멈춘다.
    func invalidate(postID: String) {
        completed.removeValue(forKey: postID)
        guard currentPostID == postID else { return }
        generation += 1
        state = .idle
    }

    private func cacheIfDone(postID: String, gen: Int) {
        guard gen == generation, case .done(let text) = state else { return }
        if completed.count >= Self.cacheCap { completed.removeAll() }
        completed[postID] = text
    }

    private var isStreaming: Bool {
        if case .streaming = state { return true }
        return false
    }

    /// 생성 공통부. 모든 상태 쓰기는 `gen` 이 현재 세대일 때만 — 스트리밍
    /// 콜백 포함(await 재개마다 낡은 태스크일 수 있다).
    private func run(detail: PostDetail, gen: Int) async {
        state = .streaming("")
        let prompt = PostSummaryPrompt.build(detail: detail)
        do {
            let text = try await generate(prompt) { [weak self] snapshot in
                guard let self, gen == self.generation else { return }
                self.state = .streaming(snapshot)
            }
            guard gen == generation else { return }
            state = text.isEmpty
                ? .failed("요약 결과가 비어 있어요.")
                : .done(text)
        } catch {
            guard gen == generation else { return }
            // 생성 중 .task 취소(글 전환)는 실패가 아니다 — failed 로 남기면
            // 재진입 자동 실행이 non-idle 가드에 막힌다(폴 취소와 동일 규율).
            if error is CancellationError {
                state = .idle
                return
            }
            state = .failed(Self.failureMessage(for: error))
        }
    }

    /// 실패 카드에 띄울 한 줄. 가드레일 거부는 유저 잘못도 우리 버그도
    /// 아니라 "이 글은 모델이 안 다룬다"는 사실이라, 영문 원문(the model's
    /// safety guardrails were triggered)을 노출하지 않고 사실만 전한다.
    /// 나머지는 원인 파악이 필요하니 원문을 붙인다.
    nonisolated static func failureMessage(for error: Error) -> String {
        if let generationError = error as? LanguageModelSession.GenerationError,
           case .guardrailViolation = generationError {
            return "민감한 내용이 있어 요약을 건너뛰었어요."
        }
        return "요약할 수 없어요 (\(error.localizedDescription))"
    }

    /// FoundationModels 스트리밍 — ResponseStream 스냅샷은 델타가 아니라
    /// **누적** 본문이라 콜백에 그대로 넘긴다.
    ///
    /// 가드레일을 `permissiveContentTransformations` 로 낮춘다: 기본
    /// 프로파일은 한국 커뮤니티 글(사건사고·비속어 섞인 본문과 댓글)을
    /// 자주 거부해 멀쩡한 글이 통째로 요약 실패했다. 우리가 새 내용을
    /// 만드는 게 아니라 **유저가 이미 보고 있는 글을 압축**하는 용도라
    /// Apple 이 이 프로파일을 두는 바로 그 케이스다. 출력 쪽 필터는 그대로
    /// 남으므로 거부가 0 이 되지는 않는다 — failureMessage 가 받는다.
    @MainActor
    static func liveGenerate(
        prompt: String,
        onSnapshot: @MainActor (String) -> Void
    ) async throws -> String {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: PostSummaryPrompt.instructions)
        var latest = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            latest = snapshot.content
            onSnapshot(latest)
        }
        return latest
    }

    /// 글 전환 시 호출 — 상태를 비우고 세대를 올려, 진행 중이던 낡은
    /// 태스크의 이후 상태/캐시 쓰기를 전부 무효화한다.
    func reset() {
        generation += 1
        state = .idle
    }
}
