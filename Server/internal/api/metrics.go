package api

import (
	"crypto/subtle"
	"encoding/json"
	"html/template"
	"io"
	"log/slog"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"

	"github.com/Moonjm/nunting/server/internal/db"
)

// validMetricKinds POST /me/metrics 의 ?kind= 허용값. metric = MXMetricPayload
// (종료 사유 카운트 등 집계), diagnostic = MXDiagnosticPayload(크래시 콜스택 등),
// parser = iOS ParserFailureTelemetry 의 structureChanged 집계({site, phase, detail}
// 작은 JSON) — 사이트 마크업 개편을 기기 밖에서 관측하기 위한 채널.
// hang = iOS HangWatchdog 의 메인스레드 hang 리포트({ts, durationMs, label, samples[]})
// — MetricKit diagnostic 이 Xcode 설치 빌드에 전달되지 않아 만든 직접 수집 채널.
// media = iOS MediaLoadTelemetry 의 미디어 로드 배치({events:[{t,ts,ms,host,link,…}]})
// — 이미지 다운로드(net)/표시(show)/영상 준비(video) 세 계층의 소요 시간. "사진·영상이
// 느리다"의 원인이 회선인지 캐시 미스인지 특정 호스트인지 기기 밖에서 가르기 위한 채널.
// hitch = iOS FrameHitchRecorder 의 인터랙션 구간 프레임 히치({label, context,
// frameCount, droppedFrames, worstFrameMs, ...}) — hang 임계(1s) 아래로 새는
// "몇 프레임 빠짐" 을 보기 위한 채널. 히치가 있는 구간만 올라온다.
var validMetricKinds = map[string]bool{
	"metric": true, "diagnostic": true, "parser": true, "hang": true, "hitch": true,
	"media": true,
}

// POST /me/metrics?kind=metric|diagnostic|parser
//
// 본문은 MetricKit 의 jsonRepresentation() 을 가공 없이 보낸 raw JSON. 서버는
// kind 검증 + JSON 유효성만 확인하고 그대로 저장한다(해석은 adminMetrics 가).
// body 상한(1MB)은 라우터의 maxBody 미들웨어가 강제 — 초과 시 read 가 에러.
func (h *handlers) postMetrics(w http.ResponseWriter, r *http.Request) {
	// MetricKit 은 하루 1건가량이라 성공/실패 모두 로깅해도 스팸이 아니다.
	// "왜 metric_payloads 에 안 쌓이나"를 서버 로그만 봐도 판별할 수 있게, 모든
	// 거부 경로와 성공 수신을 남긴다(이전엔 전 경로 무로깅이라 서버에서 안 보였다).
	device := shortUUID(UUIDFrom(r.Context()))
	kind := r.URL.Query().Get("kind")
	if !validMetricKinds[kind] {
		slog.Warn("metrics_invalid_kind", "kind", kind, "device", device)
		http.Error(w, "invalid kind", http.StatusBadRequest)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		// MaxBytesReader 초과 포함 — 413 으로 본문 과대를 명시.
		slog.Warn("metrics_body_read_failed", "kind", kind, "device", device, "err", err)
		http.Error(w, "body too large or read error", http.StatusRequestEntityTooLarge)
		return
	}
	if len(body) == 0 || !json.Valid(body) {
		slog.Warn("metrics_invalid_json", "kind", kind, "device", device, "bytes", len(body))
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	if err := h.store.InsertMetricPayload(r.Context(), UUIDFrom(r.Context()), kind, string(body)); err != nil {
		slog.Error("metrics_insert_failed", "kind", kind, "device", device, "bytes", len(body), "err", err)
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
	slog.Info("metrics_received", "kind", kind, "device", device, "bytes", len(body))
	w.WriteHeader(http.StatusOK)
}

// adminMetricsLimit admin 뷰가 한 번에 읽어 렌더하는 payload 개수 상한. 저장은
// 무제한 누적이지만, 한 페이지가 과도하게 커지지 않게 최신 N 건만 보여준다.
// MetricKit 은 하루 1건가량이라 2000 이면 수년치.
const adminMetricsLimit = 2000

// GET /admin/metrics?key=<secret>
//
// 저장된 payload 를 파싱해 "왜 앱이 죽었나"를 한눈에 보여주는 HTML. 상단에 종료
// 사유 누적 카운트(foreground OOM/watchdog/크래시 등)를 강조하고, 아래 표에서
// payload 별 요약 + raw JSON(펼침)을 보여준다. 배포 안 하는 1인 도구라 ?key= 약한
// 비밀로 보호 — adminKey 가 "" 거나 불일치면 404(존재 자체를 숨김).
func (h *handlers) adminMetrics(w http.ResponseWriter, r *http.Request) {
	if h.adminKey == "" ||
		subtle.ConstantTimeCompare([]byte(r.URL.Query().Get("key")), []byte(h.adminKey)) != 1 {
		http.NotFound(w, r)
		return
	}

	rows, err := h.store.ListMetricPayloads(r.Context(), adminMetricsLimit)
	if err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
	fps, err := h.store.ListFootprintSamples(r.Context(), adminFootprintLimit)
	if err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}

	page := buildMetricsPage(rows)
	addFootprint(&page, fps)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := metricsTemplate.Execute(w, page); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
	}
}

