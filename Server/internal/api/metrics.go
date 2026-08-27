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
// — 이미지 다운로드(net)/표시(show)/디코드(decode) 세 계층의 소요 시간. "사진이
// 느리다"의 원인이 회선인지 캐시 미스인지 특정 호스트인지 기기 밖에서 가르기 위한 채널.
// hitch = iOS FrameHitchRecorder 의 인터랙션 구간 프레임 히치({label, context,
// frameCount, droppedFrames, worstFrameMs, ...}) — hang 임계(1s) 아래로 새는
// "몇 프레임 빠짐" 을 보기 위한 채널. 히치가 있는 구간만 올라온다.
var validMetricKinds = map[string]bool{
	"metric": true, "diagnostic": true, "parser": true, "hang": true, "hitch": true,
	// fetch = iOS FetchTelemetry 의 HTML fetch 시도 배치({events:[{ts,ms,host,path,
	// status?,err?,attempt?,pf?,link?}]}) — 목록/상세/댓글이 실제로 받은 응답을
	// 남긴다. 429(즉시 거절)와 타임아웃(8s 물림)은 화면엔 똑같이 "다시 시도" 로
	// 보이지만 대응이 정반대라, 기기 밖에서 가를 채널이 필요했다.
	"media": true, "fetch": true,
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

// adminMetricsPerKindLimit admin 뷰가 **kind 마다** 읽어 렌더하는 payload 개수 상한.
//
// 전체 최신 N 건으로 자르면 말 많은 kind 가 조용한 kind 를 밀어낸다. media 는 글
// 하나 열 때마다 배치가 나오고(하루 수백 건) hang/diagnostic 은 며칠에 한 번이라,
// 창을 공유하면 정작 드물고 중요한 쪽이 먼저 사라진다 — OOM/행 추적이 그때 막힌다.
//
// 400 인 이유: media 400 배치면 이틀치가 넘어 A/B 판정에 모자라지 않는다. 페이지
// 크기는 이 상한이 아니라 `mediaRawLimit` 이 잡는다 — 말 많은 kind 의 무게는 건수가
// 아니라 배치 하나에 실린 raw JSON 이었다.
//
// 저장은 여전히 무제한 — 자르는 건 렌더 대상뿐이다.
const adminMetricsPerKindLimit = 400

// mediaRawLimit 표에서 raw JSON 을 펼쳐 싣는 media 배치 수(최신순).
//
// media 배치 하나가 HTML 로 ~15KB 라 400건이면 5.9MB — 전체 8.1MB 페이지의 73% 가
// 이 raw 였고, 그게 겨우 이틀치였다. 정작 판정에 쓰는 건 위쪽 "미디어 로딩" 집계
// (설정별 net/show/decode p50·p90, 링크·호스트 분포)라 배치 원본은 거의 안 펼친다.
//
// 그래도 0 이 아닌 이유: 집계가 굴리지 않는 건별 필드(queued/ttfb/proto/reused)를
// 눈으로 확인할 자리가 페이지에 하나는 있어야 DB 를 안 뒤진다. 최신 몇 건이면 된다.
//
// 잘리는 건 raw 뿐이다 — 400 배치 전부 한 줄 요약으로 남고 집계에도 그대로 들어간다.
const mediaRawLimit = 3

// fetchRawLimit 표에서 raw JSON 을 펼쳐 싣는 fetch 배치 수(최신순).
//
// media 와 같은 이유·같은 값이다. fetch 배치 하나가 HTML 로 ~6KB 라 상한이
// 없으면 400건에 2.3MB — 지금 페이지 전체 크기와 맞먹고, `mediaRawLimit` 이
// 막아 둔 8.1MB 시절을 그대로 재현한다(Codex 리뷰 P2). 판정에 쓰는 건 아래
// "HTML fetch" 집계(429 비율·호스트별)라 배치 원본은 거의 안 펼친다.
const fetchRawLimit = 3

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

	rows, err := h.store.ListMetricPayloadsPerKind(r.Context(), adminMetricsPerKindLimit)
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

	Media     mediaSectionView
	mediaAggs mediaAggSet
	Fetch     fetchSectionView
	fetchAgg  fetchAgg
}

// mediaAggSet 은 **설정(cfg)별로** 집계를 나눠 담는다.
//
// 전부 한 집계에 부으면 실험군과 대조군의 백분위가 합쳐져, `cfg` 를 넣은 이유
// (A/B 귀속) 자체가 무의미해진다. 등장 순서를 따로 들고 있는 건 payload 를
// 최신순으로 훑기 때문이다 — 최근에 돌린 설정이 위에 온다.
type mediaAggSet struct {
	order []string
	byCfg map[string]*mediaAgg
}

