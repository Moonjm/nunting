import SwiftUI

struct BoardPickerSheet: View {
    let favorites: FavoritesStore
    let onSelect: (Board) -> Void

    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Site.allCases) { site in
                    let boards = filteredBoards(for: site)
                    if !boards.isEmpty {
                        Section {
                            ForEach(boards) { board in
                                BoardPickerRow(
                                    board: board,
                                    isFavorite: favorites.isFavorite(board),
                                    onToggleFavorite: { favorites.toggle(board) },
                                    onSelect: {
                                        onSelect(board)
                                        dismiss()
                                    }
                                )
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Circle().fill(site.accentColor).frame(width: 8, height: 8)
                                Text(site.displayName)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "보드 또는 사이트 검색")
            .navigationTitle("전체 보드")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }

    private func filteredBoards(for site: Site) -> [Board] {
        let all = Board.boards(for: site)
        guard !searchText.isEmpty else { return all }
        let query = searchText
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || site.displayName.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct BoardPickerRow: View {
    let board: Board
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)

            Button(action: onSelect) {
                HStack {
                    Text(board.name)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.caption.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