// adminFootprintLimit admin 뷰가 렌더할 최신 footprint 샘플 수. 변화량 기반
// 샘플링이라 평상시엔 거의 안 쌓이지만, 페이지 비대 방지용 상한.
const adminFootprintLimit = 1500

// --- payload 파싱 (MetricKit jsonRepresentation 의 관심 필드만 느슨하게 디코드) ---

// exitData MXAppExitMetric 의 foreground/background 별 누적 종료 사유 카운트.
type exitData struct {
	Normal           int `json:"cumulativeNormalAppExitCount"`
	MemoryResource   int `json:"cumulativeMemoryResourceLimitExitCount"`
	MemoryPressure   int `json:"cumulativeMemoryPressureExitCount"`
	BadAccess        int `json:"cumulativeBadAccessExitCount"`
	Abnormal         int `json:"cumulativeAbnormalExitCount"`
	Watchdog         int `json:"cumulativeAppWatchdogExitCount"`
	CPUResource      int `json:"cumulativeCPUResourceLimitExitCount"`
	IllegalInstr     int `json:"cumulativeIllegalInstructionExitCount"`
	SuspendedLocked  int `json:"cumulativeSuspendedWithLockedFileExitCount"`
	BackgroundTaskAT int `json:"cumulativeBackgroundTaskAssertionTimeoutExitCount"`
}

type metricPayloadJSON struct {
	TimeStampEnd string `json:"timeStampEnd"`
	AppVersion   string `json:"appVersion"`
	// 실기기 jsonRepresentation() 의 키는 복수형 "applicationExitMetrics"
	// (MXMetricPayload 프로퍼티명 applicationExitMetric 과 다름 — 단수형으로
	// 디코드하면 전부 nil 이라 종료 카운트가 항상 0 으로 렌더됐다).
	ApplicationExitMetric *struct {
		Foreground exitData `json:"foregroundExitData"`
		Background exitData `json:"backgroundExitData"`
	} `json:"applicationExitMetrics"`
}

// diagnosticPayloadJSON 은 MXDiagnosticPayload 중 crash/hang 만 요약한다.
// cpuExceptionDiagnostics / diskWriteExceptionDiagnostics 는 "그냥 꺼짐" 진단과
// 무관해 의도적으로 요약에서 제외 — raw JSON 은 그대로 저장되므로 필요하면 펼쳐 본다.
type diagnosticPayloadJSON struct {
	CrashDiagnostics []struct {
		Meta struct {
			ExceptionType     json.RawMessage `json:"exceptionType"`
			Signal            json.RawMessage `json:"signal"`
			TerminationReason string          `json:"terminationReason"`
			AppVersion        string          `json:"appVersion"`
			OSVersion         string          `json:"osVersion"`
		} `json:"diagnosticMetaData"`
	} `json:"crashDiagnostics"`
	HangDiagnostics []json.RawMessage `json:"hangDiagnostics"`
}

// hangPayloadJSON 은 iOS HangWatchdog 리포트(kind=hang). 키는 Swift HangReportDTO 와 합의.
type hangPayloadJSON struct {
	DurationMs int    `json:"durationMs"`
	Label      string `json:"label"`
	Samples    []struct {
		AtMs   int      `json:"atMs"`
		Frames []string `json:"frames"`
	} `json:"samples"`
}

// hitchPayloadJSON 은 iOS FrameHitchRecorder 리포트(kind=hitch). 키는 Swift
// FrameHitchReportDTO 와 합의.
type hitchPayloadJSON struct {
	Label           string    `json:"label"`
	Context         string    `json:"context"`
	DurationMs      int       `json:"durationMs"`
	FrameCount      int       `json:"frameCount"`
	DroppedFrames   int       `json:"droppedFrames"`
	WorstFrameMs    float64   `json:"worstFrameMs"`
	ExpectedFrameMs float64   `json:"expectedFrameMs"`
	WorstFrames     []float64 `json:"worstFrames"`
	SessionDrags    int       `json:"sessionDrags"`
	WorstFrameAtMs  int       `json:"worstFrameAtMs"`
	MarkLabel       string    `json:"markLabel"`
	MarkAtMs        int       `json:"markAtMs"`
	DropsBeforeMark int       `json:"dropsBeforeMark"`
	DropsAfterMark  int       `json:"dropsAfterMark"`
}

// metricsSummary 상단 강조 박스 — 전체 payload 누적.
type metricsSummary struct {
	ForegroundOOM  int // foreground memory limit (앱 쓰는 중 OOM kill — 가장 흔한 "그냥 꺼짐")
	BackgroundOOM  int
	MemoryPressure int
	Watchdog       int
	BadAccess      int
	Abnormal       int
	NormalExit     int
	Crashes        int
	Hangs          int
	Hitches        int
	DroppedFrames  int
}

