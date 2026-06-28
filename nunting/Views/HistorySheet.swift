import SwiftUI

/// 하단에서 올라오는 최근 읽은 글 시트(검색 시트와 같은 버튼+시트 형태). 최근 연
/// 글 몇 개를 목록으로 보여주고, 탭하면 그 글을 다시 연다(상세 오버레이 → 재로딩).
/// 하단 탭이 아니라 버튼이 띄우는 시트라 탭 전환 바운스/깜빡임이 없다. 출처가
/// 여러 보드에 걸쳐 있어 행마다 사이트를 함께 표시한다.
struct HistorySheet: View {
    let posts: [Post]
    /// 행 탭 → 시트를 닫고 상세를 띄우기 위해 부모가 주입.
    let onOpen: (Post) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if posts.isEmpty {
                    ContentUnavailableView("최근 읽은 글이 없어요", systemImage: "clock",
                                           description: Text("글을 열어보면 여기에 쌓여요."))
                } else {
                    List(posts) { post in
                        Button { onOpen(post) } label: { HistoryRow(post: post) }
                            .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("최근 읽음")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct HistoryRow: View {
    let post: Post
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(post.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                Circle().fill(post.site.accentColor).frame(width: 7, height: 7)
                Text(post.site.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !post.author.isEmpty {
                    Text("· \(post.author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        // 행 전체(빈 공간 포함)를 탭 영역으로 — 텍스트 밖을 눌러도 이동되게.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
