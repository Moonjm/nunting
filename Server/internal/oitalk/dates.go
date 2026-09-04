// Package oitalk 는 오이톡(아파트 방문차량) API 클라이언트와, TeslaMate MQTT
// 지오펜스 진입 시 방문차량을 자동 등록하는 watcher.
package oitalk

import (
	"fmt"
	"time"
)

// KST 오이톡 날짜 규칙의 기준 시간대(UTC+9). tzdata 의존을 피하려 고정 오프셋.
var KST = time.FixedZone("KST", 9*60*60)

// MaxCoverageDays 오이톡 방문차량 1건이 커버할 수 있는 최대 일수.
const MaxCoverageDays = 3

// DayOf t 를 KST 자정으로 내린다(날짜 비교·캐시 키용).
func DayOf(t time.Time) time.Time {
	k := t.In(KST)
	return time.Date(k.Year(), k.Month(), k.Day(), 0, 0, 0, 0, KST)
}

// CoverageWindow 진입일 day(KST) 부터 days 일치 등록 구간.
// start = day 00:00:00.000 KST, end = (day+days-1) 23:59:59.999 KST.
func CoverageWindow(day time.Time, days int) (start, end time.Time, err error) {
	if days < 1 || days > MaxCoverageDays {
		return start, end, fmt.Errorf("coverage days %d out of range 1..%d", days, MaxCoverageDays)
	}
	start = DayOf(day)
	end = start.AddDate(0, 0, days).Add(-time.Millisecond)
	return start, end, nil
}

// FormatISO 오이톡이 쓰는 UTC ISO(밀리초, Z) 표기.
func FormatISO(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z")
}

// ParseYMD 목록 응답의 start_date/end_date("YYYYMMDD") → KST 자정.
func ParseYMD(s string) (time.Time, error) {
	return time.ParseInLocation("20060102", s, KST)
}
