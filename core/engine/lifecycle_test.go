package engine

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func eventually(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("condition did not become true")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestManualLoopChecksOnlyCurrentButExplicitProbeChecksAll(t *testing.T) {
	f := newFakeClash(t, testSecret)
	f.now["proxy"] = "A"
	f.setDelay("A", 80)
	f.setDelay("B", 50)
	f.setDelay("C", 20)
	e, _ := newTestEngine(t, f, []GroupConfig{group("proxy", ModeBalanced, false, "A", "B", "C")}, Options{})
	if err := e.Start(); err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	g := mustGroup(t, e, "proxy")
	eventually(t, func() bool { return g.Status().Nodes[0].Samples == samplesPerRound })
	if f.callCount("B") != 0 || f.callCount("C") != 0 {
		t.Fatal("manual startup activated unused transports")
	}
	if err := g.Select(context.Background(), "B"); err != nil {
		t.Fatal(err)
	}
	eventually(t, func() bool { return g.Status().Nodes[1].Samples == samplesPerRound })
	if f.callCount("A") != samplesPerRound || f.callCount("C") != 0 {
		t.Fatal("manual switch probed nodes other than the selected one")
	}
	g.Probe(context.Background())
	if f.callCount("C") != samplesPerRound || g.Status().Current != "B" {
		t.Fatal("explicit probe must test every node without switching a manual choice")
	}
	g.SetAuto(context.Background(), true)
	eventually(t, func() bool { return g.Status().Nodes[2].Samples >= 2*samplesPerRound })
}

func TestManualFailureDoesNotEnableFastReprobe(t *testing.T) {
	f := newFakeClash(t, testSecret)
	f.now["proxy"] = "A"
	e, _ := newTestEngine(t, f, []GroupConfig{group("proxy", ModeBalanced, false, "A", "B")}, Options{})
	g := mustGroup(t, e, "proxy")
	g.initCurrent(context.Background())
	g.Probe(context.Background())
	if g.inFailover() {
		t.Fatal("manual mode must keep its normal probe interval after failure")
	}
}

func TestPauseCancelsProbeWithoutLossAndResumeRetainsSelection(t *testing.T) {
	started := make(chan struct{}, 1)
	cancelled := make(chan struct{}, 1)
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/delay") {
			fmt.Fprint(w, `{"now":"A"}`)
			return
		}
		if calls.Add(1) == 1 {
			started <- struct{}{}
			<-r.Context().Done()
			cancelled <- struct{}{}
			return
		}
		fmt.Fprint(w, `{"delay":80}`)
	}))
	defer srv.Close()
	e, err := New(&Config{ClashAPI: srv.URL, Groups: []GroupConfig{group("proxy", ModeBalanced, true, "A")}}, Options{})
	if err != nil {
		t.Fatal(err)
	}
	e.sampleSpacing = time.Millisecond
	if err := e.Start(); err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("probe did not start")
	}
	e.Pause()
	e.Pause()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("pause did not cancel the active request")
	}
	g := mustGroup(t, e, "proxy")
	// This also waits until the cancelled round has released its probe lock.
	g.Probe(context.Background())
	st := g.Status()
	if calls.Load() != 1 || st.Nodes[0].Samples != 0 || st.Nodes[0].Loss != 0 || st.Nodes[0].LastError != "" || st.LastSwitch != nil || g.inFailover() {
		t.Fatalf("sleep was treated as a dead server: calls=%d status=%+v", calls.Load(), st)
	}
	e.Resume()
	e.Resume()
	eventually(t, func() bool { return g.Status().Nodes[0].Samples == samplesPerRound })
	if g.Status().Current != "A" || calls.Load() != 1+samplesPerRound {
		t.Fatal("resume lost selection or started duplicate rounds")
	}
	e.Pause()
	if err := e.Close(); err != nil {
		t.Fatal(err)
	}
	e.Resume()
	e.Resume()
	time.Sleep(20 * time.Millisecond)
	if calls.Load() != 1+samplesPerRound {
		t.Fatal("resume restarted a closed engine")
	}
}

func TestStartPausedMakesNoRequestsAndCloseDoesNotWaitForWake(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1) }))
	defer srv.Close()
	e, err := New(&Config{ClashAPI: srv.URL, Groups: []GroupConfig{group("proxy", ModeBalanced, true, "A")}}, Options{})
	if err != nil {
		t.Fatal(err)
	}
	e.Pause()
	if err := e.Start(); err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	time.Sleep(20 * time.Millisecond)
	closed := make(chan struct{})
	go func() { _ = e.Close(); close(closed) }()
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("paused engine shutdown blocked")
	}
	if calls.Load() != 0 {
		t.Fatal("paused startup contacted the proxy core")
	}
}

func TestProbeConcurrencyIsSharedAcrossGroups(t *testing.T) {
	started := make(chan struct{}, 10)
	var active, peak atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/delay") {
			fmt.Fprint(w, `{"now":"A"}`)
			return
		}
		n := active.Add(1)
		defer active.Add(-1)
		for old := peak.Load(); n > old && !peak.CompareAndSwap(old, n); old = peak.Load() {
		}
		started <- struct{}{}
		<-r.Context().Done()
	}))
	defer srv.Close()
	e, err := New(&Config{ClashAPI: srv.URL, Groups: []GroupConfig{
		group("proxy", ModeBalanced, true, "A", "B", "C"),
		group("game", ModeGame, true, "A", "B", "C"),
	}}, Options{ProbeConcurrency: 2})
	if err != nil {
		t.Fatal(err)
	}
	if err := e.Start(); err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	for i := 0; i < 2; i++ {
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("probe capacity was not used")
		}
	}
	select {
	case <-started:
		t.Fatal("groups have independent concurrency limits")
	case <-time.After(20 * time.Millisecond):
	}
	e.Pause()
	eventually(t, func() bool { return active.Load() == 0 })
	if peak.Load() != 2 {
		t.Fatalf("active probe peak=%d want 2", peak.Load())
	}
}
