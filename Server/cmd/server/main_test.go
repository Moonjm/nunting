package main

import (
	"net/url"
	"testing"
)

// TestPostgresDSN 은 env → DSN 조립이 (a) 기본값을 채우고 (b) 특수문자 password 를
// 깨지지 않게 인코딩하며 (c) 다시 parse 했을 때 각 구성요소가 정확히 복원되는지
// 검증한다. 프로덕션 Open(dsn) 경로의 유일한 순수 로직이라 DB 없이 단위 테스트.
func TestPostgresDSN(t *testing.T) {
	allKeys := []string{
		"NUNTING_DB_HOST", "NUNTING_DB_PORT", "NUNTING_DB_NAME",
		"NUNTING_DB_USER", "NUNTING_DB_PASSWORD", "NUNTING_DB_SSLMODE",
	}
	cases := []struct {
		name                                          string
		env                                           map[string]string
		wantUser, wantPass, wantHost, wantDB, wantSSL string
	}{
		{
			name:     "defaults",
			env:      map[string]string{},
			wantUser: "nnt", wantPass: "", wantHost: "localhost:5432", wantDB: "/nnt", wantSSL: "disable",
		},
		{
			name: "special-char password + custom host/port/sslmode",
			env: map[string]string{
				"NUNTING_DB_HOST":     "nnt-postgres",
				"NUNTING_DB_PORT":     "6543",
				"NUNTING_DB_PASSWORD": "p@ss:w/0rd ?#&=",
				"NUNTING_DB_SSLMODE":  "require",
			},
			wantUser: "nnt", wantPass: "p@ss:w/0rd ?#&=", wantHost: "nnt-postgres:6543", wantDB: "/nnt", wantSSL: "require",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// 주변 환경 영향 제거 — 모든 키를 빈 값으로(=envOr 가 기본값 사용) 둔 뒤 case 적용.
			for _, k := range allKeys {
				t.Setenv(k, "")
			}
			for k, v := range tc.env {
				t.Setenv(k, v)
			}

			dsn := postgresDSN()
			u, err := url.Parse(dsn)
			if err != nil {
				t.Fatalf("DSN not parseable: %v (dsn=%q)", err, dsn)
			}
			if u.Scheme != "postgres" {
				t.Errorf("scheme: got %q want postgres", u.Scheme)
			}
			if u.User.Username() != tc.wantUser {
				t.Errorf("user: got %q want %q", u.User.Username(), tc.wantUser)
			}
			if pass, _ := u.User.Password(); pass != tc.wantPass {
				t.Errorf("password round-trip: got %q want %q", pass, tc.wantPass)
			}
			if u.Host != tc.wantHost {
				t.Errorf("host: got %q want %q", u.Host, tc.wantHost)
			}
			if u.Path != tc.wantDB {
				t.Errorf("dbname: got %q want %q", u.Path, tc.wantDB)
			}
			if got := u.Query().Get("sslmode"); got != tc.wantSSL {
				t.Errorf("sslmode: got %q want %q", got, tc.wantSSL)
			}
		})
	}
}
