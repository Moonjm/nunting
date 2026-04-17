import SwiftUI

struct ContentView: View {
    @State private var favorites = FavoritesStore()
    @State private var selectedBoard: Board?
    @State private var showPicker = false

    private var favoriteBoards: [Board] {
        favorites.favoriteBoards()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BoardChipBar(
                    boards: favoriteBoards,
                    selection: $selectedBoard,
                    onBrowseAll: { showPicker = true }
                )
                Divider()
                mainContent
            }
            .navigationTitle(selectedBoard?.name ?? "눈팅")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Post.self) { post in
                PostDetailView(post: post)
            }
            .sheet(isPresented: $showPicker) {
                BoardPickerSheet(
                    favorites: favorites,
                    onSelect: { selectedBoard = $0 }
                )
            }
        }
        .onAppear(perform: seedSelectionIfNeeded)
        .onChange(of: favoriteBoards) { _, newBoards in
            if selectedBoard == nil, let first = newBoards.first {
                selectedBoard = first
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let board = selectedBoard {
            BoardListView(board: board)
        } else if favoriteBoards.isEmpty {
            ContentUnavailableView {
                Label("즐겨찾기한 보드가 없어요", systemImage: "star")
            } description: {
                Text("우측 상단 ≡ 버튼으로 전체 목록에서 보드를 고르세요")
            }
        } else {
            ContentUnavailableView("보드를 선택하세요", systemImage: "list.bullet")
        }
    }

    private func seedSelectionIfNeeded() {
        guard selectedBoard == nil else { return }
        selectedBoard = favoriteBoards.first
    }
}

#Preview {
    ContentView()
}
