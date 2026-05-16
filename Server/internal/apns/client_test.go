package apns

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/Moonjm/nunting/server/internal/poll"
)

func TestStubMode_LogsButDoesNotPanic(t *testing.T) {
	c, err := New(Config{})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	post := poll.Post{ID: "ppomppu-1", Title: "테스트", PostNo: "1", URL: "https://example.com/1"}
	if err := c.Send(context.Background(), "tok", "테스트", post); err != nil {
		t.Errorf("stub Send must not error: %v", err)
	}
}

func TestBuildPayload(t *testing.T) {
	post := poll.Post{ID: "ppomppu-1", Title: "갤럭시 신상", PostNo: "1", URL: "https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=1"}
	raw := BuildPayload("갤럭시", post)

	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("payload not JSON: %v body=%s", err, string(raw))
	}
	aps, ok := got["aps"].(map[string]any)
	if !ok {
		t.Fatal("aps missing")
	}
	alert, ok := aps["alert"].(map[string]any)
	if !ok {
		t.Fatal("aps.alert missing")
	}
	if alert["title"] != "갤럭시" {
		t.Errorf("title: %v", alert["title"])
	}
	if alert["body"] != "갤럭시 신상" {
		t.Errorf("body: %v", alert["body"])
	}
	if got["url"] != post.URL {
		t.Errorf("url: %v", got["url"])
	}
}
