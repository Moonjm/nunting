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

        let top = detail.comments
            .filter { !$0.content.isEmpty }
            .sorted { $0.likeCount > $1.likeCount }
            .prefix(maxComments)
        if !top.isEmpty {
            prompt += "\n\n베스트 댓글:"
            for c in top {
                prompt += "\n- (공감 \(c.likeCount)) \(String(c.content.prefix(maxCommentChars)))"
            }
        }
        return prompt
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
            if Task.isCancelled { return }
            guard gen == generation else { return } // 글 전환됨 — 쓰기 금지
            if let d = latestDetail(), d.post.id == postID {
                matched = d
                break
            }
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
    func invalidate(postID: String) {
        completed.removeValue(forKey: postID)
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
            // guardrail 거부(민감 주제)·컨텍스트 초과 등 — 프로토타입에선
            // 한 줄 안내로 뭉뚱그린다.
            guard gen == generation else { return }
            state = .failed("요약할 수 없어요 (\(error.localizedDescription))")
        }
    }

    /// FoundationModels 스트리밍 — ResponseStream 스냅샷은 델타가 아니라
    /// **누적** 본문이라 콜백에 그대로 넘긴다.
    @MainActor
    static func liveGenerate(
        prompt: String,
        onSnapshot: @MainActor (String) -> Void
    ) async throws -> String {
        let session = LanguageModelSession(instructions: PostSummaryPrompt.instructions)
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
