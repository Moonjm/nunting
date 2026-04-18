import SwiftUI

struct SideDrawer: View {
    let favorites: FavoritesStore
    @Binding var selectedSection: DrawerSection
    let onSelectBoard: (Board) -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            siteRail
            Divider()
            boardsPanel
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var siteRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(DrawerSection.all) { section in
                    railItem(section: section)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 64)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func railItem(section: DrawerSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedSection = section
            }
        } label: {
            VStack(spacing: 4) {
                Text(section.shortLabel)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
            .frame(width: 64, height: 56)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
    }

    private var boardsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selectedSection.label)
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("닫기")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            if boards.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(boards) { board in
                            boardRow(board: board)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
            switch selectedSection {
            case .favorites:
                Text("즐겨찾기한 보드가 없어요")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("사이트 탭에서 ⭐ 별표로 추가하세요")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .site:
                Text("등록된 보드가 없어요")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var boards: [Board] {
        switch selectedSection {
        case .favorites: favorites.favoriteBoards()
        case .site(let s): Board.boards(for: s)
        }
    }

    private func boardRow(board: Board) -> some View {
        Button {
            onSelectBoard(board)
        } label: {
            HStack(spacing: 8) {
                Text(board.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
                if showSiteBadge {
                    siteBadge(site: board.site)
                }
                Button {
                    favorites.toggle(board)
                } label: {
                    Image(systemName: favorites.isFavorite(board) ? "star.fill" : "star")
                        .foregroundStyle(favorites.isFavorite(board) ? Color.yellow : Color.secondary.opacity(0.6))
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var showSiteBadge: Bool {
        if case .favorites = selectedSection { return true }
        return false
    }

    private func siteBadge(site: Site) -> some View {
        Text(site.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(site.accentColor.opacity(0.18), in: Capsule())
            .foregroundStyle(site.accentColor)
    }
}

extension Site {
    var accentColor: Color {
        switch self {
        case .clien: .blue
        case .coolenjoy: .orange
        case .inven: .red
        case .ppomppu: .green
        }
    }
}
