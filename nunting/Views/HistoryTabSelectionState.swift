import Foundation

struct HistoryTabSelectionState: Equatable {
    var selectedTab: Int
    var tabBeforeHistory: Int
    var showingHistory: Bool

    init(selectedTab: Int = 0, tabBeforeHistory: Int = 0, showingHistory: Bool = false) {
        self.selectedTab = selectedTab
        self.tabBeforeHistory = tabBeforeHistory
        self.showingHistory = showingHistory
    }

    var effectiveSelectedTab: Int {
        selectedTab == 4 ? tabBeforeHistory : selectedTab
    }

    mutating func selectTab(_ newTab: Int) {
        let oldTab = selectedTab
        selectedTab = newTab
        if newTab == 4 {
            tabBeforeHistory = oldTab == 4 ? tabBeforeHistory : oldTab
            showingHistory = true
        }
    }

    mutating func setHistoryShowing(_ showing: Bool) {
        showingHistory = showing
        if !showing, selectedTab == 4 {
            selectedTab = tabBeforeHistory
        }
    }
}
