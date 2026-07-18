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

    /// 요약 버튼 노출 여부. unavailable 사유는 프로토타입에선 구분 없이 숨김
    /// (deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady).
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    func summarize(detail: PostDetail) async {
        if case .streaming = state { return }
        state = .streaming("")
        let prompt = PostSummaryPrompt.build(detail: detail)
        let session = LanguageModelSession(instructions: PostSummaryPrompt.instructions)
        do {
            var latest = ""
            // ResponseStream 스냅샷은 델타가 아니라 **누적** 본문 — 그대로 대입.
            for try await snapshot in session.streamResponse(to: prompt) {
                latest = snapshot.content
                state = .streaming(latest)
            }
            state = latest.isEmpty
                ? .failed("요약 결과가 비어 있어요.")
                : .done(latest)
        } catch {
            // guardrail 거부(민감 주제)·컨텍스트 초과 등 — 프로토타입에선
            // 한 줄 안내로 뭉뚱그린다.
            state = .failed("요약할 수 없어요 (\(error.localizedDescription))")
        }
    }

    func reset() {
        state = .idle
    }
}
