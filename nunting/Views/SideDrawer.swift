import SwiftUI

struct SideDrawer: View {
    let favorites: FavoritesStore
    let catalog: BoardCatalogStore
    let currentBoardID: String?
    @Binding var selectedSection: DrawerSection
    let onSelectBoard: (Board) -> Void
    let onClose: () -> Void

    /// Per-section persistent expand/collapse state. Keyed by
    /// `"<section.id>|<group.id>"`. JSON-encoded Set on disk; we keep an
    /// in-memory Set so per-row `isCollapsed` reads stay O(1) instead of
    /// re-parsing the raw string on every render pass.
    @AppStorage("drawer.collapsedGroups.v2")
    private var collapsedGroupsRaw: String = "[]"

    @State private var collapsedGroups: Set<String> = []
    @State private var collapsedHydrated: Bool = false

    @State private var favoritesEditMode: EditMode = .inactive

    var body: some View {
        HStack(spacing: 0) {
            siteRail
            Divider()
            boardsPanel
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            // Hydrate the in-memory Set once. Subsequent writes go through
            // setCollapsed which keeps both copies in sync.
            guard !collapsedHydrated else { return }
            if let data = collapsedGroupsRaw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                collapsedGroups = Set(decoded)
            }
            collapsedHydrated = true
        }
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
        .frame(width: 48)
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
            .frame(width: 48, height: 56)
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
            panelHeader
            Divider()

            if case .site(let s) = selectedSection, let err = catalog.error(for: s) {
                Text("메뉴 불러오기 실패: \(err)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            let sectionGroups = currentGroups
            if sectionGroups.allSatisfy({ $0.boards.isEmpty }) {
                emptyState
            } else if case .favorites = selectedSection {
                favoritesList(boards: sectionGroups.flatMap(\.boards))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sectionGroups) { group in
                            groupSection(group: group)
                        }
                    }
                }
            }
        }
        .task(id: selectedSection.id) {
            if case .site(let s) = selectedSection {
                await catalog.loadIfNeeded(s)
                // Refresh persisted favorite snapshots in case the upstream
                // catalog renamed or moved any matching board.
                favorites.merge(boards: catalog.boards(for: s))
            }
        }
        .onChange(of: selectedSection) { _, _ in
            favoritesEditMode = .inactive
        }
    }

    private var panelHeader: some View {
        HStack {
            Text(selectedSection.label)
                .font(.headline)
            if case .site(let s) = selectedSection, catalog.isLoading(s) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 4)
            }
            Spacer()
            if case .favorites = selectedSection {
                Button {
                    withAnimation {
                        favoritesEditMode = (favoritesEditMode == .active) ? .inactive : .active
                    }
                } label: {
                    Text(favoritesEditMode == .active ? "완료" : "편집")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(favoritesEditMode == .active ? "편집 완료" : "순서 편집")
            } else {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("닫기")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func favoritesList(boards: [Board]) -> some View {
        List {
            ForEach(boards) { board in
                boardRow(board: board)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                    .listRowBackground(rowBackground(for: board))
                    .listRowSeparator(.visible, edges: .bottom)
                    .listRowSeparatorTint(Color(uiColor: .separator).opacity(0.45))
                    // Hide the leading delete affordance — favorites are
                    // managed via the star toggle, so the row only needs the
                    // trailing reorder handle in edit mode. Tightens the row
                    // chrome significantly.
                    .deleteDisabled(true)
            }
            .onMove { source, destination in
                favorites.move(from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $favoritesEditMode)
        .environment(\.defaultMinListRowHeight, 48)
    }

    @ViewBuilder
    private func groupSection(group: BoardGroup) -> some View {
        if let name = group.name {
            let collapsed = isCollapsed(group: group)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setCollapsed(!collapsed, group: group)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(group.boards.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(name), \(group.boards.count)개, \(collapsed ? "접힘" : "펼침")")

            if !collapsed {
                ForEach(group.boards) { board in
                    boardRow(board: board)
                    Divider()
                }
            } else {
                Divider()
            }
        } else {
            ForEach(group.boards) { board in
                boardRow(board: board)
                Divider()
            }
        }
    }

    private var currentGroups: [BoardGroup] {
        switch selectedSection {
        case .favorites:
            let favs = favorites.favoriteBoards()
            return [BoardGroup(id: "favorites", name: nil, boards: favs)]
        case .site(let s):
            return catalog.groups(for: s)
        }
    }

    private func collapseKey(_ group: BoardGroup) -> String {
        "\(selectedSection.id)|\(group.id)"
    }

    private func isCollapsed(group: BoardGroup) -> Bool {
        collapsedGroups.contains(collapseKey(group))
    }

    private func setCollapsed(_ collapsed: Bool, group: BoardGroup) {
        let key = collapseKey(group)
        if collapsed { collapsedGroups.insert(key) } else { collapsedGroups.remove(key) }
        if let data = try? JSONEncoder().encode(collapsedGroups.sorted()),
           let raw = String(data: data, encoding: .utf8) {
            collapsedGroupsRaw = raw
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

    private func boardRow(board: Board) -> some View {
        let isCurrent = currentBoardID == board.id
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(board.name)
                    .font(boardNameFont(isCurrent: isCurrent))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                Spacer()
                if showSiteBadge {
                    siteBadge(site: board.site)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onSelectBoard(board) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isCurrent ? "현재 보드" : "")

            if showFavoriteButton {
                Button {
                    favorites.toggle(board)
                } label: {
                    Image(systemName: favorites.isFavorite(board) ? "star.fill" : "star")
                        .foregroundStyle(favorites.isFavorite(board) ? Color.yellow : Color.secondary.opacity(0.6))
                        .font(.footnote)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(favorites.isFavorite(board) ? "즐겨찾기 해제" : "즐겨찾기 추가")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(rowContentBackground(for: board))
    }

    private func rowBackground(for board: Board) -> Color {
        currentBoardID == board.id ? Color.accentColor.opacity(0.10) : Color.clear
    }

    private func rowContentBackground(for board: Board) -> Color {
        if case .favorites = selectedSection {
            return .clear
        }
        return rowBackground(for: board)
    }

    private var showFavoriteButton: Bool {
        if case .favorites = selectedSection { return false }
        return true
    }

    private func boardNameFont(isCurrent: Bool) -> Font {
        if case .favorites = selectedSection {
            return .subheadline.weight(isCurrent ? .semibold : .regular)
        }
        return .footnote.weight(isCurrent ? .semibold : .regular)
    }

    private var showSiteBadge: Bool {
        if case .favorites = selectedSection { return true }
        return false
    }

    private func siteBadge(site: Site) -> some View {
        let info = siteBadgeInfo(site: site)
        return Text(siteBadgeLabel(site: site))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(info.color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(info.textColor)
    }

    private func siteBadgeInfo(site: Site) -> AagagSourceTag.Info {
        switch site {
        case .clien:
            AagagSourceTag.info(for: "clien")
        case .coolenjoy:
            AagagSourceTag.info(for: "coolenjoy")
        case .inven:
            AagagSourceTag.info(for: "inven")
        case .ppomppu:
            AagagSourceTag.info(for: "ppomppu")
        case .aagag, .humor:
            AagagSourceTag.Info(label: site.displayName, color: site.accentColor, textColor: .white)
        }
    }

    private func siteBadgeLabel(site: Site) -> String {
        DrawerSection.site(site).shortLabel
    }
}
