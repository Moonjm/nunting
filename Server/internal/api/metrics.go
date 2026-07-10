package api

import (
	"crypto/subtle"
	"encoding/json"
	"html/template"
	"io"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/Moonjm/nunting/server/internal/db"
)

// validMetricKinds POST /me/metrics 의 ?kind= 허용값. metric = MXMetricPayload
// (종료 사유 카운트 등 집계), diagnostic = MXDiagnosticPayload(크래시 콜스택 등),
// parser = iOS ParserFailureTelemetry 의 structureChanged 집계({site, phase, detail}
// 작은 JSON) — 사이트 마크업 개편을 기기 밖에서 관측하기 위한 채널.
var validMetricKinds = map[string]bool{"metric": true, "diagnostic": true, "parser": true}

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
	TimeStampEnd          string `json:"timeStampEnd"`
	AppVersion            string `json:"appVersion"`
	ApplicationExitMetric *struct {
		Foreground exitData `json:"foregroundExitData"`
		Background exitData `json:"backgroundExitData"`
	} `json:"applicationExitMetric"`
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
		}
		if vr.Summary == "" {
			vr.Summary = "—"
		}
		page.Rows = append(page.Rows, vr)
	}
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
</body></html>`))
