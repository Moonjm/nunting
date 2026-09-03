package oitalk

import (
	"os"
	"strings"
)

const (
	defaultBaseURL = "https://api.oitalk.net"
	mqttClientID   = "nunting-oitalk"
)

// Config 오이톡 API 자격증명·등록 파라미터. 전부 env(OITALK_*) 주입.
// client_secret 은 오이톡 계정 전체를 여는 열쇠 — 로그에 남기지 않는다.
type Config struct {
	BaseURL      string
	ClientSecret string
	AccountID    string
	GroupID      string
	DeviceID     string
	MobiKey      string
	CarNum       string
	RecvPhone    string // E.164
	VisitReason  string
}

// Enabled 필수 env 가 모두 있어야 true. 하나라도 비면 watcher 는 뜨지 않는다.
func (c Config) Enabled() bool {
	return c.ClientSecret != "" && c.AccountID != "" && c.GroupID != "" &&
		c.DeviceID != "" && c.MobiKey != "" && c.CarNum != "" && c.RecvPhone != ""
}

// ConfigFromEnv OITALK_* env 를 읽는다. 기본값: 사유 "세대 방문".
func ConfigFromEnv() Config {
	return Config{
		BaseURL:      defaultBaseURL,
		ClientSecret: os.Getenv("OITALK_CLIENT_SECRET"),
		AccountID:    os.Getenv("OITALK_ACCOUNT_ID"),
		GroupID:      os.Getenv("OITALK_GROUP_ID"),
		DeviceID:     os.Getenv("OITALK_DEVICE_ID"),
		MobiKey:      os.Getenv("OITALK_MOBI_KEY"),
		CarNum:       os.Getenv("OITALK_CAR_NUM"),
		RecvPhone:    os.Getenv("OITALK_RECV_PHONE"),
		VisitReason:  envOr("OITALK_VISIT_REASON", "세대 방문"),
	}
}

// MQTTConfig TeslaMate 브로커 접속 + 매칭할 지오펜스 이름. 브로커는 익명(공식
// compose 의 mosquitto-no-auth) 전제라 인증 필드가 없다.
type MQTTConfig struct {
	Broker   string // tcp://host:1883
	Geofence string // TESLAMATE_GEOFENCE — trim 후 정확 일치
}

// Enabled 브로커 주소와 지오펜스 이름이 둘 다 있어야 true.
func (m MQTTConfig) Enabled() bool {
	return m.Broker != "" && m.Geofence != ""
}

// MQTTConfigFromEnv TESLAMATE_* env 를 읽는다.
func MQTTConfigFromEnv() MQTTConfig {
	return MQTTConfig{
		Broker:   os.Getenv("TESLAMATE_MQTT_BROKER"),
		Geofence: strings.TrimSpace(os.Getenv("TESLAMATE_GEOFENCE")),
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
