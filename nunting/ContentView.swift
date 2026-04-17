import SwiftUI

struct ContentView: View {
    @State private var selectedTab: TopTab = .site(.clien)
    @State private var selectedBoardPerSite: [Site: Board] = [:]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SiteTabBar(tabs: TopTab.all, selection: $selectedTab)
                Divider()
                tabContent
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Post.self) { post in
                PostDetailView(post: post)
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .site(let site):
            siteContent(site: site)
        case .favorites:
            FavoritesView()
        }
    }

    @ViewBuilder
    private func siteContent(site: Site) -> some View {
        let boards = Board.boards(for: site)
        if boards.isEmpty {
            ContentUnavailableView("게시판 없음", systemImage: "tray", description: Text("등록된 게시판이 없어요"))
        } else {
            let selected = selectedBoardPerSite[site] ?? boards[0]
            BoardSegmentedPicker(
                boards: boards,
                selection: Binding(
                    get: { selected },
                    set: { selectedBoardPerSite[site] = $0 }
                )
            )
            .padding(.vertical, 8)
            Divider()
            BoardListView(board: selected)
        }
    }

    private var navigationTitle: String {
        switch selectedTab {
        case .site(let site):
            return selectedBoardPerSite[site]?.name
                ?? Board.boards(for: site).first?.name
                ?? site.displayName
        case .favorites:
            return "모음"
        }
    }
}

#Preview {
    ContentView()
}
