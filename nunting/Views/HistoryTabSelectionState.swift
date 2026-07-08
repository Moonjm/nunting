import Foundation

// 하단 탭(모음 0 / 둘러보기 1 / 알림 2) 선택 상태. (이름의 "History" 는 예전
// role:.search 히스토리 탭 시절의 잔재 — 지금 "이전 글"은 탭이 아니라 우측
// 모서리 유리 핸들(HistoryResumeHandle)이라 탭 선택에는 관여하지 않는다.)
struct HistoryTabSelectionState: Equatable {
    var selectedTab: Int

    init(selectedTab: Int = 0) {
        self.selectedTab = selectedTab
    }

    mutating func selectTab(_ newTab: Int) {
        selectedTab = newTab
    }
}
