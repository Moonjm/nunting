// Package poll 은 ppomppu 모바일 리스트 폴링 + 키워드 매칭.
// parser.go 는 HTML → []Post, fetcher.go 는 HTTP → bytes,
// matcher.go 는 (post, keywords) → matches, poller.go 는 ticker 루프.
package poll

import (
	"bytes"
	"fmt"
	"net/url"
	"strings"

	"github.com/PuerkitoBio/goquery"
	"golang.org/x/net/html/charset"
)

// Post 폴러가 다루는 최소 글 정보. iOS Post 와 의도적으로 다른 모델
// (서버는 매칭/푸시만 필요).
type Post struct {
	ID     string // "ppomppu-<postNo>" — sentinel 비교용
	PostNo string
	Title  string
	URL    string // 외부 노출용 deep-link
}

const boardID = "ppomppu"

// ParseList ppomppu 모바일 리스트 페이지 HTML → []Post.
// Selector 는 Swift PpomppuParser.parseList 와 동일:
//   - ul.bbsList_new > li (fallback ul.bbsList > li)
//   - hotpop_bg_color 클래스 row 는 skip (인기글 고정)
//   - href 에 id 가 다른 board 면 skip (sponsor 글)
//   - title: li.title span.cont (fallback strong) — img/sup/rp 제거
//
// EUC-KR 인코딩 페이지는 자동 감지 후 UTF-8로 변환한다.
func ParseList(html []byte) ([]Post, error) {
	// golang.org/x/net/html/charset 으로 EUC-KR → UTF-8 자동 변환.
	r, err := charset.NewReader(bytes.NewReader(html), "text/html; charset=euc-kr")
	if err != nil {
		return nil, fmt.Errorf("charset reader: %w", err)
	}

	doc, err := goquery.NewDocumentFromReader(r)
	if err != nil {
		return nil, fmt.Errorf("goquery: %w", err)
	}

	rows := doc.Find("ul.bbsList_new > li")
	if rows.Length() == 0 {
		rows = doc.Find("ul.bbsList > li")
	}

	var posts []Post
	rows.Each(func(_ int, row *goquery.Selection) {
		if cls, _ := row.Attr("class"); strings.Contains(cls, "hotpop_bg_color") {
			return
		}

		link := row.Find("a[href*='bbs_view.php']").First()
		if link.Length() == 0 {
			return
		}
		href, _ := link.Attr("href")
		if href == "" {
			return
		}

		base, _ := url.Parse("https://m.ppomppu.co.kr/new/")
		ref, err := url.Parse(href)
		if err != nil {
			return
		}
		full := base.ResolveReference(ref)
		scheme := strings.ToLower(full.Scheme)
		if scheme != "http" && scheme != "https" {
			return
		}

		if got := full.Query().Get("id"); got != "" && got != boardID {
			return
		}

		titleEl := row.Find("li.title span.cont").First()
		if titleEl.Length() == 0 {
			titleEl = row.Find("strong").First()
		}
		if titleEl.Length() == 0 {
			return
		}
		titleEl.Find("img, span.rp, sup, .baseList-img").Remove()
		title := strings.TrimSpace(titleEl.Text())
		title = strings.Join(strings.Fields(title), " ")
		if title == "" {
			return
		}

		postNo := full.Query().Get("no")
		if postNo == "" {
			return
		}

		q := full.Query()
		q.Del("page")
		full.RawQuery = q.Encode()

		posts = append(posts, Post{
			ID:     boardID + "-" + postNo,
			PostNo: postNo,
			Title:  title,
			URL:    full.String(),
		})
	})

	return posts, nil
}
