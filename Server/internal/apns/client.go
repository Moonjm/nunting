// Package apns 는 sideshow/apns2 의 얇은 wrapper. JWT 캐시/refresh,
// HTTP/2 POST, 410 self-heal 만 외부 인터페이스로 노출.
package apns

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"

	apns2 "github.com/sideshow/apns2"
	"github.com/sideshow/apns2/token"

	"github.com/Moonjm/nunting/server/internal/poll"
)

// Config env 4개. Topic 까지 모두 있어야 real 모드.
type Config struct {
	KeyPath string // 컨테이너 내부 .p8 경로
	KeyID   string
	TeamID  string
	Topic   string
	Host    string // ""면 sandbox
}

// TokenClearer 410 self-heal 시 호출되는 콜백. main.go 가 db.Store 에 묶어 주입.
type TokenClearer interface {
	ClearPushTokenByValue(ctx context.Context, token string) error
}

// Client real 모드 또는 stub 모드 둘 중 하나. Send 가 동작 결정.
type Client struct {
	real    *apns2.Client
	topic   string
	clearer TokenClearer
}

// New 4개 env 모두 있으면 real, 아니면 stub. Real 모드는 KeyPath 파일이
// 실제 존재해야 하며 .p8 파싱 가능해야 함 — 실패 시 error 반환.
func New(c Config) (*Client, error) {
	if c.KeyPath == "" || c.KeyID == "" || c.TeamID == "" || c.Topic == "" {
		slog.Warn("apns_stub_mode", "reason", "APNS_* env 누락")
		return &Client{}, nil
	}

	authKey, err := token.AuthKeyFromFile(c.KeyPath)
	if err != nil {
		return nil, fmt.Errorf("read .p8: %w", err)
	}
	tk := &token.Token{
		AuthKey: authKey,
		KeyID:   c.KeyID,
		TeamID:  c.TeamID,
	}

	cli := apns2.NewTokenClient(tk)
	if c.Host == "api.push.apple.com" {
		cli = cli.Production()
	} else {
		cli = cli.Development() // sandbox
	}

	return &Client{real: cli, topic: c.Topic}, nil
}

// SetTokenClearer 의존 사이클을 피하기 위해 main.go 가 db.Store wrapper 를 주입.
func (c *Client) SetTokenClearer(tc TokenClearer) {
	c.clearer = tc
}

// BuildPayload iOS 클라이언트와 합의된 APNs JSON 페이로드.
// Swift NotificationDelegate 가 userInfo["url"] 로 deep-link, userInfo["alert_id"]
// 로 푸시-탭 읽음 처리. alertID 0 이면 이력 기록 실패 케이스 — 클라가 무시.
func BuildPayload(matchedKeyword string, alertID int64, post poll.Post) []byte {
	payload := map[string]any{
		"aps": map[string]any{
			"alert": map[string]any{
				"title": matchedKeyword,
				"body":  post.Title,
			},
			"sound": "default",
		},
		"url":      post.URL,
		"alert_id": alertID,
	}
	b, _ := json.Marshal(payload)
	return b
}

// Send 모드 분기. real 이면 HTTP/2 POST, stub 이면 stderr 로깅.
// 410 Unregistered 응답 시 token clearer 호출(있다면).
func (c *Client) Send(ctx context.Context, deviceToken, matchedKeyword string, alertID int64, post poll.Post) error {
	payload := BuildPayload(matchedKeyword, alertID, post)

	if c.real == nil {
		fmt.Fprintf(os.Stderr, "[apns-stub] token=%s keyword=%s body=%s\n", deviceToken, matchedKeyword, post.Title)
		return nil
	}

	n := &apns2.Notification{
		DeviceToken: deviceToken,
		Topic:       c.topic,
		Payload:     payload,
	}
	res, err := c.real.PushWithContext(ctx, n)
	if err != nil {
		return fmt.Errorf("apns push: %w", err)
	}
	if res.StatusCode == 410 {
		slog.Warn("apns_410_self_heal", "device_token_prefix", safePrefix(deviceToken))
		if c.clearer != nil {
			if e := c.clearer.ClearPushTokenByValue(ctx, deviceToken); e != nil {
				slog.Error("apns_410_clear_failed", "err", e)
			}
		}
		return nil
	}
	if res.StatusCode != 200 {
		return fmt.Errorf("apns status %d reason=%s", res.StatusCode, res.Reason)
	}
	return nil
}

func safePrefix(s string) string {
	if len(s) <= 8 {
		return s
	}
	return s[:8] + "..."
}
