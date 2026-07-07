# 히스토리 버튼 → 마지막 상세뷰 재노출 (keep-alive)

- 날짜: 2026-07-07
- 상태: 구현 예정
- 관련 파일: `RootTabView.swift`, `DetailOverlayController.swift`, `HistoryTabSelectionState.swift`, `ReadStore.swift`, `HistorySheet.swift`(삭제)

## 배경 / 문제

하단 탭바 오른쪽 분리 슬롯의 **히스토리 버튼**(`Tab(value: 4, role: .search)`)은 지금
`fullScreenCover`로 "최근 읽은 글 5개" 목록(`HistorySheet`)을 띄우고, 행을 탭해야
그 글을 다시 연다.

원하는 동작은 **목록을 거치지 않고, 히스토리 버튼을 누르면 마지막으로 보던 상세
화면을 그대로 다시 띄우는 것**이다. "그대로"가 핵심 — 재fetch가 아니라 보던 뷰
자체(스크롤 위치·로딩된 본문·이미지·영상 재생 상태)를 복원한다.

## 결정

**상세 오버레이의 keep-alive를 되살리고, 히스토리 버튼을 재노출 트리거로 배선한다.**
최근 읽은 글 목록 기능(`HistorySheet` + `ReadStore.recentPosts`)은 통째로 제거한다.

세션 한정 동작이다 — 앱을 끄면 `activePost`가 사라지므로, 재실행 직후 히스토리
버튼은 **비활성**이고 글을 한 번 열어야 활성화된다. 마지막 글을 영속 저장하지
않는다(사용자 요구: "마지막글은 저장할필요가없다").

히스토리 탭은 `.disabled(detail.activePost == nil)`로 재노출 대상이 없으면
비활성화한다. `activePost`는 `@Observable`이라 첫 글을 열면 자동으로 활성으로
전환되고, keep-alive라 이후 세션 내내 활성 유지된다.

## 구조 — 왜 작은 변경인가

`DetailOverlayController`는 **이미 keep-alive 컨트롤러**다. 상세 오버레이는
`RootTabView`의 ZStack에 영구 마운트되고:

- `hide()` 는 오버레이를 화면 밖 오른쪽으로 밀기만 한다(`offset = containerWidth`).
- `show(post)` 는 같은 `activePost`면 **그 뷰를 그대로 다시 슬라이드 인**한다
  (keep-alive 분기). 내부 `PostDetailView`가 스크롤·이미지·영상 상태를 계속 소유.

즉 원하는 동작은 이미 `show`/`hide`에 구현돼 있다. 문제는 **새 Glass 셸이 이걸
꺼놨다**는 것: `DetailBackDrag.dismiss()`가 닫은 뒤 380ms 후 `activePost = nil`로
오버레이를 언마운트한다. 그 이유는 코드 주석에:

> "메모리 회수 + '마지막 글 재노출'이 보드 스와이프와 겹치는 문제를 원천 차단"

두 번째 이유(보드 페이저 가로 스와이프 충돌)는 **재노출을 스와이프가 아니라
버튼으로 하면 자동 해소**된다. 버튼은 제스처가 아니므로 페이저와 겹칠 일이 없다.
남는 건 첫 번째 이유(메모리)뿐 → 아래 트레이드오프 참조.

숨겨진(오프스크린) 오버레이는 무해하다: `isOverlayVisible == false`라
`DetailBackDrag`가 보드 스와이프에 양보하고, `allowsHitTesting == false`라 히트
테스트도 안 받는다. 영상 재생·이미지 디코드도 `isOverlayVisible` 게이트로 멈춘다.

## 메모리 트레이드오프

이 앱은 OOM에 민감하고(앱 "그냥 꺼짐" = OOM), 새 셸이 `activePost`를 nil로 비운
것도 그 완화책의 일부였다. keep-alive를 되살리면 **마지막 상세뷰 1개**(디코드된
이미지 포함)가 다음 글을 열거나 앱을 끌 때까지 메모리에 상주한다.

