import SwiftUI

struct ContentView: View {
    @State private var favorites = FavoritesStore()
    @State private var selectedBoard: Board = .clienNews
    @State private var drawerOpen = false
    @State private var drawerSection: DrawerSection = .favorites
    @State private var dragOffset: CGFloat = 0

    private let drawerWidth: CGFloat = 300
    private let edgeTriggerWidth: CGFloat = 22

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                mainScreen
                    .toolbar(.hidden, for: .navigationBar)

                if drawerOpen || dragOffset > 0 {
                    Color.black
                        .opacity(0.3 * (currentDrawerOffset / drawerWidth))
                        .ignoresSafeArea()
                        .onTapGesture { closeDrawer() }
                        .allowsHitTesting(drawerOpen)
                }

                SideDrawer(
                    favorites: favorites,
                    selectedSection: $drawerSection,
                    onSelectBoard: { board in
                        selectedBoard = board
                        closeDrawer()
                    },
                    onClose: { closeDrawer() }
                )
                .frame(width: drawerWidth)
                .offset(x: -drawerWidth + currentDrawerOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if drawerOpen {
                                dragOffset = max(-drawerWidth, min(0, value.translation.width))
                            }
                        }
                        .onEnded { value in
                            if drawerOpen && value.translation.width < -80 {
                                closeDrawer()
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )

                edgeSwipeCatcher
            }
            .ignoresSafeArea(.keyboard)
            .navigationDestination(for: Post.self) { post in
                PostDetailView(post: post)
            }
        }
    }

    private var mainScreen: some View {
        VStack(spacing: 0) {
            BoardListView(board: selectedBoard)
            MainBottomBar(
                board: selectedBoard,
                favorites: favorites,
                onSiteTap: { openDrawer(targetSection: .site(selectedBoard.site)) },
                onSearch: {},
                onMore: { openDrawer(targetSection: drawerSection) }
            )
        }
    }

    private var edgeSwipeCatcher: some View {
        Color.clear
            .frame(width: edgeTriggerWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        if !drawerOpen
                            && value.startLocation.x < edgeTriggerWidth
                            && value.translation.width > 50
                        {
                            openDrawer(targetSection: drawerSection)
                        }
                    }
            )
            .allowsHitTesting(!drawerOpen)
    }

    private var currentDrawerOffset: CGFloat {
        let base: CGFloat = drawerOpen ? drawerWidth : 0
        return max(0, min(drawerWidth, base + dragOffset))
    }

    private func openDrawer(targetSection: DrawerSection) {
        drawerSection = targetSection
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            drawerOpen = true
            dragOffset = 0
        }
    }

    private func closeDrawer() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            drawerOpen = false
            dragOffset = 0
        }
    }
}

#Preview {
    ContentView()
}
