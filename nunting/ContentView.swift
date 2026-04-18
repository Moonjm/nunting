import SwiftUI

struct ContentView: View {
    @State private var favorites = FavoritesStore()
    @State private var selectedBoard: Board = .clienNews
    @State private var drawerOpen = false
    @State private var drawerSection: DrawerSection = .favorites

    @State private var dragOffset: CGFloat = 0
    @State private var dragDirection: DragDirection?

    private let drawerWidth: CGFloat = 300

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                mainScreen
                    .toolbar(.hidden, for: .navigationBar)

                Color.black
                    .opacity(0.3 * drawerProgress)
                    .ignoresSafeArea()
                    .allowsHitTesting(drawerProgress > 0.01)
                    .onTapGesture { closeDrawer() }

                SideDrawer(
                    favorites: favorites,
                    selectedSection: $drawerSection,
                    onSelectBoard: { board in
                        selectedBoard = board
                        closeDrawer()
                    },
                    onClose: closeDrawer
                )
                .frame(width: drawerWidth)
                .offset(x: drawerXOffset)
            }
            .ignoresSafeArea(.keyboard)
            .simultaneousGesture(panGesture)
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

    private var drawerProgress: CGFloat {
        let base: CGFloat = drawerOpen ? drawerWidth : 0
        let target = base + dragOffset
        return max(0, min(1, target / drawerWidth))
    }

    private var drawerXOffset: CGFloat {
        -drawerWidth + drawerWidth * drawerProgress
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragDirection == nil {
                    let absW = abs(value.translation.width)
                    let absH = abs(value.translation.height)
                    if absW > 8 && absW > absH * 1.3 {
                        dragDirection = .horizontal
                    } else if absH > 8 && absH > absW * 1.3 {
                        dragDirection = .vertical
                    }
                }
                if dragDirection == .horizontal {
                    dragOffset = value.translation.width
                }
            }
            .onEnded { value in
                let lockedHorizontal = dragDirection == .horizontal
                dragDirection = nil

                guard lockedHorizontal else {
                    dragOffset = 0
                    return
                }

                let velocity = value.predictedEndTranslation.width - value.translation.width
                let shouldOpen: Bool
                if drawerOpen {
                    shouldOpen = !(value.translation.width < -drawerWidth / 3 || velocity < -150)
                } else {
                    shouldOpen = (value.translation.width > drawerWidth / 3 || velocity > 150)
                }

                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    drawerOpen = shouldOpen
                    dragOffset = 0
                }
            }
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

private enum DragDirection {
    case horizontal
    case vertical
}

#Preview {
    ContentView()
}