// mediaUnknownCfg cfg 를 안 싣던 시절의 배치. 섞지 않고 따로 모은다.
const mediaUnknownCfg = "(설정 미상)"

// mediaConfigLimit 렌더할 설정 블록 수 상한. A/B 는 최근 몇 개만 보면 되고,
// 전부 늘어놓으면 페이지가 설정 수만큼 길어진다(잘라낸 사실은 제목에 적는다).
const mediaConfigLimit = 6

func (s *mediaAggSet) for_(cfg string) *mediaAgg {
	if cfg == "" {
		cfg = mediaUnknownCfg
	}
	if s.byCfg == nil {
		s.byCfg = map[string]*mediaAgg{}
	}
	if agg, ok := s.byCfg[cfg]; ok {
		return agg
	}
	agg := &mediaAgg{}
	s.byCfg[cfg] = agg
	s.order = append(s.order, cfg)
	return agg
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
	mediaSeen := 0
	fetchSeen := 0
	for _, row := range rows {
		vr := metricsRow{
			Received: row.ReceivedAt.Local().Format("2006-01-02 15:04"),
			Kind:     row.Kind,
			UUID:     shortUUID(row.UUID),
		}
		// raw 를 안 실을 행은 `prettyJSON` 도 부르지 않는다 — media 배치가 400건이라
		// 버리려고 만드는 문자열이 곧 페이지 한 장 분량이다.
		keepRaw := true
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
			// 집계는 전 건을 먹는다. 잘리는 건 아래 raw 뿐.
			vr.Summary = summarizeMedia(row.Payload, &page.mediaAggs)
			mediaSeen++
			keepRaw = mediaSeen <= mediaRawLimit
		case "fetch":
			vr.Summary = summarizeFetch(row.Payload, &page.fetchAgg)
			fetchSeen++
			keepRaw = fetchSeen <= fetchRawLimit
		}
		if keepRaw {
			vr.Raw = prettyJSON(row.Payload)
		}
		if vr.Summary == "" {
			vr.Summary = "—"
		}
		page.Rows = append(page.Rows, vr)
	}
	page.Media = page.mediaAggs.view()
	page.Fetch = page.fetchAgg.view()
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
  <td>{{if .Raw}}<details><summary>json</summary><pre>{{.Raw}}</pre></details>{{else}}—{{end}}</td>
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
<h2>HTML fetch <span style="color:#999;font-weight:400">({{.Fetch.Events}} 시도{{if .Fetch.Limited}} · 429 {{.Fetch.Limited}} ({{.Fetch.LimitedPct}}){{end}}{{if .Fetch.Hidden}} · 호스트 {{.Fetch.Hidden}}개 생략{{end}})</span></h2>
{{if .Fetch.Events}}
<p style="color:#777;font-size:12px">목록/상세/댓글이 실제로 받은 응답. <b>429 는 사이트의 요청률 제한</b>이고 화면엔 "다시 시도" 로만 보여서, 이 표 없이는 타임아웃과 구분되지 않는다. 판정 지표는 <b>429 비율</b>. 재시도(att≥2)와 프리페치 비중이 높으면 예산을 그쪽이 먹고 있는 것이다.</p>
<table>
 <tr><th>host</th><th>시도</th><th>200</th><th>429</th><th>429 비율</th><th>실패</th><th>재시도</th><th>프리페치</th><th>p50</th><th>p90</th></tr>
 {{range .Fetch.Hosts}}
 <tr>
  <td class="mono">{{.Host}}</td><td class="mono">{{.Events}}</td><td class="mono">{{.OK}}</td>
  <td class="mono{{if .Limited}} up{{end}}">{{.Limited}}</td><td class="mono">{{.LimitedPct}}</td>
  <td class="mono{{if .Failed}} up{{end}}">{{.Failed}}</td>
  <td class="mono">{{.Retries}}</td><td class="mono">{{.Prefetch}}</td>
  <td class="mono">{{.P50}}</td><td class="mono">{{.P90}}</td>
 </tr>
 {{end}}