type metricsRow struct {
	Received string
	Kind     string
	UUID     string // 앞 12자만
	Summary  string
	Raw      string
}

type footprintRow struct {
	Time  string
	UUID  string
	Label string
	MB    int
	Avail int
	Live  int  // malloc size_in_use
	Alloc int  // malloc size_allocated
	Gap   int  // alloc-live = 단편화로 묶인 빈 페이지
	Delta int  // 직전(시간상 이전) 샘플 대비 MB 증감 — 누수 지점 가독성
	Hot   bool // 큰 폭 상승(>=50MB) 강조
}

type metricsPage struct {
	Summary metricsSummary
	Rows    []metricsRow
	Count   int

	Footprint      []footprintRow
	FootprintPeak  int
	FootprintCount int

	Media    mediaView
	mediaAgg mediaAgg
}

// addFootprint footprint 샘플을 시간순(오래된→최신)으로 정리해 페이지에 붙인다.
// Delta 는 **같은 기기(UUID)의** 시간상 직전 샘플 대비 증감이라, 메모리가 치솟거나
// (상승) "뒤로 갔는데 안 줄어든"(횡보) 지점을 표에서 바로 읽게 한다. 여러 기기가
// 섞여도 UUID 별로 직전값을 추적해 경계에서 Δ 가 오염되지 않는다(첫 샘플은 Δ=0).
// 표시는 최신이 위로 가게 뒤집는다.
func addFootprint(page *metricsPage, rows []db.FootprintRow) {
	page.FootprintCount = len(rows)
	if len(rows) == 0 {
		return
	}
	// ListFootprintSamples 는 최신순(id DESC) → 시간순으로 뒤집어 delta 계산.
	asc := make([]db.FootprintRow, len(rows))
	for i, r := range rows {
		asc[len(rows)-1-i] = r
	}
	prevByUUID := make(map[string]int, 4) // UUID 별 직전 MB
	built := make([]footprintRow, 0, len(asc))
	for _, r := range asc {
		delta := 0
		if p, ok := prevByUUID[r.UUID]; ok {
			delta = r.MB - p
		}
		prevByUUID[r.UUID] = r.MB
		if r.MB > page.FootprintPeak {
			page.FootprintPeak = r.MB
		}
		built = append(built, footprintRow{
			Time:  r.ClientTS.Local().Format("01-02 15:04:05"),
			UUID:  shortUUID(r.UUID),
			Label: r.Label,
			MB:    r.MB,
			Avail: r.AvailMB,
			Live:  r.LiveMB,
			Alloc: r.AllocMB,
			Gap:   r.AllocMB - r.LiveMB,
			Delta: delta,
			Hot:   delta >= 50,
		})
	}
	// 최신이 위로.
	for i, j := 0, len(built)-1; i < j; i, j = i+1, j-1 {
		built[i], built[j] = built[j], built[i]
	}
	page.Footprint = built
}

func buildMetricsPage(rows []db.MetricPayloadRow) metricsPage {
	page := metricsPage{Count: len(rows)}
	for _, row := range rows {
		vr := metricsRow{
			Received: row.ReceivedAt.Local().Format("2006-01-02 15:04"),
			Kind:     row.Kind,
			UUID:     shortUUID(row.UUID),
			Raw:      prettyJSON(row.Payload),
		}
		switch row.Kind {
		case "metric":
			vr.Summary = summarizeMetric(row.Payload, &page.Summary)
		case "diagnostic":
			vr.Summary = summarizeDiagnostic(row.Payload, &page.Summary)
		case "hang":
			vr.Summary = summarizeHang(row.Payload, &page.Summary)
		case "hitch":
			vr.Summary = summarizeHitch(row.Payload, &page.Summary)
		case "media":
			vr.Summary = summarizeMedia(row.Payload, &page.mediaAgg)
		}
		if vr.Summary == "" {
			vr.Summary = "—"
		}
		page.Rows = append(page.Rows, vr)
	}
	page.Media = page.mediaAgg.view()
	return page
}

func summarizeMetric(payload string, sum *metricsSummary) string {
	var m metricPayloadJSON
	if err := json.Unmarshal([]byte(payload), &m); err != nil || m.ApplicationExitMetric == nil {
		return ""
	}
	fg := m.ApplicationExitMetric.Foreground
	bg := m.ApplicationExitMetric.Background
	sum.ForegroundOOM += fg.MemoryResource
	sum.BackgroundOOM += bg.MemoryResource
	sum.MemoryPressure += fg.MemoryPressure + bg.MemoryPressure
	sum.Watchdog += fg.Watchdog + bg.Watchdog
	sum.BadAccess += fg.BadAccess + bg.BadAccess
	sum.Abnormal += fg.Abnormal + bg.Abnormal
	sum.NormalExit += fg.Normal + bg.Normal

	parts := []kv{
		{"fg-OOM", fg.MemoryResource},
		{"bg-OOM", bg.MemoryResource},
		{"mem-pressure", fg.MemoryPressure + bg.MemoryPressure},
		{"watchdog", fg.Watchdog + bg.Watchdog},
		{"bad-access", fg.BadAccess + bg.BadAccess},
		{"abnormal", fg.Abnormal + bg.Abnormal},
		{"normal", fg.Normal + bg.Normal},
	}
	return joinNonZero(parts)
}

