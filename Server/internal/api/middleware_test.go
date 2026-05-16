package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Moonjm/nunting/server/internal/db"
)

// helper: 미들웨어로 감싼 echo 핸들러. 통과 시 context 의 uuid 를 body 로.
func wrappedEcho(t *testing.T) (http.Handler, *db.Store) {
	t.Helper()
	store, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	echo := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(UUIDFrom(r.Context())))
	})
	return BearerAuth(store)(echo), store
}

func TestBearerAuth_MissingHeader_401(t *testing.T) {
	h, store := wrappedEcho(t)
	defer store.Close()

	req := httptest.NewRequest("GET", "/me/_echo", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)

	if w.Code != 401 {
		t.Errorf("want 401, got %d", w.Code)
	}
}

func TestBearerAuth_WrongPrefix_401(t *testing.T) {
	h, store := wrappedEcho(t)
	defer store.Close()

	req := httptest.NewRequest("GET", "/me/_echo", nil)
	req.Header.Set("Authorization", "Bearer wrong_foobar")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)

	if w.Code != 401 {
		t.Errorf("want 401, got %d", w.Code)
	}
}

func TestBearerAuth_Valid_UpsertsAndEchoesUUID(t *testing.T) {
	h, store := wrappedEcho(t)
	defer store.Close()

	req := httptest.NewRequest("GET", "/me/_echo", nil)
	req.Header.Set("Authorization", "Bearer nnt_abc")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Fatalf("want 200, got %d (body=%s)", w.Code, w.Body.String())
	}
	if w.Body.String() != "nnt_abc" {
		t.Errorf("want body 'nnt_abc', got %q", w.Body.String())
	}

	// upsert 가 실제로 row 를 만들었는지 확인 (GetPushToken 은 row 없어도 nil 반환).
	exists, err := store.UserExists(req.Context(), "nnt_abc")
	if err != nil {
		t.Errorf("UserExists query: %v", err)
	}
	if !exists {
		t.Errorf("user nnt_abc not upserted to DB")
	}
}
