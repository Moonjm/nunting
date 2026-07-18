import SwiftUI

/// 상세 본문 위의 온디바이스 AI 요약 카드 (프로토타입).
///
/// idle 에선 작은 "AI 요약" 칩만 차지하고, 탭하면 그 자리가 카드로 바뀌며
/// 스트리밍 스냅샷이 차오른다 — 첫 문장이 1~2초 안에 보이기 시작하므로
/// 전체 생성(3~5초)을 기다리는 느낌이 없다. 모델 미지원 환경(구형 기기·
/// Apple Intelligence 꺼짐)에서는 호출부가 이 뷰 자체를 만들지 않는다.
struct PostSummaryCard: View {
    let summarizer: PostSummarizer
    let detail: PostDetail

    var body: some View {
        switch summarizer.state {
        case .idle:
            Button {
                Task { await summarizer.summarize(detail: detail) }
            } label: {
                Label("AI 요약", systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color("AppSurface2"), in: Capsule())
            }
            .buttonStyle(.plain)

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
                        summarizer.reset()
                        Task { await summarizer.summarize(detail: detail) }
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