func summarizeDiagnostic(payload string, sum *metricsSummary) string {
	var d diagnosticPayloadJSON
	if err := json.Unmarshal([]byte(payload), &d); err != nil {
		return ""
	}
	sum.Crashes += len(d.CrashDiagnostics)
	sum.Hangs += len(d.HangDiagnostics)
	if len(d.CrashDiagnostics) > 0 {
		c := d.CrashDiagnostics[0].Meta
		s := "crash"
		if c.TerminationReason != "" {
			s += ": " + c.TerminationReason
		} else if len(c.ExceptionType) > 0 {
			s += " exc=" + string(c.ExceptionType)
		}
		if len(d.CrashDiagnostics) > 1 {
			s += " (+more)"
		}
		return s
	}
	if len(d.HangDiagnostics) > 0 {
		return "hang"
	}
	return ""
}

// summarizeHang HangWatchdog 리포트 한 건을 "hang 3.1s @ post:open (2 samples ·
// top: <최심 앱 프레임>)" 형태로 요약하고 hangs 카드에 집계한다. 스택 전체는 raw
// JSON details 로 본다.
func summarizeHang(payload string, sum *metricsSummary) string {
	var h hangPayloadJSON
	if err := json.Unmarshal([]byte(payload), &h); err != nil {
		return ""
	}
	sum.Hangs++
	s := "hang " + strconv.FormatFloat(float64(h.DurationMs)/1000, 'f', 1, 64) + "s"
	if h.Label != "" {
		s += " @ " + h.Label
	}
	if n := len(h.Samples); n > 0 {
		s += " (" + strconv.Itoa(n) + " samples"
		if top := topFrame(h.Samples[0].Frames); top != "" {
			s += " · top: " + top
		}
		s += ")"
	}
	return s
}

// summarizeHitch FrameHitchRecorder 리포트 한 건을 "hitch 6 dropped / 42 frames ·
// worst 68ms (기대 8ms) @ backdrag · comments 210/400 (13번째)" 형태로 요약한다.
// 원인 특정에 쓰는 축은 두 개다: worst/expected 비율(얼마나 크게 걸렸나)과
// context(무엇이 화면에 실체화돼 있었나).
func summarizeHitch(payload string, sum *metricsSummary) string {
	var h hitchPayloadJSON
	if err := json.Unmarshal([]byte(payload), &h); err != nil {
		return ""
	}
	sum.Hitches++
	sum.DroppedFrames += h.DroppedFrames

	s := "hitch " + strconv.Itoa(h.DroppedFrames) + " dropped / " +
		strconv.Itoa(h.FrameCount) + " frames"
	s += " · worst " + strconv.FormatFloat(h.WorstFrameMs, 'f', 0, 64) + "ms"
	if h.ExpectedFrameMs > 0 {
		s += " (기대 " + strconv.FormatFloat(h.ExpectedFrameMs, 'f', 0, 64) + "ms)"
	}
	if h.WorstFrameAtMs > 0 {
		s += " @+" + strconv.Itoa(h.WorstFrameAtMs) + "ms"
	}
	if h.Label != "" {
		s += " @ " + h.Label
	}
	// 마크 앞/뒤 드랍 — 드래그 중에 걸렸는지, 그 뒤(스냅샷 해제·정착)에
	// 걸렸는지 가른다.
	if h.MarkLabel != "" {
		s += " · " + strconv.Itoa(h.DropsBeforeMark) + "전/" +
			strconv.Itoa(h.DropsAfterMark) + "후(" + h.MarkLabel +
			" +" + strconv.Itoa(h.MarkAtMs) + "ms)"
	}
	if h.Context != "" {
		s += " · " + h.Context
	}
	if h.SessionDrags > 0 {
		s += " (" + strconv.Itoa(h.SessionDrags) + "번째)"
	}
	return s
}

// topFrame 스택에서 원인 특정에 쓸 대표 프레임 — 첫 앱(nunting) 프레임을 고르고,
// 없으면(전부 시스템 프레임이면) 최상단 프레임을 쓴다.
func topFrame(frames []string) string {
	for _, f := range frames {
		if strings.Contains(f, "nunting") {
			return f
		}
	}
	if len(frames) > 0 {
		return frames[0]
	}
	return ""
}

type kv struct {
	k string
	v int
}

func joinNonZero(parts []kv) string {
	out := ""
	for _, p := range parts {
		if p.v == 0 {
			continue
		}
		if out != "" {
			out += "  "
		}
		out += p.k + ":" + strconv.Itoa(p.v)
	}
	return out
}

func shortUUID(u string) string {
	if len(u) > 12 {
		return u[:12] + "…"
	}
	return u
}

// prettyJSON raw 를 들여쓰기. 실패하면 원본 그대로(표시는 되게).
func prettyJSON(raw string) string {
	var v any
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		return raw
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return raw
	}
	return string(b)
}