</table>
{{else}}
<p class="empty">아직 fetch 이벤트가 없어. 앱에서 목록/글을 좀 열고 백그라운드로 보내면 배치 전송돼.</p>
{{end}}
<h2>미디어 로딩 <span style="color:#999;font-weight:400">({{.Media.Events}} events{{if .Media.Fails}} · 실패 {{.Media.Fails}}{{end}}{{if .Media.Hidden}} · 설정 {{.Media.Hidden}}개 생략{{end}})</span></h2>
{{if .Media.Events}}
<p style="color:#777;font-size:12px">net=이미지 다운로드(URLSession 실측), show=슬롯이 뜬 뒤 그림이 채워지기까지(캐시 히트 포함 — 체감 시간), decode=디코드. show 가 빠른데 net 이 느리면 프리페치가 가려주고 있는 것이고, show 의 net 비중이 높으면 캐시를 못 타는 것. <b>분포는 실행 설정(cfg)별로 나눠 낸다</b> — 섞으면 A/B 비교가 안 된다.</p>
{{range .Media.Configs}}
<h3 style="font-size:13px;margin-top:22px;border-top:1px solid #e2e2e2;padding-top:12px">{{.Cfg}} <span style="color:#999;font-weight:400">({{.Events}} events{{if .Fails}} · 실패 {{.Fails}}{{end}})</span></h3>
<table>
 <tr><th>계층</th><th>건수</th><th>p50</th><th>p90</th><th>비고</th></tr>
 {{range .Layers}}
 <tr><td class="mono">{{.Layer}}</td><td class="mono">{{.Count}}</td><td class="mono">{{.P50}}</td><td class="mono">{{.P90}}</td><td class="mono">{{.Note}}</td></tr>
 {{end}}
</table>
{{if .Links}}
<table style="margin-top:8px">
 <tr><th>link</th><th>건수</th><th>p50</th><th>p90</th><th>bytes</th></tr>
 {{range .Links}}
 <tr><td class="mono">{{.Link}}</td><td class="mono">{{.Count}}</td><td class="mono">{{.P50}}</td><td class="mono">{{.P90}}</td><td class="mono">{{.Bytes}}</td></tr>
 {{end}}
</table>
{{end}}
{{if .Hosts}}
<table style="margin-top:8px">
 <tr><th>느린 호스트 (p90 상위 5)</th><th>건수</th><th>p50</th><th>p90</th></tr>
 {{range .Hosts}}
 <tr><td class="mono">{{.Host}}</td><td class="mono">{{.Count}}</td><td class="mono">{{.P50}}</td><td class="mono">{{.P90}}</td></tr>
 {{end}}
