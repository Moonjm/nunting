package poll

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

const (
	listURL         = "https://m.ppomppu.co.kr/new/bbs_list.php"
	defaultUA       = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
	fetchTimeout    = 15 * time.Second
	defaultLanguage = "ko-KR,ko;q=0.9,en;q=0.5"
)

// FetchListPage page 번호 페이지의 raw HTML bytes 를 가져온다.
// EUC-KR/UTF-8 transcoding 은 하지 않음 — parser 가 charset.NewReader 로
// 메타 태그 보고 자동 디코드. 여기서 transcoded 바이트 + 메타태그=euc-kr
// 조합을 만들면 parser 가 다시 디코드해 mojibake 생성.
func FetchListPage(ctx context.Context, client *http.Client, page int) ([]byte, error) {
	u, _ := url.Parse(listURL)
	q := u.Query()
	q.Set("id", "ppomppu")
	q.Set("page", strconv.Itoa(page))
	u.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, "GET", u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", defaultUA)
	req.Header.Set("Accept-Language", defaultLanguage)

	if client == nil {
		client = &http.Client{Timeout: fetchTimeout}
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("ppomppu status %d", resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}