var metricsTemplate = template.Must(template.New("metrics").Parse(`<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>nunting metrics</title>
<style>
 body{font:14px/1.5 -apple-system,system-ui,sans-serif;margin:16px;color:#222;background:#fafafa}
 h1{font-size:18px}
 .cards{display:flex;flex-wrap:wrap;gap:8px;margin:12px 0 20px}
 .card{background:#fff;border:1px solid #e2e2e2;border-radius:8px;padding:10px 14px;min-width:96px}
 .card .n{font-size:22px;font-weight:600}
 .card .l{font-size:11px;color:#777}
 .card.hot .n{color:#c0341d}
 table{width:100%;border-collapse:collapse;background:#fff}
 th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #eee;vertical-align:top}
 th{font-size:11px;color:#777;text-transform:uppercase}
 td.sum{font-family:ui-monospace,Menlo,monospace;font-size:12px}
 td.mono{font-family:ui-monospace,Menlo,monospace;font-size:12px}
 td.up{color:#c0341d;font-weight:600}
 td.down{color:#1a7f37}
 tr.hot td{background:#fff4f2}
 pre{white-space:pre-wrap;word-break:break-word;background:#f6f6f6;padding:8px;border-radius:6px;max-height:340px;overflow:auto;font-size:11px}
 details summary{cursor:pointer;color:#06c;font-size:12px}
 .empty{color:#999;padding:24px 0}
 h2{font-size:15px;margin-top:32px}
</style></head><body>
<h1>nunting metrics <span style="color:#999;font-weight:400">({{.Count}} payloads)</span></h1>
<div class="cards">
 <div class="card{{if .Summary.ForegroundOOM}} hot{{end}}"><div class="n">{{.Summary.ForegroundOOM}}</div><div class="l">fg OOM (사용 중 메모리 kill)</div></div>
 <div class="card"><div class="n">{{.Summary.BackgroundOOM}}</div><div class="l">bg OOM</div></div>
 <div class="card{{if .Summary.MemoryPressure}} hot{{end}}"><div class="n">{{.Summary.MemoryPressure}}</div><div class="l">mem pressure</div></div>
 <div class="card{{if .Summary.Watchdog}} hot{{end}}"><div class="n">{{.Summary.Watchdog}}</div><div class="l">watchdog</div></div>
 <div class="card{{if .Summary.Crashes}} hot{{end}}"><div class="n">{{.Summary.Crashes}}</div><div class="l">crashes</div></div>
 <div class="card{{if .Summary.BadAccess}} hot{{end}}"><div class="n">{{.Summary.BadAccess}}</div><div class="l">bad access</div></div>
 <div class="card"><div class="n">{{.Summary.Abnormal}}</div><div class="l">abnormal</div></div>
 <div class="card"><div class="n">{{.Summary.Hangs}}</div><div class="l">hangs</div></div>
 <div class="card{{if .Summary.Hitches}} hot{{end}}"><div class="n">{{.Summary.Hitches}}</div><div class="l">hitches</div></div>
 <div class="card"><div class="n">{{.Summary.DroppedFrames}}</div><div class="l">dropped frames</div></div>
 <div class="card"><div class="n">{{.Summary.NormalExit}}</div><div class="l">normal exit</div></div>
</div>
{{if .Rows}}
<table>
 <tr><th>received</th><th>kind</th><th>device</th><th>summary</th><th>raw</th></tr>
 {{range .Rows}}
 <tr>
  <td>{{.Received}}</td><td>{{.Kind}}</td><td>{{.UUID}}</td>
  <td class="sum">{{.Summary}}</td>
  <td><details><summary>json</summary><pre>{{.Raw}}</pre></details></td>
 </tr>
 {{end}}
</table>
{{else}}
<p class="empty">아직 수집된 payload 가 없어. MetricKit 은 하루 1회 전달이라 첫 데이터까지 시간이 걸려.</p>
{{end}}

<h2>memory footprint <span style="color:#999;font-weight:400">(peak {{.FootprintPeak}} MB · {{.FootprintCount}} samples)</span></h2>
{{if .Footprint}}
<p style="color:#777;font-size:12px">phys_footprint(=jetsam 이 보는 값). Δ 가 크게 +면 그 동작에서 메모리 급증, 뒤로 갔는데 안 줄면(Δ≈0 유지) 거기서 안 풀리는 것.</p>
<table>
 <tr><th>time</th><th>device</th><th>event</th><th>MB</th><th>Δ</th><th>avail</th><th>live</th><th>alloc</th><th>gap</th></tr>
 {{range .Footprint}}
 <tr{{if .Hot}} class="hot"{{end}}>
  <td class="mono">{{.Time}}</td><td>{{.UUID}}</td><td class="mono">{{.Label}}</td>
  <td class="mono">{{.MB}}</td>
  <td class="mono{{if gt .Delta 0}} up{{else if lt .Delta 0}} down{{end}}">{{if gt .Delta 0}}+{{end}}{{.Delta}}</td>
  <td class="mono">{{.Avail}}</td>
  <td class="mono">{{.Live}}</td>
  <td class="mono">{{.Alloc}}</td>
  <td class="mono">{{.Gap}}</td>
 </tr>
 {{end}}
</table>
{{else}}
<p class="empty">아직 footprint 샘플이 없어. 앱을 좀 쓰다 백그라운드로 보내면 배치 전송돼.</p>
{{end}}
<h2>미디어 로딩 <span style="color:#999;font-weight:400">({{.Media.Events}} events{{if .Media.Fails}} · 실패 {{.Media.Fails}}{{end}})</span></h2>
{{if .Media.Events}}
<p style="color:#777;font-size:12px">net=이미지 다운로드(URLSession 실측), show=슬롯이 뜬 뒤 그림이 채워지기까지(캐시 히트 포함 — 체감 시간), video=재생 준비까지. show 가 빠른데 net 이 느리면 프리페치가 가려주고 있는 것이고, show 의 net 비중이 높으면 캐시를 못 타는 것.</p>
<table>
 <tr><th>계층</th><th>건수</th><th>p50</th><th>p90</th><th>비고</th></tr>
 {{range .Media.Layers}}
 <tr><td class="mono">{{.Layer}}</td><td class="mono">{{.Count}}</td><td class="mono">{{.P50}}</td><td class="mono">{{.P90}}</td><td class="mono">{{.Note}}</td></tr>
 {{end}}
</table>
{{if .Media.Links}}
<h2 style="font-size:13px;margin-top:18px">링크별 다운로드 <span style="color:#999;font-weight:400">(회선이 느린 건지 앱이 느린 건지)</span></h2>
<table>
 <tr><th>link</th><th>건수</th><th>p50</th><th>p90</th><th>bytes</th></tr>
 {{range .Media.Links}}
 <tr><td class="mono">{{.Link}}</td><td class="mono">{{.Count}}</td><td class="mono">{{.P50}}</td><td class="mono">{{.P90}}</td><td class="mono">{{.Bytes}}</td></tr>
 {{end}}
</table>
{{end}}
{{if .Media.Hosts}}
<h2 style="font-size:13px;margin-top:18px">느린 호스트 <span style="color:#999;font-weight:400">(다운로드 p90 상위 5)</span></h2>
<table>
 <tr><th>host</th><th>건수</th><th>p50</th><th>p90</th></tr>
 {{range .Media.Hosts}}
 <tr><td class="mono">{{.Host}}</td><td class="mono">{{.Count}}</td><td class="mono">{{.P50}}</td><td class="mono">{{.P90}}</td></tr>
 {{end}}
</table>
{{end}}
{{else}}
<p class="empty">아직 미디어 로드 이벤트가 없어. 앱에서 글을 좀 열고 백그라운드로 보내면 배치 전송돼.</p>
{{end}}
</body></html>`))

