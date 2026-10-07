package melsicore

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
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

func TestSleepStateSurvivesEngineReload(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if strings.HasSuffix(r.URL.Path, "/delay") {
			fmt.Fprint(w, `{"delay":30}`)
		} else {
			fmt.Fprint(w, `{"now":"A"}`)
		}
	}))
	defer srv.Close()
	PauseEngine()
	PauseEngine()
	defer ResumeEngine()
	defer StopEngine()
	configuration := strings.Replace(cfg, "127.0.0.1:1", strings.TrimPrefix(srv.URL, "http://"), 1)
	for i := 0; i < 2; i++ {
		if err := StartEngine(configuration); err != nil {
			t.Fatal(err)
		}
		time.Sleep(20 * time.Millisecond)
		if calls.Load() != 0 {
			t.Fatal("starting/reloading a sleeping engine resumed network work")
		}
	}
	ResumeEngine()
	ResumeEngine()
	deadline := time.Now().Add(time.Second)
	for calls.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if calls.Load() == 0 {
		t.Fatal("wake did not resume the reloaded engine")
	}
}
