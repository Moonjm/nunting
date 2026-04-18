import SwiftUI

struct ContentView: View {
    @State private var favorites = FavoritesStore()
    @State private var selectedBoard: Board = .clienNews
    @State private var selectedFilter: BoardFilter? = nil
    @State private var searchQuery: String? = nil
    @State private var drawerOpen = false
    @State private var drawerSection: DrawerSection = .favorites
    @State private var navigationPath = NavigationPath()
    @State private var searchSheetPresented = false

    @State private var dragOffset: CGFloat = 0
    @State private var dragDirection: DragDirection?
    @State private var dragLockBaseline: CGFloat = 0
    @State private var scrollLocked = false

    private let drawerWidth: CGFloat = 300

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack(alignment: .leading) {
                mainScreen
                    .toolbar(.hidden, for: .navigationBar)

                Color.black
                    .opacity(0.3 * drawerProgress)
                    .ignoresSafeArea()
                    .allowsHitTesting(drawerOpen)
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
            if let q = searchQuery, !q.isEmpty {
                SearchActiveBar(query: q) { searchQuery = nil }
            }
            BoardListView(
                board: selectedBoard,
                filter: selectedFilter,
                searchQuery: searchQuery,
                scrollLocked: scrollLocked,
                onSelectPost: { navigationPath.append($0) }
            )
            if !selectedBoard.filters.isEmpty {
                BoardFilterBar(filters: selectedBoard.filters, selection: $selectedFilter)
            }
            MainBottomBar(
                board: selectedBoard,
                favorites: favorites,
                onSiteTap: { openDrawer(targetSection: .site(selectedBoard.site)) },
                onSearch: { searchSheetPresented = true },
                onMore: { openDrawer(targetSection: drawerSection) }
            )
        }
        .onChange(of: selectedBoard) { _, _ in
            selectedFilter = nil
            searchQuery = nil
        }
        .sheet(isPresented: $searchSheetPresented) {
            SearchSheet(
                board: selectedBoard,
                initialQuery: searchQuery ?? "",
                onSubmit: { q in searchQuery = q },
                onClear: { searchQuery = nil }
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
                    if absW > 10 && absW >= absH {
                        dragDirection = .horizontal
                        dragLockBaseline = value.translation.width
                        scrollLocked = true
                    } else if absH > 10 && absH > absW {
                        dragDirection = .vertical
                    }
                }
                if dragDirection == .horizontal {
                    dragOffset = value.translation.width - dragLockBaseline
                }
            }
            .onEnded { value in
                let lockedHorizontal = dragDirection == .horizontal
                let baseline = dragLockBaseline
                dragDirection = nil
                dragLockBaseline = 0
                scrollLocked = false

                guard lockedHorizontal else {
                    dragOffset = 0
                    return
                }

                let velocity = value.predictedEndTranslation.width - value.translation.width
                let traveled = value.translation.width - baseline

                let shouldOpen: Bool
                if drawerOpen {
                    shouldOpen = !(traveled < -drawerWidth / 3 || velocity < -150)
                } else {
                    shouldOpen = (traveled > drawerWidth / 3 || velocity > 150)
                }

                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    drawerOpen = shouldOpen
                    dragOffset = 0
                }
            }
    }

    private func openDrawer(targetSection: DrawerSection) {
        drawerSection = targetSection
        dragDirection = nil
        dragLockBaseline = 0
        scrollLocked = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            drawerOpen = true
            dragOffset = 0
        }
    }

    private func closeDrawer() {
        dragDirection = nil
        dragLockBaseline = 0
        scrollLocked = false
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

private struct SearchActiveBar: View {
    let query: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text("\"\(query)\" 검색 결과")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("검색 해제")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }
}

#Preview {
    ContentView()
}
