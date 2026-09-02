package oitalk

import (
	"testing"
	"time"
)

func TestCoverageWindow_ThreeDaysFromEntryDayKST(t *testing.T) {
	// 진입일 D=2026-09-02(KST) → start=D 00:00 KST, end=(D+2) 23:59:59.999 KST
	day := time.Date(2026, 9, 2, 0, 0, 0, 0, KST)
	start, end, err := CoverageWindow(day, 3)
	if err != nil {
		t.Fatalf("CoverageWindow: %v", err)
	}
	if got := FormatISO(start); got != "2026-09-01T15:00:00.000Z" {
		t.Errorf("start = %s", got)
	}
	if got := FormatISO(end); got != "2026-09-04T14:59:59.999Z" {
		t.Errorf("end = %s", got)
	}
}

func TestCoverageWindow_RejectsOutOfRangeDays(t *testing.T) {
	day := time.Date(2026, 9, 2, 0, 0, 0, 0, KST)
	for _, days := range []int{0, -1, 4} {
		if _, _, err := CoverageWindow(day, days); err == nil {
			t.Errorf("days=%d: expected error", days)
		}
	}
}

func TestDayOf_TruncatesToKSTMidnight(t *testing.T) {
	// UTC 2026-09-01T16:30Z = KST 2026-09-02 01:30 → 2026-09-02
	got := DayOf(time.Date(2026, 9, 1, 16, 30, 0, 0, time.UTC))
	want := time.Date(2026, 9, 2, 0, 0, 0, 0, KST)
	if !got.Equal(want) || got.Location() != KST {
		t.Errorf("DayOf = %v, want %v", got, want)
	}
}

func TestParseYMD(t *testing.T) {
	got, err := ParseYMD("20260716")
	if err != nil {
		t.Fatal(err)
	}
	if !got.Equal(time.Date(2026, 7, 16, 0, 0, 0, 0, KST)) {
		t.Errorf("ParseYMD = %v", got)
	}
	if _, err := ParseYMD("2026-07-16"); err == nil {
		t.Error("expected error for dashed format")
	}
}
