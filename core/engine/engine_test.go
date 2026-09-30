package engine

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"net/url"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const testSecret = "s3cret"

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time          { return c.t }
func (c *fakeClock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newTestEngine(t *testing.T, f *fakeClash, groups []GroupConfig, opts Options) (*Engine, *fakeClock) {
	t.Helper()
	cfg := &Config{ClashAPI: f.addr(), Secret: testSecret, Groups: groups}
	e, err := New(cfg, opts)
	if err != nil {
		t.Fatal(err)
	}
	clk := &fakeClock{t: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
	e.now = clk.now
	e.sampleSpacing = time.Millisecond
	e.retryDelay = time.Millisecond
	return e, clk
}

func group(sel string, mode Mode, auto bool, tags ...string) GroupConfig {
	g := GroupConfig{Selector: sel, Mode: mode, Auto: auto, IntervalSec: 60}
	for _, tag := range tags {
		g.Candidates = append(g.Candidates, Candidate{Tag: tag, Type: "vless"})
	}
	return g
}

func mustGroup(t *testing.T, e *Engine, sel string) *Group {
	t.Helper()
	g, ok := e.Group(sel)
	if !ok {
		t.Fatalf("group %q missing", sel)
	}
	return g
}

// --- stats & scoring -------------------------------------------------------

func TestStatsEWMAJitterLoss(t *testing.T) {
	var s nodeStats
	s.add(100, nil)
	if s.ewma != 100 || s.jitter != 0 {
		t.Fatalf("first sample: ewma=%v jitter=%v", s.ewma, s.jitter)
	}
	s.add(200, nil)
	if want := 0.3*200 + 0.7*100; math.Abs(s.ewma-want) > 1e-9 {
		t.Fatalf("ewma=%v want %v", s.ewma, want)
	}
	if want := 0.3 * 100; math.Abs(s.jitter-want) > 1e-9 {
		t.Fatalf("jitter=%v want %v", s.jitter, want)
	}
	s.add(0, errors.New("timeout"))
	if !s.alive() || s.consecFail != 1 {
		t.Fatal("one failure must not kill a node")
	}
	if got := s.loss(); math.Abs(got-1.0/3) > 1e-9 {
		t.Fatalf("loss=%v", got)
	}
	s.add(0, errors.New("timeout"))
	if s.alive() || !s.dead() {
		t.Fatal("two consecutive failures must mark dead")
	}
	if !math.IsInf(s.score(ModeBalanced, false), 1) {
		t.Fatal("dead node must score +Inf")
	}
	s.add(50, nil)
	if !s.alive() || s.lastError != "" {
		t.Fatal("success must revive")
	}
	// ok ok fail fail ok -> 2 transitions
	if s.flaps() != 2 {
		t.Fatalf("flaps=%d", s.flaps())
	}
}

func TestLossWindowSlides(t *testing.T) {
	var s nodeStats
	for i := 0; i < 5; i++ {
		s.add(0, errors.New("x"))
	}
	for i := 0; i < lossWindow; i++ {
		s.add(10, nil)
	}
	if s.loss() != 0 {
		t.Fatalf("old failures should have left the window, loss=%v", s.loss())
	}
	if s.samples != 5+lossWindow {
		t.Fatalf("samples=%d", s.samples)
	}
}

func TestNeverProbedIsNeitherAliveNorDead(t *testing.T) {
	var s nodeStats
	if s.alive() || s.dead() {
		t.Fatal("fresh node must be unknown")
	}
}

func TestScoreModes(t *testing.T) {
	const ewma, jit, loss = 50.0, 10.0, 0.1
	cases := []struct {
		mode Mode
		udp  bool
		want float64
	}{
		{ModeLatency, false, 50},
		{ModeBalanced, false, 50 + 20 + 80},
		{ModeStability, false, 50 + 30 + 200 + 2*flapPenalty},
		{ModeGame, false, 50 + 40 + 300},
		{ModeGame, true, (50 + 40 + 300) * 0.85},
		{ModeBalanced, true, 50 + 20 + 80}, // UDP bonus only in game mode
	}
	for _, c := range cases {
		if got := scoreOf(c.mode, c.udp, ewma, jit, loss, 2); math.Abs(got-c.want) > 1e-9 {
			t.Errorf("%s udp=%v: got %v want %v", c.mode, c.udp, got, c.want)
		}
	}
}

func TestParseConfigDefaults(t *testing.T) {
	cfg, err := ParseConfig([]byte(`{"secret":"x","groups":[{"selector":"proxy","auto":true,
		"candidates":[{"tag":"a"},{"tag":"a"},{"tag":""},{"tag":"🇩🇪 DE-1","type":"hysteria2","udp_native":true}]}]}`))
	if err != nil {
		t.Fatal(err)
	}
	g := cfg.Groups[0]
	if cfg.ClashAPI != DefaultClashAPI || g.Mode != ModeBalanced || g.IntervalSec != 60 ||
		g.TimeoutMs != 3000 || g.ProbeURL != DefaultProbeURL {
		t.Fatalf("defaults not applied: %+v %+v", cfg, g)
	}
	if len(g.Candidates) != 2 || !g.Candidates[1].UDPNative {
		t.Fatalf("candidates: %+v", g.Candidates)
	}
	if _, err := ParseConfig([]byte(`{"groups":[{"selector":"p","mode":"turbo"}]}`)); err == nil {
		t.Fatal("unknown mode must fail")
	}
	if _, err := ParseConfig([]byte(`{"groups":[{"selector":"p"},{"selector":"p"}]}`)); err == nil {
		t.Fatal("duplicate selector must fail")
	}
}

// --- switching policy ------------------------------------------------------

func TestInitialCurrentAndSwitchToMuchBetter(t *testing.T) {
	f := newFakeClash(t, testSecret)
	f.now["proxy"] = "A"
	f.setDelay("A", 200)
	f.setDelay("B", 40)
	e, _ := newTestEngine(t, f, []GroupConfig{group("proxy", ModeBalanced, true, "A", "B")}, Options{})
	g := mustGroup(t, e, "proxy")
	g.initCurrent(context.Background())
	if g.Status().Current != "A" {
		t.Fatalf("current=%q", g.Status().Current)
	}
	g.Probe(context.Background())
	st := g.Status()
	if st.Current != "B" || f.current("proxy") != "B" {
		t.Fatalf("expected switch to B, status=%+v fake=%s", st, f.current("proxy"))
	}
	if st.LastSwitch == nil || st.LastSwitch.From != "A" || st.LastSwitch.To != "B" ||
		st.LastSwitch.Reason != "latency 40ms vs 200ms" {
		t.Fatalf("last_switch=%+v", st.LastSwitch)
	}
	if _, err := time.Parse(time.RFC3339, st.LastSwitch.At); err != nil {
		t.Fatalf("at not RFC3339: %v", err)
	}
	for _, n := range st.Nodes {
		if n.Samples != samplesPerRound || !n.Alive {
			t.Fatalf("node %+v", n)
		}
	}
}

func TestHysteresisThresholds(t *testing.T) {
	cases := []struct {
		name    string
		cur, bt int
		switchs bool
	}{
		{"15% better: stay", 100, 85, false},
		{"25% better: switch", 100, 75, true},
		{">20% but <10ms: stay", 30, 21, false},
		{"worse: stay", 50, 80, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFakeClash(t, testSecret)
			f.now["proxy"] = "A"
			f.setDelay("A", c.cur)
			f.setDelay("B", c.bt)
			e, _ := newTestEngine(t, f, []GroupConfig{group("proxy", ModeLatency, true, "A", "B")}, Options{})
			g := mustGroup(t, e, "proxy")
			g.initCurrent(context.Background())
			g.Probe(context.Background())
			if got := g.Status().Current == "B"; got != c.switchs {
				t.Fatalf("switched=%v want %v", got, c.switchs)
			}
		})
	}
}

func TestMinDwell(t *testing.T) {
	for _, c := range []struct {
		mode  Mode
		dwell time.Duration
	}{{ModeBalanced, 30 * time.Second}, {ModeLatency, 30 * time.Second}, {ModeStability, 120 * time.Second}, {ModeGame, 120 * time.Second}} {
		t.Run(string(c.mode), func(t *testing.T) {
			f := newFakeClash(t, testSecret)
			f.now["proxy"] = "A"
			f.setDelay("A", 300)
			f.setDelay("B", 100)
			f.setDelay("C", 900)
			e, clk := newTestEngine(t, f, []GroupConfig{group("proxy", c.mode, true, "A", "B", "C")}, Options{})
			g := mustGroup(t, e, "proxy")
			g.initCurrent(context.Background())
			g.Probe(context.Background())
			if g.Status().Current != "B" {
				t.Fatalf("want B, got %s", g.Status().Current)
			}
			// C becomes much better, but dwell has not elapsed.
			f.setDelay("C", 10)
			f.setDelay("B", 100)
			for i := 0; i < 8; i++ { // let EWMA converge
				g.Probe(context.Background())
			}
			clk.advance(c.dwell - time.Second)
			g.Probe(context.Background())
			if g.Status().Current != "B" {
				t.Fatalf("switched before dwell: %s", g.Status().Current)
			}
			clk.advance(2 * time.Second)
			g.Probe(context.Background())
			if g.Status().Current != "C" {
				t.Fatalf("did not switch after dwell: %s", g.Status().Current)
			}
		})
	}
}

func TestFailoverIgnoresDwell(t *testing.T) {
	f := newFakeClash(t, testSecret)
	f.now["proxy"] = "DE-1"
	f.setDelay("DE-1", 50)
	f.setDelay("NL-1", 55)
	e, _ := newTestEngine(t, f, []GroupConfig{group("proxy", ModeStability, true, "DE-1", "NL-1")}, Options{})
	g := mustGroup(t, e, "proxy")
	g.initCurrent(context.Background())
	// A recent manual switch starts the dwell timer.
	if err := g.Select(context.Background(), "DE-1"); err != nil {
		t.Fatal(err)
	}
	g.SetAuto(context.Background(), true)
	g.Probe(context.Background())
	if g.Status().Current != "DE-1" {
		t.Fatal("should stay on DE-1")
	}
	f.setDelay("DE-1", 0)
	g.Probe(context.Background())
	st := g.Status()
	if st.Current != "NL-1" || f.current("proxy") != "NL-1" {
		t.Fatalf("no failover: %+v", st)
	}
	if st.LastSwitch.Reason != "failover: DE-1 unreachable" {
		t.Fatalf("reason=%q", st.LastSwitch.Reason)
	}
	if st.Nodes[0].Alive || st.Nodes[0].Score != -1 || st.Nodes[0].LastError == "" {
		t.Fatalf("dead node status: %+v", st.Nodes[0])
	}
}

func TestSingleLossDoesNotFailover(t *testing.T) {
	f := newFakeClash(t, testSecret)
	f.now["proxy"] = "A"
	f.setDelay("A", 50)
	f.setDelay("B", 55)
	// Latency mode ignores loss, so only a (wrong) failover could switch here.
	e, _ := newTestEngine(t, f, []GroupConfig{group("proxy", ModeLatency, true, "A", "B")}, Options{})
	g := mustGroup(t, e, "proxy")
	g.initCurrent(context.Background())
	g.Probe(context.Background())
	f.setSeq("A", 50, 0, 50)
	g.Probe(context.Background())
	if g.Status().Current != "A" {
		t.Fatal("a single lost sample must not trigger failover")
	}
}

func TestJitterReason(t *testing.T) {
	f := newFakeClash(t, testSecret)
	f.now["proxy"] = "A"
	e, _ := newTestEngine(t, f, []GroupConfig{group("proxy", ModeBalanced, true, "A", "B")}, Options{})
	g := mustGroup(t, e, "proxy")
	g.initCurrent(context.Background())
	for i := 0; i < 5; i++ {
		f.setSeq("A", 30, 90, 30)
		f.setSeq("B", 40, 42, 40)
		g.Probe(context.Background())
	}
	st := g.Status()
	if st.Current != "B" {
		t.Fatalf("expected switch to stable B: %+v", st)
	}
	if !strings.HasPrefix(st.LastSwitch.Reason, "jitter ") {
		t.Fatalf("reason=%q", st.LastSwitch.Reason)
	}
}

func TestGameModePrefersUDPNative(t *testing.T) {
	f := newFakeClash(t, testSecret)
	f.now["game"] = "TCP"
	f.setDelay("TCP", 60)
	f.setDelay("HY2", 64)
	gc := GroupConfig{Selector: "game", Auto: true, Mode: ModeGame, Candidates: []Candidate{
		{Tag: "TCP", Type: "vless"}, {Tag: "HY2", Type: "hysteria2", UDPNative: true},
	}}
	e, _ := newTestEngine(t, f, []GroupConfig{gc}, Options{})
	g := mustGroup(t, e, "game")
	g.initCurrent(context.Background())
	g.Probe(context.Background())
	st := g.Status()
	if st.Nodes[1].Score >= st.Nodes[0].Score {
		t.Fatalf("UDP-native bonus missing: %+v", st.Nodes)
	}
	// 64*0.85=54.4 vs 60 is <20% better -> hysteresis keeps TCP.
	if st.Current != "TCP" {
		t.Fatalf("hysteresis violated: %s", st.Current)
	}
}

func TestAllDeadNoSwitch(t *testing.T) {
	f := newFakeClash(t, testSecret)
	f.now["proxy"] = "A"
	e, _ := newTestEngine(t, f, []GroupConfig{group("proxy", ModeBalanced, true, "A", "B")}, Options{})
	g := mustGroup(t, e, "proxy")
	g.initCurrent(context.Background())
	g.Probe(context.Background())
	if f.putCount() != 0 || g.Status().Current != "A" {
		t.Fatal("must not switch when everything is dead")
	}
	if !g.inFailover() {
		t.Fatal("all-dead group should be in failover")
	}
	// Dead nodes get at most deadAfter samples per round.
	if n := f.callCount("A"); n != deadAfter {
		t.Fatalf("calls=%d", n)
	}
}

func TestAutoOffProbesButNeverSwitches(t *testing.T) {
	f := newFakeClash(t, testSecret)
	f.now["proxy"] = "A"
	f.setDelay("A", 0)
	f.setDelay("B", 20)
	e, _ := newTestEngine(t, f, []GroupConfig{group("proxy", ModeBalanced, false, "A", "B")}, Options{})
	g := mustGroup(t, e, "proxy")
	g.initCurrent(context.Background())
	g.Probe(context.Background())
	st := g.Status()
	if f.putCount() != 0 || st.Current != "A" {
		t.Fatalf("auto=false must not switch: %+v", st)
	}
	if st.Nodes[1].Samples != samplesPerRound || st.Nodes[1].LatencyMs != 20 {
		t.Fatalf("stats not collected: %+v", st.Nodes[1])
	}
	// Turning auto on applies the policy immediately.
	g.SetAuto(context.Background(), true)
	if g.Status().Current != "B" {
		t.Fatal("auto on should failover right away")
	}
}

// --- loop behaviour --------------------------------------------------------

func TestLoopFastReprobeInFailoverAndCleanShutdown(t *testing.T) {
	f := newFakeClash(t, testSecret)
	f.now["proxy"] = "A"
	before := runtime.NumGoroutine()
	e, _ := newTestEngine(t, f, []GroupConfig{group("proxy", ModeBalanced, true, "A")}, Options{})
	e.failoverEvery = 10 * time.Millisecond
	if err := e.Start(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for f.callCount("A") < 4*deadAfter && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if f.callCount("A") < 4*deadAfter {
		t.Fatalf("no fast re-probe, calls=%d", f.callCount("A"))
	}
	f.setDelay("A", 30)
	deadline = time.Now().Add(3 * time.Second)
	for !mustGroup(t, e, "proxy").Status().Nodes[0].Alive && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	calls := f.callCount("A")
	time.Sleep(100 * time.Millisecond)
	if extra := f.callCount("A") - calls; extra > samplesPerRound {
		t.Fatalf("still fast probing after recovery: %d extra calls", extra)
	}
	if err := e.Close(); err != nil {
		t.Fatal(err)
	}
	_ = e.Close() // idempotent
	waitGoroutines(t, before)
}

func waitGoroutines(t *testing.T, want int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for runtime.NumGoroutine() > want+2 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if n := runtime.NumGoroutine(); n > want+2 {
		buf := make([]byte, 1<<16)
		t.Fatalf("goroutine leak: %d > %d\n%s", n, want, buf[:runtime.Stack(buf, true)])
	}
}

// --- control API -----------------------------------------------------------

type apiClient struct {
	t    *testing.T
	base string
}

func (c apiClient) do(method, path, token string, body any) (int, []byte) {
	c.t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, c.base+path, rd)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, data
}

func TestControlAPI(t *testing.T) {
	const sel = "🎮 game/udp"
	f := newFakeClash(t, testSecret)
	f.now["proxy"] = "A"
	f.now[sel] = "A"
	f.setDelay("A", 50)
	f.setDelay("B", 52)
	var stopped atomic.Int32
	e, _ := newTestEngine(t, f, []GroupConfig{
		group("proxy", ModeBalanced, true, "A", "B"),
		group(sel, ModeGame, true, "A", "B"),
	}, Options{OnStop: func() { stopped.Add(1) }})
	e.cfg.ControlListen = "127.0.0.1:0"
	if err := e.Start(); err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	c := apiClient{t, "http://" + e.Addr()}
	esc := "/groups/" + url.PathEscape(sel)

	if code, _ := c.do("GET", "/health", "", nil); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", code)
	}
	if code, _ := c.do("GET", "/status", "wrong", nil); code != http.StatusUnauthorized {
		t.Fatalf("bad token: %d", code)
	}

	code, body := c.do("GET", "/health", testSecret, nil)
	var health map[string]any
	_ = json.Unmarshal(body, &health)
	if code != 200 || health["ok"] != true || health["sing_box"] == "" || health["version"] == "" {
		t.Fatalf("health %d %s", code, body)
	}
	if _, ok := health["uptime_sec"].(float64); !ok {
		t.Fatalf("uptime_sec missing: %s", body)
	}

	code, body = c.do("POST", esc+"/probe", testSecret, nil)
	var gs GroupStatus
	if err := json.Unmarshal(body, &gs); err != nil || code != 200 || gs.Selector != sel || len(gs.Nodes) != 2 || gs.Nodes[0].Samples == 0 {
		t.Fatalf("probe %d %s", code, body)
	}

	code, body = c.do("POST", esc+"/mode", testSecret, map[string]string{"mode": "stability"})
	_ = json.Unmarshal(body, &gs)
	if code != 200 || gs.Mode != ModeStability {
		t.Fatalf("mode %d %s", code, body)
	}
	if code, _ := c.do("POST", esc+"/mode", testSecret, map[string]string{"mode": "warp"}); code != 400 {
		t.Fatalf("bad mode: %d", code)
	}

	code, body = c.do("POST", esc+"/select", testSecret, map[string]string{"tag": "B"})
	_ = json.Unmarshal(body, &gs)
	if code != 200 || gs.Auto || gs.Current != "B" || f.current(sel) != "B" || gs.LastSwitch.Reason != "manual" {
		t.Fatalf("select %d %s", code, body)
	}
	if code, _ := c.do("POST", esc+"/select", testSecret, map[string]string{"tag": "missing"}); code != 400 {
		t.Fatalf("select missing: %d", code)
	}

	code, body = c.do("POST", esc+"/auto", testSecret, map[string]bool{"auto": true})
	_ = json.Unmarshal(body, &gs)
	if code != 200 || !gs.Auto {
		t.Fatalf("auto %d %s", code, body)
	}
	if code, _ := c.do("POST", esc+"/auto", testSecret, map[string]string{}); code != 400 {
		t.Fatalf("auto without body: %d", code)
	}
	if code, _ := c.do("POST", "/groups/nope/auto", testSecret, map[string]bool{"auto": true}); code != 404 {
		t.Fatalf("unknown group: %d", code)
	}

	code, body = c.do("GET", "/status", testSecret, nil)
	var status StatusResponse
	if err := json.Unmarshal(body, &status); err != nil || code != 200 || len(status.Groups) != 2 || status.Groups[1].Selector != sel {
		t.Fatalf("status %d %s", code, body)
	}

	code, body = c.do("POST", "/stop", testSecret, nil)
	if code != 200 || !strings.Contains(string(body), `"ok":true`) {
		t.Fatalf("stop %d %s", code, body)
	}
	deadline := time.Now().Add(time.Second)
	for stopped.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if stopped.Load() != 1 {
		t.Fatal("stop hook not called")
	}
}

