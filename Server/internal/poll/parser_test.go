package poll

import (
	"os"
	"strings"
	"testing"
)

func loadFixture(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/ppomppu_page1.html")
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	return b
}

func TestParseList_ExtractsPosts(t *testing.T) {
	posts, err := ParseList(loadFixture(t))
	if err != nil {
		t.Fatalf("ParseList: %v", err)
	}
	if len(posts) < 5 {
		t.Fatalf("want >=5 posts, got %d", len(posts))
	}
	for i, p := range posts {
		if p.ID == "" || p.Title == "" || p.PostNo == "" || p.URL == "" {
			t.Errorf("post[%d] incomplete: %+v", i, p)
		}
		if !strings.HasPrefix(p.ID, "ppomppu-") {
			t.Errorf("post[%d] id missing board prefix: %q", i, p.ID)
		}
	}
}
