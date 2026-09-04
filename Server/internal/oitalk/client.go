package oitalk

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// tokenTTL 발급 후 이 시간이 지나면 갱신한다. 관찰된 수명은 ≈24h — 절반이면
// 넉넉하고, 혹시 더 짧아도 401 → refresh 재시도 안전망이 받는다.
const tokenTTL = 12 * time.Hour

// Reservation 오이톡 방문차량 1건. 등록 응답 row / 목록 rows 공용.
type Reservation struct {
	ID        json.RawMessage `json:"_id"` // 숫자·문자열 미상 — 로그에만 쓰므로 raw
	CarNum    string          `json:"car_num"`
	StartDate string          `json:"start_date"` // YYYYMMDD (KST)
	EndDate   string          `json:"end_date"`   // YYYYMMDD (KST)
	State     string          `json:"state"`
}

// IDString 로그용 — 문자열 _id 면 따옴표를 벗긴다.
func (r Reservation) IDString() string { return strings.Trim(string(r.ID), `"`) }

// Client 오이톡 HTTP 클라이언트. access token 을 캐시하고 만료 임박 시
// client_secret 으로 재발급(전화인증 없음). 트리거 방식과 무관하게 재사용 가능.
type Client struct {
	http *http.Client
	cfg  Config

	mu          sync.Mutex
	accessToken string
	tokenExp    time.Time
}

// NewClient cfg 로 클라이언트 생성. 실제 네트워크는 첫 호출 때 나간다.
func NewClient(cfg Config) *Client {
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultBaseURL
	}
	return &Client{http: &http.Client{Timeout: 15 * time.Second}, cfg: cfg}
}

// Enabled 필수 자격증명이 모두 있는지.
func (c *Client) Enabled() bool { return c.cfg.Enabled() }

// Config 주입된 설정(읽기용).
func (c *Client) Config() Config { return c.cfg }

// EnsureToken 유효한 access token 을 돌려준다. 발급 후 tokenTTL 지났으면 refresh.
func (c *Client) EnsureToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.accessToken != "" && time.Now().Before(c.tokenExp) {
		return c.accessToken, nil
	}
	if err := c.refreshLocked(ctx); err != nil {
		return "", err
	}
	return c.accessToken, nil
}

// Refresh 무조건 POST /auth/refresh 로 access token 재발급.
func (c *Client) Refresh(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.refreshLocked(ctx)
}

func (c *Client) refreshLocked(ctx context.Context) error {
	body := map[string]any{
		"account_id":    c.cfg.AccountID,
		"client_secret": c.cfg.ClientSecret,
		"device": map[string]any{
			"id":       c.cfg.DeviceID,
			"mobi_key": c.cfg.MobiKey,
			"app_ver":  "2.3.23",
			"app_name": "net.gntalk.oitalk",
			"os_type":  "ios",
			"os_ver":   "26.6.1",
			"model":    "iPhone18,1",
			"lan":      "ko",
			"nation":   "KR",
		},
	}
	var resp struct {
		Data struct {
			Token string `json:"token"`
		} `json:"data"`
	}
	if _, err := c.do(ctx, http.MethodPost, "/auth/refresh", "", body, &resp); err != nil {
		return fmt.Errorf("oitalk refresh: %w", err)
	}
	if resp.Data.Token == "" {
		return errors.New("oitalk refresh: empty token")
	}
	c.accessToken = resp.Data.Token
	c.tokenExp = time.Now().Add(tokenTTL)
	slog.Info("oitalk_token_refreshed", "renew_after", c.tokenExp.In(KST).Format(time.RFC3339))
	return nil
}

// Register [start,end] 구간 방문차량 등록. 401 이면 refresh 후 1회 재시도.
func (c *Client) Register(ctx context.Context, start, end time.Time) (Reservation, error) {
	body := map[string]any{
		"start_dt":        FormatISO(start),
		"end_dt":          FormatISO(end),
		"car_num":         c.cfg.CarNum,
		"recv_phone_e164": c.cfg.RecvPhone,
		"visit_reason":    c.cfg.VisitReason,
	}
	var resp struct {
		Data struct {
			Row Reservation `json:"row"`
		} `json:"data"`
	}
	path := "/groups/" + url.PathEscape(c.cfg.GroupID) + "/visit_cars"
	if err := c.doAuthed(ctx, http.MethodPost, path, body, &resp); err != nil {
		return Reservation{}, fmt.Errorf("oitalk register: %w", err)
	}
	return resp.Data.Row, nil
}