- 항상 **딱 1개**다 — 새 글을 열면 `.id(post.id)`가 바뀌며 이전 뷰가 해제된다.
- 숨겨진 동안 영상/디코드는 멈추지만, 이미 디코드된 이미지는 상주한다.
- 최악: 무거운 글을 열었다가 나와서 목록만 한참 보는 경우 그 1개가 계속 물린다.

사용자가 이 상주를 명시적으로 수용했다("그냥 메모리상주해도 괜찮아"). 이번 변경은
OOM 완화 티어다운의 **부분 되돌림**임을 기록으로 남긴다.

## 변경 파일

- **`DetailBackDrag.dismiss()`** (`RootTabView.swift`): `activePost = nil` 티어다운
  Task 제거, `detail.hide()`만 남긴다. 클래스 주석의 "언마운트" 설명도 갱신.
- **히스토리 탭 배선** (`RootTabView.swift`): `fullScreenCover`+`HistorySheet` 제거.
  TabView selection setter에서 `newValue == 4`면 `activePost`가 있을 때
  `detail.show(activePost)`로 재노출하고 **`selectedTab`은 바꾸지 않는다**(아래
  "깜빡임" 참조). 탭에 `.disabled(activePost == nil)`로 재노출 대상 없을 때 비활성.
- **`HistoryTabSelectionState`**: `showingHistory`/`setHistoryShowing`/`tabBeforeHistory`/
  `effectiveSelectedTab` 전부 제거. `selectTab(4)`는 무시(선택 안 바꿈)하고 그 외
  값만 전환하는 최소 상태기계로 축소.
- **`ReadStore`**: `recentPosts`/`recentKey`/`recentCapacity`/`recordRecent`/
  `persistRecent` 제거. `markRead(_ post:)`는 `markRead(id:)`만 위임.
  읽음 표시용 read-ID 마커(`ids`/`order`)는 히스토리와 무관하므로 그대로 둔다.
  (영속됐던 `recentReadPosts.v1` 키는 고아 데이터로 남지만 무해 — 1인 도구라 마이그레이션 불필요.)
- **`HistorySheet.swift`**: 파일 삭제.
- **`HistoryTabSelectionStateTests.swift`**: `showingHistory`/`setHistoryShowing`
  검증을 새 상태기계에 맞게 갱신.

## 깜빡임 (탭 전환 vs 순수 버튼)

히스토리 버튼을 "탭 선택(4)했다가 직전 탭으로 복원"하는 방식으로 만들면, 상세가
슬라이드-인 하는 동안 언더레이가 tab4 의 빈 `Color.clear` 로 한 프레임 번쩍였다가
복귀해 **깜빡인다**. 탭 전환을 느리게 하는 걸로는 못 고친다 — 왕복 자체가 원인.

해결: 히스토리는 탭 전환이 아니라 **순수 버튼**이므로 `selectedTab` 을 아예 바꾸지
않는다(거부 바인딩). 언더레이가 직전 탭 화면 그대로 유지되고 그 위로 오버레이만
미끄러져 깜빡임이 없다. `selectedTab` 이 4 가 되는 경로가 사라지므로
`effectiveSelectedTab` 마스킹·복원 로직도 불필요해진다.

주의: role:.search 탭에 거부 바인딩을 걸 때 시스템이 탭 알약을 잠깐 강조할 수 있다.
오버레이(zIndex 10, 전체화면)가 탭바를 덮으므로 상세 표시 중엔 안 보이고, 닫으면
`selectedTab`(직전 탭)이 그대로라 정상 복귀한다 — 기기에서 한 번 확인 권장.

## 검토한 대안

- **재fetch(캐시) 방식**: 히스토리 버튼이 마지막 `Post`로 상세를 새로 렌더
  (본문은 `PostDetailCache`에서 → 네트워크 플래시 없음). 메모리 상 안전하지만
  스크롤 위치·재생 상태가 초기화돼 "그 뷰 그대로" 요구를 못 채운다. 기각.
- **재노출을 forward-reveal 스와이프로**: 보드 페이저 가로 스와이프와 충돌
  (애초에 keep-alive를 뗀 두 번째 이유). 버튼 방식이 이 충돌을 회피하므로 기각.