// ---- 미디어 로딩(kind=media) ----

// mediaEventJSON 은 iOS MediaLoadEventDTO 한 건. 키는 Swift 쪽과 합의.
// 세 계층을 `t` 로 가른다: net(다운로드) / show(표시) / video(재생 준비).
type mediaEventJSON struct {
	T      string `json:"t"`
	Ms     int    `json:"ms"`
	Host   string `json:"host"`
	Ctx    string `json:"ctx"`
	Src    string `json:"src"`  // show: mem|disk|net
	Kind   string `json:"kind"` // video: mp4|webm
	Link   string `json:"link"` // wifi|cell|wired|none
	Bytes  int    `json:"bytes"`
	TTFB   int    `json:"ttfb"`
	Proto  string `json:"proto"`
	Status int    `json:"status"`
	Queued int    `json:"queued"` // net: 다운로더 슬롯 대기(ms)
	Px     int    `json:"px"`     // decode: 출력 픽셀 수
	OK     *bool  `json:"ok"`     // 실패일 때만 실린다(false)
}

type mediaPayloadJSON struct {
	Events []mediaEventJSON `json:"events"`
	// Cfg 이 배치가 나온 실행 설정("slots=4 build=137"). A/B 판정의 귀속 축이라
	// 행 요약 맨 앞에 세운다 — 없으면 어느 빌드의 숫자인지 사후에 못 가른다.
	Cfg string `json:"cfg"`
}

// mediaAgg 는 여러 배치에 걸친 이벤트를 계층·링크·호스트별로 누적한다.
// 퍼센타일을 내려면 원본 값이 필요해서 슬라이스로 들고 있는다 — 1인용 앱의
// 하루치(수천 건) 기준으로 메모리는 문제가 되지 않는다.
type mediaAgg struct {
	Events    int
	Fails     int
	NetMs     []int
	ShowMs    []int
	VideoMs   []int
	Bytes     int64
	Src       map[string]int   // show 캐시 출처 분포
	VideoKind map[string]int   // mp4/webm 건수
	LinkMs    map[string][]int // 링크별 net 소요
	LinkBytes map[string]int64
	HostMs    map[string][]int // 호스트별 net 소요
	QueuedMs  []int            // net 슬롯 대기 — 디코드가 슬롯을 붙잡는지 보는 축
	DecodeMs  []int
	DecodePx  []int
	DecodeBy  map[string]int // 코더별 디코드 건수
}