const (
	listPageSize = 20
	// listMaxPages 페이지네이션 상한(안전장치). 3일 구간에 400건이면 이미 비정상.
	listMaxPages = 20
)

// List [start,end] 와 겹치는 방문차량 목록. 20건씩 offset 을 늘려 가며 페이지가
// 짧게 올 때까지 모두 모은다 — 첫 페이지만 보면 우리 차 예약이 빠져 중복 등록될 수 있다.
func (c *Client) List(ctx context.Context, start, end time.Time) ([]Reservation, error) {
	var all []Reservation
	for page := 0; page < listMaxPages; page++ {
		q := url.Values{}
		q.Set("ver", "1")
		q.Set("offset", strconv.Itoa(page*listPageSize))
		q.Set("limit", strconv.Itoa(listPageSize))
		q.Set("start_dt", FormatISO(start))
		q.Set("end_dt", FormatISO(end))
		var resp struct {
			Data struct {
				Rows []Reservation `json:"rows"`
			} `json:"data"`
		}
		path := "/groups/" + url.PathEscape(c.cfg.GroupID) + "/visit_cars?" + q.Encode()
		if err := c.doAuthed(ctx, http.MethodGet, path, nil, &resp); err != nil {
			return nil, fmt.Errorf("oitalk list: %w", err)
		}
		all = append(all, resp.Data.Rows...)
		if len(resp.Data.Rows) < listPageSize {
			return all, nil
		}
	}
	return all, fmt.Errorf("oitalk list: exceeded %d pages", listMaxPages)
}

// doAuthed 토큰 붙여 호출. 401 이면 강제 refresh 후 한 번 더.
func (c *Client) doAuthed(ctx context.Context, method, path string, body, out any) error {
	tok, err := c.EnsureToken(ctx)
	if err != nil {
		return err
	}
	status, err := c.do(ctx, method, path, tok, body, out)
	if status != http.StatusUnauthorized {
		return err
	}
	slog.Warn("oitalk_http_401", "method", method, "path", stripQuery(path),
		"action", "refresh_and_retry_once", "hint", "반복되면 client_secret 무효화 — 재캡처 필요")
	if err := c.Refresh(ctx); err != nil {
		return err
	}
	c.mu.Lock()
	tok = c.accessToken
	c.mu.Unlock()
	_, err = c.do(ctx, method, path, tok, body, out)
	return err
}

// do JSON 요청 1회. 응답 status 를 함께 돌려줘 401 분기가 가능하게 한다.
func (c *Client) do(ctx context.Context, method, path, token string, body, out any) (int, error) {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return 0, err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.cfg.BaseURL+path, rd)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("x-access-token", token)
	}
	t0 := time.Now()
	res, err := c.http.Do(req)
	if err != nil {
		slog.Warn("oitalk_http", "method", method, "path", stripQuery(path), "err", err, "elapsed_ms", ms(t0))
		return 0, err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return res.StatusCode, err
	}
	slog.Info("oitalk_http", "method", method, "path", stripQuery(path), "status", res.StatusCode,
		"bytes", len(raw), "elapsed_ms", ms(t0))
	if res.StatusCode != http.StatusOK {
		return res.StatusCode, fmt.Errorf("%s %s: status %d body=%s", method, path, res.StatusCode, truncate(raw, 300))
	}
	if out != nil {
		if err := json.Unmarshal(raw, out); err != nil {
			return res.StatusCode, fmt.Errorf("%s %s: decode: %w", method, path, err)
		}
	}
	return res.StatusCode, nil
}

// stripQuery 로그용 경로 — 쿼리(날짜 등)는 잘라 한 줄로.
func stripQuery(path string) string {
	if i := strings.IndexByte(path, '?'); i >= 0 {
		return path[:i]
	}
	return path
}

func truncate(b []byte, n int) string {
	if len(b) <= n {
		return string(b)
	}
	return string(b[:n]) + "…"
}
