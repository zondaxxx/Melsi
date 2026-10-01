package melsicore

import (
	"encoding/json"
	"testing"
)

const cfg = `{"clash_api":"127.0.0.1:1","secret":"x","control_listen":"127.0.0.1:0",
 "groups":[{"selector":"proxy","auto":true,"candidates":[{"tag":"A"}]}]}`

func TestStartStopRepeated(t *testing.T) {
	if got := EngineStatus(); got != `{"groups":[]}` {
		t.Fatalf("stopped status: %s", got)
	}
	for i := 0; i < 3; i++ {
		if err := StartEngine(cfg); err != nil {
			t.Fatal(err)
		}
	}
	var st struct {
		Groups []struct {
			Selector string `json:"selector"`
		} `json:"groups"`
	}
	if err := json.Unmarshal([]byte(EngineStatus()), &st); err != nil || len(st.Groups) != 1 || st.Groups[0].Selector != "proxy" {
		t.Fatalf("status: %s", EngineStatus())
	}
	StopEngine()
	StopEngine()
	if got := EngineStatus(); got != `{"groups":[]}` {
		t.Fatalf("after stop: %s", got)
	}
	if err := StartEngine("{bad"); err == nil {
		t.Fatal("bad JSON must fail")
	}
	if Version() == "" {
		t.Fatal("empty version")
	}
}
