import SwiftUI

/// 상세 본문 위의 온디바이스 AI 요약 카드 (프로토타입).
///
/// 자동 실행 — 임계 길이(`PostSummaryPrompt.autoSummarizeMinChars`) 이상인
/// 글에서만 호출부가 카드를 만들고, 카드가 뜨는 즉시 `.task` 로 생성이
/// 시작돼 스트리밍 스냅샷이 차오른다. 첫 문장이 1~2초 안에 보이기
/// 시작하므로 전체 생성(3~5초)을 기다리는 느낌이 없다. 짧은 글·모델
/// 미지원 환경에서는 카드 자체가 없다.
struct PostSummaryCard: View {
    let summarizer: PostSummarizer
    let detail: PostDetail

    var body: some View {
        switch summarizer.state {
        case .idle:
            // 자동 실행 task 가 붙기 전의 찰나 — 스트리밍 대기와 동일하게.
            card {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("요약 중…").font(.caption).foregroundStyle(.secondary)
                }
            }

        case .streaming(let text):
            card {
                if text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("요약 중…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    summaryText(text)
                }
            }

        case .done(let text):
            card { summaryText(text) }

        case .failed(let message):
            card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("다시 시도") {
                        // reset() 을 부르지 않는 이유: reset 은 글 전환용으로
                        // 세대를 올려 버려, 같은 글 재시도가 자기 세대 검사에
                        // 걸린다. retry 는 현재 세대 안에서 재생성한다.
                        Task { await summarizer.retry(detail: detail) }
                    }
                    .font(.caption.weight(.medium))
                }
            }
        }
    }

    private func summaryText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI 요약", systemImage: "sparkles")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color("AppSurface2"), in: RoundedRectangle(cornerRadius: 10))
    }
}
