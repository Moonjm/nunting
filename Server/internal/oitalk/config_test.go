package oitalk

import "testing"

func setFullEnv(t *testing.T) {
	t.Helper()
	t.Setenv("OITALK_CLIENT_SECRET", "sec")
	t.Setenv("OITALK_ACCOUNT_ID", "acc")
	t.Setenv("OITALK_GROUP_ID", "grp")
	t.Setenv("OITALK_DEVICE_ID", "dev")
	t.Setenv("OITALK_MOBI_KEY", "mobi")
	t.Setenv("OITALK_CAR_NUM", "12가3456")
	t.Setenv("OITALK_RECV_PHONE", "+821012345678")
	t.Setenv("OITALK_VISIT_REASON", "")
	t.Setenv("TESLAMATE_MQTT_BROKER", "tcp://192.168.0.10:1883")
	t.Setenv("TESLAMATE_GEOFENCE", " 일산 ")
}

func TestConfigFromEnv_FullEnvEnabledWithDefaults(t *testing.T) {
	setFullEnv(t)
	c := ConfigFromEnv()
	if !c.Enabled() {
		t.Fatal("expected enabled")
	}
	if c.VisitReason != "세대 방문" {
		t.Errorf("VisitReason default = %q", c.VisitReason)
	}
	if c.BaseURL != "https://api.oitalk.net" {
		t.Errorf("BaseURL = %q", c.BaseURL)
	}
}

func TestConfigFromEnv_MissingAnyRequiredDisables(t *testing.T) {
	for _, key := range []string{
		"OITALK_CLIENT_SECRET", "OITALK_ACCOUNT_ID", "OITALK_GROUP_ID",
		"OITALK_DEVICE_ID", "OITALK_MOBI_KEY", "OITALK_CAR_NUM", "OITALK_RECV_PHONE",
	} {
		t.Run(key, func(t *testing.T) {
			setFullEnv(t)
			t.Setenv(key, "")
			if ConfigFromEnv().Enabled() {
				t.Errorf("expected disabled without %s", key)
			}
		})
	}
}

func TestMQTTConfigFromEnv(t *testing.T) {
	setFullEnv(t)
	m := MQTTConfigFromEnv()
	if !m.Enabled() {
		t.Fatal("expected enabled")
	}
	if m.Geofence != "일산" {
		t.Errorf("Geofence should be trimmed: %q", m.Geofence)
	}

	t.Setenv("TESLAMATE_MQTT_BROKER", "")
	if MQTTConfigFromEnv().Enabled() {
		t.Error("expected disabled without broker")
	}
	t.Setenv("TESLAMATE_MQTT_BROKER", "tcp://x:1883")
	t.Setenv("TESLAMATE_GEOFENCE", "")
	if MQTTConfigFromEnv().Enabled() {
		t.Error("expected disabled without geofence")
	}
}
