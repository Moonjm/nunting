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
	}
	for _, c := range cases {
		got := MatchTitle(c.title, c.keyword)
		if got != c.want {
			t.Errorf("MatchTitle(%q, %q): want %v, got %v", c.title, c.keyword, c.want, got)
		}
	}
}
