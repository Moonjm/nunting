package poll

import "testing"

func TestMatchTitle_CaseInsensitive(t *testing.T) {
	cases := []struct {
		title   string
		keyword string
		want    bool
	}{
		{"삼성 갤럭시 S25 ULTRA", "갤럭시", true},
		{"삼성 갤럭시 S25 ULTRA", "GALAXY", false}, // 한글-영문 변환 없음
		{"Apple iPhone 16 Pro", "iphone", true},
		{"Apple iPhone 16 Pro", "IPHONE", true},
		{"무관한 제목", "갤럭시", false},
		{"  공백 갤럭시  ", " 갤럭시 ", true},
		// --- AND multi-token cases ---
		{"삼다수 500ml 24개입", "500ml,삼다수", true},
		{"삼다수 500ml 24개입", "삼다수,500ml", true}, // 순서 무관
		{"삼다수 2L", "500ml,삼다수", false},          // 한 토큰만 — miss
		{"500ml 콜라", "500ml,삼다수", false},        // 다른 한 토큰만 — miss
		{"삼다수 500ML 24개입", "500ml,삼다수", true}, // case-insensitive (title 쪽 대문자)
		{"무관한 제목", "500ml,삼다수", false},
	}
	for _, c := range cases {
		got := MatchTitle(c.title, c.keyword)
		if got != c.want {
			t.Errorf("MatchTitle(%q, %q): want %v, got %v", c.title, c.keyword, c.want, got)
		}
	}
}
