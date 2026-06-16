package api

import (
	"encoding/json"
	"io"
	"net/http"

	"github.com/Moonjm/nunting/server/internal/db"
)

const (
	// maxFootprintSamples 한 배치가 담을 수 있는 샘플 수 상한. 변화량 기반이라
	// 실제론 훨씬 적지만, 비정상 클라가 거대한 배치로 DB 를 폭격하는 것 방어.
	maxFootprintSamples = 2000
	// maxFootprintLabelRunes label 길이 상한(rune 단위 — 한글 보드명 안전 절단).
	maxFootprintLabelRunes = 80
)

// POST /me/footprint  { "samples": [ {ts,label,mb,avail}, ... ] }
//
// iOS FootprintLogger 가 모아둔 메모리 footprint 샘플 배치. 변화량 기반 샘플링이라
// 평상시엔 거의 안 오고 백그라운드/경고/임계 도달 시 묶여 전송된다. 저장만 하고
// 해석/타임라인 렌더는 adminMetrics 가 한다. body 상한(256KB)은 라우터 maxBody 가 강제.
func (h *handlers) postFootprint(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "body too large or read error", http.StatusRequestEntityTooLarge)
		return
	}
	var batch struct {
		Samples []db.FootprintSample `json:"samples"`
	}
	if err := json.Unmarshal(body, &batch); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	if len(batch.Samples) == 0 {
		w.WriteHeader(http.StatusOK) // 빈 배치는 멱등 no-op
		return
	}
	if len(batch.Samples) > maxFootprintSamples {
		http.Error(w, "too many samples", http.StatusBadRequest)
		return
	}
	for i := range batch.Samples {
		if rs := []rune(batch.Samples[i].Label); len(rs) > maxFootprintLabelRunes {
			batch.Samples[i].Label = string(rs[:maxFootprintLabelRunes])
		}
	}
	if err := h.store.InsertFootprintSamples(r.Context(), UUIDFrom(r.Context()), batch.Samples); err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}
