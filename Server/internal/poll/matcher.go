package poll

import "strings"

// MatchTitle 제목에 keyword 의 모든 토큰(콤마로 split)이 case-insensitive
// substring 으로 포함되어 있는지. 토큰 0개(empty/콤마만)는 false.
//
// 한글-영문 cross-script 매칭은 안 함(예: "갤럭시" 키워드는 "GALAXY" 제목
// 못 잡음). 사용자가 둘 다 등록하라는 게 의도.
func MatchTitle(title, keyword string) bool {
	lowerTitle := strings.ToLower(title)
	tokens := strings.Split(keyword, ",")
	hadAny := false
	for _, t := range tokens {
		t = strings.ToLower(strings.TrimSpace(t))
		if t == "" {
			continue
		}
		hadAny = true
		if !strings.Contains(lowerTitle, t) {
			return false
		}
	}
	return hadAny
}
