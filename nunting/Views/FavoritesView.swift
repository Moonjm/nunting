import SwiftUI

struct FavoritesView: View {
    var body: some View {
        ContentUnavailableView {
            Label("모음", systemImage: "star")
        } description: {
            Text("즐겨찾기한 게시판의 최신 글을 여기서 모아볼 수 있어요.")
        } actions: {
            Text("탐색 탭에서 ⭐ 토글로 즐겨찾기 추가 (준비 중)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
