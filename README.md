# 눈팅 (Nunting)

여러 한국 커뮤니티 사이트를 한 앱에서 눈팅(읽기 전용)하는 iOS 앱.

## 컨셉
- 로그인/댓글 없이 **조회만** 잘 되면 됨
- 각 사이트 게시판을 **즐겨찾기**로 모아서 통합 피드로 보기
- 네이티브 리스트 + 본문 파싱 (WebView 지양, UX 우선)

## 대상 사이트 (초기)
- 쿨엔조이 https://coolenjoy.net/
- 인벤 메이플 게시판 https://www.inven.co.kr/board/maple/5974
- 뽐뿌 https://www.ppomppu.co.kr/
- 클리앙 https://www.clien.net/service/board/news

## 주요 기능
- **즐겨찾기 탭** — 선택한 게시판들 최신글을 날짜순 통합 피드
- **탐색 탭** — 사이트 → 게시판 드릴다운, 별표로 즐겨찾기 토글
- **설정 탭** — 정렬/필터/캐시

## 기술 스택
- SwiftUI (iOS)
- SwiftSoup — HTML 파싱
- SwiftData — 즐겨찾기/캐시 영속화
- 비동기 fetch: `async/await` + `withTaskGroup`

## 데이터 모델
```
Site  { id, name, baseURL, parserType }
Board { id, siteID, name, path, isFavorite }
Post  { boardID, title, author, date, commentCount, url }
PostDetail { post, contentHTML, images }
```

## 구조
- **사이트별 Parser 프로토콜**
  ```swift
  protocol BoardParser {
      func parseList(html: String) throws -> [Post]
      func parseDetail(html: String) throws -> PostDetail
  }
  ```
  사이트마다 구현체 분리 → 셀렉터 바뀔 때 해당 파일만 수정

- **통합 피드**
  - 즐겨찾기 Board들 병렬 fetch → 날짜순 merge
  - 셀에 사이트 배지로 출처 표시
  - Pull-to-refresh + "더 보기" 방식 (무한스크롤 X)
  - 실패한 사이트는 스킵하고 인디케이터로 알림

## 주의 사항
- **인코딩**: 뽐뿌는 EUC-KR 가능성 → `String(data:encoding:)` 처리
- **User-Agent**: 기본 URLSession UA로 403 뜨는 사이트 있음 → 커스텀 UA
- **각 사이트 약관/robots.txt** 확인
- 셀렉터 깨짐 대응 속도가 핵심 리스크

## 게시판 목록 관리
- 1차: 하드코딩 JSON (주요 게시판만)
- 2차: **원격 JSON** (GitHub raw 등) fetch → 앱 업데이트 없이 게시판 추가/수정

## 다음 단계
1. Xcode 프로젝트 생성 (SwiftUI, iOS 17+)
2. 사이트 1개 PoC 파서 — 클리앙부터 (UTF-8, 구조 깔끔)
3. List/Detail 화면 + 즐겨찾기 토글
4. 나머지 3개 사이트 파서 확장
5. 통합 피드 구현
