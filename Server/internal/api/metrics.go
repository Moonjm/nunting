package api

import (
	"crypto/subtle"
	"encoding/json"
	"html/template"
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/Moonjm/nunting/server/internal/db"
)

// validMetricKinds POST /me/metrics 의 ?kind= 허용값. metric = MXMetricPayload
// (종료 사유 카운트 등 집계), diagnostic = MXDiagnosticPayload(크래시 콜스택 등).
var validMetricKinds = map[string]bool{"metric": true, "diagnostic": true}

// POST /me/metrics?kind=metric|diagnostic
//
// 본문은 MetricKit 의 jsonRepresentation() 을 가공 없이 보낸 raw JSON. 서버는
// kind 검증 + JSON 유효성만 확인하고 그대로 저장한다(해석은 adminMetrics 가).
// body 상한(1MB)은 라우터의 maxBody 미들웨어가 강제 — 초과 시 read 가 에러.
func (h *handlers) postMetrics(w http.ResponseWriter, r *http.Request) {
	kind := r.URL.Query().Get("kind")
	if !validMetricKinds[kind] {
		http.Error(w, "invalid kind", http.StatusBadRequest)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		// MaxBytesReader 초과 포함 — 413 으로 본문 과대를 명시.
		http.Error(w, "body too large or read error", http.StatusRequestEntityTooLarge)
		return
	}
	if len(body) == 0 || !json.Valid(body) {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	if err := h.store.InsertMetricPayload(r.Context(), UUIDFrom(r.Context()), kind, string(body)); err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
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

	page := buildMetricsPage(rows)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := metricsTemplate.Execute(w, page); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
	}
}

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

type metricsPage struct {
	Summary metricsSummary
	Rows    []metricsRow
	Count   int
}

func buildMetricsPage(rows []db.MetricPayloadRow) metricsPage {
	page := metricsPage{Count: len(rows)}
	for _, row := range rows {
		vr := metricsRow{
			Received: time.Unix(row.ReceivedAt, 0).Format("2006-01-02 15:04"),
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
 pre{white-space:pre-wrap;word-break:break-word;background:#f6f6f6;padding:8px;border-radius:6px;max-height:340px;overflow:auto;font-size:11px}
 details summary{cursor:pointer;color:#06c;font-size:12px}
 .empty{color:#999;padding:24px 0}
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
</body></html>`))