func (a *mediaAgg) add(e mediaEventJSON) {
	a.Events++
	if e.OK != nil && !*e.OK {
		a.Fails++
	}
	switch e.T {
	case "net":
		a.NetMs = append(a.NetMs, e.Ms)
		a.Bytes += int64(e.Bytes)
		if a.LinkMs == nil {
			a.LinkMs = map[string][]int{}
			a.LinkBytes = map[string]int64{}
		}
		if e.Link != "" {
			a.LinkMs[e.Link] = append(a.LinkMs[e.Link], e.Ms)
			a.LinkBytes[e.Link] += int64(e.Bytes)
		}
		if a.HostMs == nil {
			a.HostMs = map[string][]int{}
		}
		if e.Host != "" {
			a.HostMs[e.Host] = append(a.HostMs[e.Host], e.Ms)
		}
		if e.Queued > 0 {
			a.QueuedMs = append(a.QueuedMs, e.Queued)
		}
	case "decode":
		a.DecodeMs = append(a.DecodeMs, e.Ms)
		if e.Px > 0 {
			a.DecodePx = append(a.DecodePx, e.Px)
		}
		if a.DecodeBy == nil {
			a.DecodeBy = map[string]int{}
		}
		if e.Kind != "" {
			a.DecodeBy[e.Kind]++
		}
	case "show":
		a.ShowMs = append(a.ShowMs, e.Ms)
		if a.Src == nil {
			a.Src = map[string]int{}
		}
		if e.Src != "" {
			a.Src[e.Src]++
		}
	case "video":
		a.VideoMs = append(a.VideoMs, e.Ms)
		if a.VideoKind == nil {
			a.VideoKind = map[string]int{}
		}
		if e.Kind != "" {
			a.VideoKind[e.Kind]++
		}
	}
}

type mediaLayerRow struct {
	Layer string
	Count int
	P50   string
	P90   string
	Note  string
}

type mediaLinkRow struct {
	Link  string
	Count int
	P50   string
	P90   string
	Bytes string
}

type mediaHostRow struct {
	Host  string
	Count int
	P50   string
	P90   string
}

type mediaView struct {
	Events int
	Fails  int
	Layers []mediaLayerRow
	Links  []mediaLinkRow
	Hosts  []mediaHostRow
}

// view 누적치를 표로 만든다. 호스트는 p90 상위 5개만 — 전부 늘어놓으면
// "어디가 느린가"가 오히려 안 보인다(잘라낸 사실은 제목에 적는다).
func (a *mediaAgg) view() mediaView {
	v := mediaView{Events: a.Events, Fails: a.Fails}
	if a.Events == 0 {
		return v
	}
	if len(a.NetMs) > 0 {
		note := bytesLabel(a.Bytes)
		// 슬롯 대기 — 다운로드 자체는 짧은데 화면엔 늦게 뜨는 경우, 대기가 여기
		// 잡히면 원인은 다운로더 큐(디코드가 슬롯을 붙잡는 구조)다.
		if len(a.QueuedMs) > 0 {
			note += " · 대기 p50 " + msLabel(percentile(a.QueuedMs, 50)) +
				"/p90 " + msLabel(percentile(a.QueuedMs, 90))
		}
		v.Layers = append(v.Layers, mediaLayerRow{
			Layer: "net (다운로드)", Count: len(a.NetMs),
			P50: msLabel(percentile(a.NetMs, 50)), P90: msLabel(percentile(a.NetMs, 90)),
			Note: note,
		})
	}
	if len(a.DecodeMs) > 0 {
		note := countPairs(a.DecodeBy)
		// 픽셀 규모를 같이 봐야 "무거운 이미지라 오래 걸린 것"과 "가벼운데 밀린 것"이 갈린다.
		if len(a.DecodePx) > 0 {
			note += " · 중앙 " + megapixelLabel(percentile(a.DecodePx, 50)) +
				" / p90 " + megapixelLabel(percentile(a.DecodePx, 90))
		}
		v.Layers = append(v.Layers, mediaLayerRow{
			Layer: "decode (디코드)", Count: len(a.DecodeMs),
			P50: msLabel(percentile(a.DecodeMs, 50)), P90: msLabel(percentile(a.DecodeMs, 90)),
			Note: note,
		})
	}
	if len(a.ShowMs) > 0 {
		v.Layers = append(v.Layers, mediaLayerRow{
			Layer: "show (표시)", Count: len(a.ShowMs),
			P50: msLabel(percentile(a.ShowMs, 50)), P90: msLabel(percentile(a.ShowMs, 90)),
			Note: sharePairs(a.Src, len(a.ShowMs)),
		})
	}
	if len(a.VideoMs) > 0 {
		v.Layers = append(v.Layers, mediaLayerRow{
			Layer: "video (재생 준비)", Count: len(a.VideoMs),
			P50: msLabel(percentile(a.VideoMs, 50)), P90: msLabel(percentile(a.VideoMs, 90)),
			Note: countPairs(a.VideoKind),
		})
	}
	for link, ms := range a.LinkMs {
		v.Links = append(v.Links, mediaLinkRow{
			Link: link, Count: len(ms),
			P50: msLabel(percentile(ms, 50)), P90: msLabel(percentile(ms, 90)),
			Bytes: bytesLabel(a.LinkBytes[link]),
		})
	}
	sort.Slice(v.Links, func(i, j int) bool { return v.Links[i].Link < v.Links[j].Link })

	for host, ms := range a.HostMs {
		v.Hosts = append(v.Hosts, mediaHostRow{
			Host: host, Count: len(ms),
			P50: msLabel(percentile(ms, 50)), P90: msLabel(percentile(ms, 90)),
		})
	}
	sort.Slice(v.Hosts, func(i, j int) bool {
		pi, pj := percentile(a.HostMs[v.Hosts[i].Host], 90), percentile(a.HostMs[v.Hosts[j].Host], 90)
		if pi != pj {
			return pi > pj
		}
		return v.Hosts[i].Host < v.Hosts[j].Host
	})
	if len(v.Hosts) > 5 {
		v.Hosts = v.Hosts[:5]
	}
	return v
}

