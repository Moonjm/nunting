package poll

import "strings"

// MatchTitle 제목에 키워드가 case-insensitive substring 으로 들어있는지.
// DB 의 MatchedUsersForTitle 가 이미 SQL 단에서 비슷한 비교를 하지만,
// 이 함수는 단일 keyword/title 시나리오(예: 디버깅, 테스트)용 헬퍼.
//
// 한글-영문 cross-script 매칭은 안 함(예: "갤럭시" 키워드는 "GALAXY" 제목
// 못 잡음). 사용자가 둘 다 등록하라는 게 의도.
func MatchTitle(title, keyword string) bool {
	return strings.Contains(strings.ToLower(title), strings.ToLower(keyword))
}