func TestStopNotRegisteredWithoutHook(t *testing.T) {
	f := newFakeClash(t, testSecret)
	e, _ := newTestEngine(t, f, nil, Options{})
	srv := httptest.NewServer(e.Handler())
	defer srv.Close()
	c := apiClient{t, srv.URL}
	if code, _ := c.do("POST", "/stop", testSecret, nil); code != http.StatusNotFound {
		t.Fatalf("stop without hook: %d", code)
	}
	code, body := c.do("GET", "/status", testSecret, nil)
	if code != 200 || strings.TrimSpace(string(body)) != `{"groups":[]}` {
		t.Fatalf("empty status: %d %s", code, body)
	}
}

func TestClashClientSendsSecretAndEscapes(t *testing.T) {
	f := newFakeClash(t, testSecret)
	f.now["a/b 🇩🇪"] = "x"
	c := NewClashClient(f.addr(), testSecret)
	now, err := c.Now(context.Background(), "a/b 🇩🇪")
	if err != nil || now != "x" {
		t.Fatalf("now=%q err=%v", now, err)
	}
	bad := NewClashClient(f.addr(), "nope")
	var apiErr *APIError
	if _, err := bad.Now(context.Background(), "a/b 🇩🇪"); !errors.As(err, &apiErr) || apiErr.Status != 401 {
		t.Fatalf("expected 401, got %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := c.WaitReady(ctx, 10*time.Millisecond); err != nil {
		t.Fatal(err)
	}
}