</table>
{{end}}
{{end}}
{{else}}
<p class="empty">아직 미디어 로드 이벤트가 없어. 앱에서 글을 좀 열고 백그라운드로 보내면 배치 전송돼.</p>
{{end}}
</body></html>`))

// ---- 미디어 로딩(kind=media) ----

// mediaEventJSON 은 iOS MediaLoadEventDTO 한 건. 키는 Swift 쪽과 합의.
// 세 계층을 `t` 로 가른다: net(다운로드) / show(표시) / decode(디코드).
type mediaEventJSON struct {
	T      string `json:"t"`
	Ms     int    `json:"ms"`
	Host   string `json:"host"`
	Ctx    string `json:"ctx"`
	Src    string `json:"src"`  // show: mem|disk|net
	Kind   string `json:"kind"` // decode: 디코드 경로 이름
	Link   string `json:"link"` // wifi|cell|wired|none
	Bytes  int    `json:"bytes"`
	TTFB   int    `json:"ttfb"`
	Proto  string `json:"proto"`
	Status int    `json:"status"`
	// Queued net 다운로더 슬롯 대기(ms). 포인터인 이유는 **측정된 0 과 측정 안 됨을
	// 갈라야** 하기 때문이다. 같은 밀리초에 시작하면 클라이언트가 정당하게 0 을
	// 싣는데, 그걸 버리면 기다린 요청만으로 백분위가 나와 대기 압력이 과장된다.
	Queued *int  `json:"queued"`
	Px     int   `json:"px"` // decode: 출력 픽셀 수
	PF     bool  `json:"pf"` // net: 프리페치 요청(표시 요청이면 없음)
	OK     *bool `json:"ok"` // 실패일 때만 실린다(false)
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
	Events     int
	Fails      int
	NetMs      []int
	ShowMs     []int
	Bytes      int64
	Src        map[string]int   // show 캐시 출처 분포
	LinkMs     map[string][]int // 링크별 net 소요
	LinkBytes  map[string]int64
	HostMs     map[string][]int // 호스트별 net 소요
	QueuedMs   []int            // net 슬롯 대기 — 디코드가 슬롯을 붙잡는지 보는 축
	QueuedPF   []int            // 그중 프리페치 요청의 대기
	QueuedShow []int            // 그중 표시 요청의 대기
	DecodeMs   []int
	DecodePx   []int
	DecodeBy   map[string]int // 코더별 디코드 건수
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
		if e.Queued != nil {
			a.QueuedMs = append(a.QueuedMs, *e.Queued)
			// 대기의 정체를 가르는 축. 프리페치가 큐를 채우고 있으면 표시 요청이 그
			// 뒤에 줄 서는 구조이고, 그건 슬롯 수가 아니라 순서/양의 문제다.
			if e.PF {
				a.QueuedPF = append(a.QueuedPF, *e.Queued)
			} else {
				a.QueuedShow = append(a.QueuedShow, *e.Queued)
			}
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

// mediaSectionView 미디어 섹션 전체. 합계는 헤더용이고, 분포는 설정별로 나뉜다.
type mediaSectionView struct {
	Events  int
	Fails   int
	Configs []mediaConfigView
	Hidden  int // 상한에 걸려 안 그린 설정 수
}

// mediaConfigView 설정 하나의 분포. `mediaView` 를 묻어 템플릿에서 그대로 쓴다.
type mediaConfigView struct {
	Cfg string
	mediaView
}

// view 설정별 블록을 최신 설정부터 만든다. 합계(Events/Fails)는 전 설정 합이다 —
// 헤더의 "얼마나 쌓였나" 는 나눌 이유가 없다.
func (s *mediaAggSet) view() mediaSectionView {
	out := mediaSectionView{}
	for _, cfg := range s.order {
		agg := s.byCfg[cfg]
		out.Events += agg.Events
		out.Fails += agg.Fails
		if len(out.Configs) >= mediaConfigLimit {
			out.Hidden++
			continue
		}
		out.Configs = append(out.Configs, mediaConfigView{Cfg: cfg, mediaView: agg.view()})
	}
	return out
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
		// 슬롯 대기 — 다운로드 자체는 짧은데 화면엔 늦게 뜨는 경우, 여기 잡히면
		// 원인은 다운로더 큐다.
		if len(a.QueuedMs) > 0 {
			note += " · 대기 p50 " + msLabel(percentile(a.QueuedMs, 50)) +
				"/p90 " + msLabel(percentile(a.QueuedMs, 90))
		}
		// 기다린 게 프리페치인지 표시 요청인지 — 처방이 갈린다.
		if len(a.QueuedPF) > 0 {
			note += " · 프리페치 " + strconv.Itoa(len(a.QueuedPF)) + "건 대기 p90 " +
				msLabel(percentile(a.QueuedPF, 90))
		}
		if len(a.QueuedShow) > 0 {
			note += " · 표시 " + strconv.Itoa(len(a.QueuedShow)) + "건 대기 p90 " +
				msLabel(percentile(a.QueuedShow, 90))
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

// ---- HTML fetch(kind=fetch) 집계 -------------------------------------------
//
// 판정에 쓰는 값은 하나다: **429 비율**. 사이트가 IP 당 요청률을 제한하면
// 목록/상세/댓글이 조용히 거절당하는데, 화면엔 전부 똑같이 "다시 시도" 로만
// 보여 기기 안에서는 원인을 못 가른다. 여기서 호스트별로 200/429/실패와
// 재시도·프리페치 비중을 같이 낸다 — 429 가 남았을 때 "요청을 누가 쓰고
// 있나"를 바로 짚기 위해서다.

// fetchPayloadJSON iOS FetchTelemetry 배치. 키는 Swift 쪽과 합의.
type fetchPayloadJSON struct {
	Events []fetchEventJSON `json:"events"`
}

// fetchEventJSON 시도 한 건. status 와 attempt 는 포인터 — 0 과 "없음"을
// 가려야 한다(응답 없는 실패는 status 자체가 없고, attempt 는 1 이면 생략된다).
type fetchEventJSON struct {
	Ms      int    `json:"ms"`
	Host    string `json:"host"`
	Status  *int   `json:"status"`
	Err     string `json:"err"`
	Attempt *int   `json:"attempt"`
	Pf      *bool  `json:"pf"`
}

// fetchHostLimit 렌더할 호스트 수 상한. 조용한 호스트까지 전부 늘어놓으면
// 표가 사이트 수만큼 길어진다 — 건수 상위만 본다.
const fetchHostLimit = 8

type fetchHostAgg struct {
	events   int
	ok       int
	limited  int
	failed   int
	retries  int
	prefetch int
	ms       []int
}

type fetchAgg struct {
	events int
	order  []string
	byHost map[string]*fetchHostAgg
}

func (a *fetchAgg) add(e fetchEventJSON) {
	if a.byHost == nil {
		a.byHost = map[string]*fetchHostAgg{}
	}
	host := e.Host
	if host == "" {
		host = "?"
	}
	agg, ok := a.byHost[host]
	if !ok {
		agg = &fetchHostAgg{}
		a.byHost[host] = agg
		a.order = append(a.order, host)
	}
	a.events++
	agg.events++
	agg.ms = append(agg.ms, e.Ms)
	switch {
	case e.Status != nil && *e.Status == 429:
		agg.limited++
	case e.Status != nil && *e.Status >= 200 && *e.Status < 300:
		agg.ok++
	default:
		agg.failed++
	}
	if e.Attempt != nil && *e.Attempt > 1 {
		agg.retries++
	}
	if e.Pf != nil && *e.Pf {
		agg.prefetch++
	}
}

type fetchHostView struct {
	Host                                           string
	Events, OK, Limited, Failed, Retries, Prefetch int
	LimitedPct                                     string
	P50, P90                                       string
}

type fetchSectionView struct {
	Events     int
	Limited    int
	LimitedPct string
	Hidden     int
	Hosts      []fetchHostView
}

func (a *fetchAgg) view() fetchSectionView {
	v := fetchSectionView{Events: a.events}
	hosts := append([]string(nil), a.order...)
	sort.SliceStable(hosts, func(i, j int) bool {
		return a.byHost[hosts[i]].events > a.byHost[hosts[j]].events
	})
	// 섹션 합계는 **생략된 호스트까지** 센다. 자르고 나서 더하면 429 를
	// 표시된 호스트에서만 모으면서 분모는 전체 시도 수라 비율이 낮게 나오고,
	// 429 가 전부 생략된 호스트에 있으면 헤더에서 429 가 통째로 사라진다
	// (템플릿이 `{{if .Fetch.Limited}}` 로 감싸므로). 판정 지표가 바로 그
	// 비율이라 이 오차는 결론을 뒤집는다 — Codex 리뷰 P2.
	for _, host := range hosts {
		v.Limited += a.byHost[host].limited
	}
	v.LimitedPct = pctLabel(v.Limited, v.Events)

	// 자르는 건 렌더 목록뿐이다.
	if len(hosts) > fetchHostLimit {
		v.Hidden = len(hosts) - fetchHostLimit
		hosts = hosts[:fetchHostLimit]
	}
	for _, host := range hosts {
		agg := a.byHost[host]
		v.Hosts = append(v.Hosts, fetchHostView{
			Host:       host,
			Events:     agg.events,
			OK:         agg.ok,
			Limited:    agg.limited,
			Failed:     agg.failed,
			Retries:    agg.retries,
			Prefetch:   agg.prefetch,
			LimitedPct: pctLabel(agg.limited, agg.events),
			P50:        msLabel(percentile(agg.ms, 50)),
			P90:        msLabel(percentile(agg.ms, 90)),
		})
	}
	return v
}

// pctLabel 정수 퍼센트. 분모 0 이면 빈 문자열 — "0%" 로 찍으면 데이터가 없는
// 것과 정말 0 인 것이 구분되지 않는다.
func pctLabel(part, total int) string {
	if total <= 0 {
		return ""
	}
	return strconv.Itoa(part*100/total) + "%"
}

// summarizeFetch 배치 한 건의 행 요약 + 누적. 행 요약엔 이 배치의 상태 분포만
// 싣는다(호스트별 분포는 아래 fetch 섹션).
func summarizeFetch(payload string, agg *fetchAgg) string {
	var p fetchPayloadJSON
	if err := json.Unmarshal([]byte(payload), &p); err != nil || len(p.Events) == 0 {
		return ""
	}
	ok, limited, failed := 0, 0, 0
	for _, e := range p.Events {
		agg.add(e)
		switch {
		case e.Status != nil && *e.Status == 429:
			limited++
		case e.Status != nil && *e.Status >= 200 && *e.Status < 300:
			ok++
		default:
			failed++
		}
	}
	s := "fetch " + strconv.Itoa(len(p.Events)) + "건 · 200:" + strconv.Itoa(ok)
	if limited > 0 {
		s += " · 429:" + strconv.Itoa(limited)
	}
	if failed > 0 {
		s += " · 실패:" + strconv.Itoa(failed)
	}
	return s
}

// summarizeMedia 배치 한 건의 행 요약 + 누적. 행 요약은 "이 배치가 무슨 상황이었나"를
// 한 줄로 보여주는 용도라 계층별 건수와 net p50 만 싣는다(분포는 아래 미디어 섹션).
func summarizeMedia(payload string, set *mediaAggSet) string {
	var p mediaPayloadJSON
	if err := json.Unmarshal([]byte(payload), &p); err != nil || len(p.Events) == 0 {
		return ""
	}
	agg := set.for_(p.Cfg)
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
