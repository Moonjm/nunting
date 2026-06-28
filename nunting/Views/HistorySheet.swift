import SwiftUI

/// 최근 읽은 글 목록. 하단 히스토리 탭(role:.search)이 fullScreenCover 로 띄운다.
/// 전체 화면으로 덮으므로 탭 선택 바운스(깜빡임)가 뒤에 가려 안 보인다. 글을
/// 탭하면 그 글을 다시 연다(상세 오버레이). 닫기 버튼으로 내린다. 출처가 여러
/// 보드에 걸쳐 있어 행마다 사이트를 함께 표시한다.
struct HistorySheet: View {
    let posts: [Post]
    /// 행 탭 → 커버를 닫고 상세를 띄우기 위해 부모가 주입.
    let onOpen: (Post) -> Void
    @Environment(\.dismiss) private var dismiss

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
            // fullScreenCover 는 스와이프 닫기가 없어 명시적 닫기 버튼을 둔다.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
            // 모음/알림과 같은 처리 — 배경을 깔아 톤 일체감.
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
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