// summarizeMedia 배치 한 건의 행 요약 + 누적. 행 요약은 "이 배치가 무슨 상황이었나"를
// 한 줄로 보여주는 용도라 계층별 건수와 net p50 만 싣는다(분포는 아래 미디어 섹션).
func summarizeMedia(payload string, agg *mediaAgg) string {
	var p mediaPayloadJSON
	if err := json.Unmarshal([]byte(payload), &p); err != nil || len(p.Events) == 0 {
		return ""
	}
	before := *agg
	for _, e := range p.Events {
		agg.add(e)
	}
	batchNet := agg.NetMs[len(before.NetMs):]
	s := "media " + strconv.Itoa(len(p.Events)) + "건"
	if p.Cfg != "" {
		s = "[" + p.Cfg + "] " + s
	}
	if len(batchNet) > 0 {
		s += " · net " + strconv.Itoa(len(batchNet)) + "건 p50 " + msLabel(percentile(batchNet, 50))
	}
	if show := len(agg.ShowMs) - len(before.ShowMs); show > 0 {
		s += " · show " + strconv.Itoa(show) + "건"
	}
	if vid := len(agg.VideoMs) - len(before.VideoMs); vid > 0 {
		s += " · video " + strconv.Itoa(vid) + "건"
	}
	if fails := agg.Fails - before.Fails; fails > 0 {
		s += " · 실패 " + strconv.Itoa(fails)
	}
	return s
}

// percentile nearest-rank. 입력 순서는 상관없고(복사해 정렬), 빈 입력은 0.
func percentile(values []int, p float64) int {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]int(nil), values...)
	sort.Ints(sorted)
	idx := int(math.Ceil(p/100*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

// megapixelLabel 픽셀 수 → "3.1MP".
func megapixelLabel(px int) string {
	return strconv.FormatFloat(float64(px)/1_000_000, 'f', 1, 64) + "MP"
}

func msLabel(ms int) string {
	if ms < 1000 {
		return strconv.Itoa(ms) + "ms"
	}
	return strconv.FormatFloat(float64(ms)/1000, 'f', 1, 64) + "s"
}

func bytesLabel(n int64) string {
	if n <= 0 {
		return ""
	}
	mb := float64(n) / (1024 * 1024)
	if mb < 1 {
		return strconv.FormatFloat(float64(n)/1024, 'f', 0, 64) + "KB"
	}
	return strconv.FormatFloat(mb, 'f', 1, 64) + "MB"
}

// sharePairs {mem:5, net:5} → "mem 50% · net 50%" (건수 많은 순).
func sharePairs(m map[string]int, total int) string {
	if total == 0 {
		return ""
	}
	type kvs struct {
		k string
		v int
	}
	pairs := make([]kvs, 0, len(m))
	for k, v := range m {
		pairs = append(pairs, kvs{k, v})
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].v != pairs[j].v {
			return pairs[i].v > pairs[j].v
		}
		return pairs[i].k < pairs[j].k
	})
	out := ""
	for _, p := range pairs {
		if out != "" {
			out += " · "
		}
		out += p.k + " " + strconv.Itoa(p.v*100/total) + "%"
	}
	return out
}

// countPairs {webm:3, mp4:1} → "webm 3 · mp4 1".
func countPairs(m map[string]int) string {
	type kvs struct {
		k string
		v int
	}
	pairs := make([]kvs, 0, len(m))
	for k, v := range m {
		pairs = append(pairs, kvs{k, v})
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].v != pairs[j].v {
			return pairs[i].v > pairs[j].v
		}
		return pairs[i].k < pairs[j].k
	})
	out := ""
	for _, p := range pairs {
		if out != "" {
			out += " · "
		}
		out += p.k + " " + strconv.Itoa(p.v)
	}
	return out
}
