package engine

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"sync"
	"time"
)

const (
	samplesPerRound  = 3
	maxConcurrency   = 8
	switchRatio      = 0.8 // best must be >20% better
	switchMinDeltaMs = 10.0
)

// SwitchEvent records the most recent selector change.
type SwitchEvent struct {
	From   string `json:"from"`
	To     string `json:"to"`
	Reason string `json:"reason"`
	At     string `json:"at"` // RFC3339
}

// NodeStatus is the per-candidate part of GroupStatus.
type NodeStatus struct {
	Tag       string  `json:"tag"`
	LatencyMs int     `json:"latency_ms"`
	JitterMs  int     `json:"jitter_ms"`
	Loss      float64 `json:"loss"`
	Score     float64 `json:"score"` // -1 when the node is not alive
	Alive     bool    `json:"alive"`
	Samples   int     `json:"samples"`
	LastError string  `json:"last_error"`
}

// GroupStatus is the JSON shape of one group (CONTRACT §3).
type GroupStatus struct {
	Selector   string       `json:"selector"`
	Auto       bool         `json:"auto"`
	Mode       Mode         `json:"mode"`
	Current    string       `json:"current"`
	LastSwitch *SwitchEvent `json:"last_switch"`
	Nodes      []NodeStatus `json:"nodes"`
}

// Group drives one sing-box selector.
type Group struct {
	e        *Engine
	log      *slog.Logger
	selector string
	probeURL string
	interval time.Duration
	timeout  int
	cands    []Candidate

	probeMu  sync.Mutex // serializes probe rounds
	selectMu sync.Mutex // serializes decide+PUT so manual and auto picks cannot interleave

	mu           sync.Mutex
	auto         bool
	mode         Mode
	current      string
	stats        map[string]*nodeStats
	lastSwitch   *SwitchEvent
	lastSwitchAt time.Time
}

func newGroup(e *Engine, cfg GroupConfig) *Group {
	g := &Group{
		e:        e,
		log:      e.log.With("group", cfg.Selector),
		selector: cfg.Selector,
		probeURL: cfg.ProbeURL,
		interval: time.Duration(cfg.IntervalSec) * time.Second,
		timeout:  cfg.TimeoutMs,
		cands:    cfg.Candidates,
		auto:     cfg.Auto,
		mode:     cfg.Mode,
		stats:    make(map[string]*nodeStats, len(cfg.Candidates)),
	}
	for _, c := range cfg.Candidates {
		g.stats[c.Tag] = &nodeStats{}
	}
	return g
}

func (g *Group) run(ctx context.Context) {
	g.initCurrent(ctx)
	timer := time.NewTimer(0)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		g.probeAndEvaluate(ctx)
		wait := g.interval
		if g.inFailover() {
			wait = min(wait, g.e.failoverEvery)
		}
		timer.Reset(wait)
	}
}

// initCurrent reads the selector's current member, retrying briefly while
// sing-box finishes starting.
func (g *Group) initCurrent(ctx context.Context) {
	for attempt := 0; attempt < 10; attempt++ {
		now, err := g.e.clash.Now(ctx, g.selector)
		if err == nil {
			g.mu.Lock()
			g.current = now
			g.mu.Unlock()
			g.log.Info("selector attached", "current", now)
			return
		}
		g.log.Warn("read selector", "err", err)
		select {
		case <-ctx.Done():
			return
		case <-time.After(g.e.retryDelay):
		}
	}
}

func (g *Group) probeAndEvaluate(ctx context.Context) {
	g.probe(ctx)
	if ctx.Err() == nil {
		g.evaluate(ctx)
	}
}

// probe runs one round: samplesPerRound samples per candidate with bounded
// concurrency across candidates.
func (g *Group) probe(ctx context.Context) {
	g.probeMu.Lock()
	defer g.probeMu.Unlock()
	sem := make(chan struct{}, maxConcurrency)
	var wg sync.WaitGroup
	for _, c := range g.cands {
		wg.Add(1)
		go func(tag string) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				return
			}
			defer func() { <-sem }()
			g.probeNode(ctx, tag)
		}(c.Tag)
	}
	wg.Wait()
}

func (g *Group) probeNode(ctx context.Context, tag string) {
	failsInRound := 0
	for i := 0; i < samplesPerRound; i++ {
		if i > 0 {
			select {
			case <-ctx.Done():
				return
			case <-time.After(g.e.sampleSpacing):
			}
		}
		d, err := g.e.clash.Delay(ctx, tag, g.probeURL, g.timeout)
		if ctx.Err() != nil {
			return // shutting down; don't count as loss
		}
		g.mu.Lock()
		g.stats[tag].add(d, err)
		g.mu.Unlock()
		if err != nil {
			failsInRound++
			// Already dead for this round; don't burn more timeouts on it.
			if failsInRound >= deadAfter {
				return
			}
		}
	}
}

// inFailover reports whether the current node is down (or everything is),
// which switches the loop to fast re-probing.
func (g *Group) inFailover() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if st, ok := g.stats[g.current]; ok && st.dead() {
		return true
	}
	for _, st := range g.stats {
		if !st.dead() {
			return false
		}
	}
	return len(g.stats) > 0
}

// evaluate applies the auto-select policy and switches the selector if needed.
func (g *Group) evaluate(ctx context.Context) {
	g.selectMu.Lock()
	defer g.selectMu.Unlock()
	g.mu.Lock()
	from := g.current
	to, reason := g.decideLocked(g.e.now())
	g.mu.Unlock()
	if to == "" {
		return
	}
	if err := g.e.clash.Select(ctx, g.selector, to); err != nil {
		g.log.Warn("switch failed", "to", to, "err", err)
		return
	}
	g.mu.Lock()
	g.recordSwitchLocked(from, to, reason)
	g.mu.Unlock()
	g.log.Info("switched", "from", from, "to", to, "reason", reason)
}

func (g *Group) recordSwitchLocked(from, to, reason string) {
	now := g.e.now()
	g.current = to
	g.lastSwitchAt = now
	g.lastSwitch = &SwitchEvent{From: from, To: to, Reason: reason, At: now.UTC().Format(time.RFC3339)}
}

func (g *Group) minDwell() time.Duration {
	switch g.mode {
	case ModeStability, ModeGame:
		return 120 * time.Second
	default:
		return 30 * time.Second
	}
}

// decideLocked returns the tag to switch to (empty for none) and a
// human-readable reason.
func (g *Group) decideLocked(now time.Time) (string, string) {
	if !g.auto {
		return "", ""
	}
	best, bestScore := "", math.Inf(1)
	var bestCand Candidate
	for _, c := range g.cands {
		if sc := g.stats[c.Tag].score(g.mode, c.UDPNative); sc < bestScore {
			best, bestScore, bestCand = c.Tag, sc, c
		}
	}
	if best == "" || best == g.current {
		return "", ""
	}
	cur, isCand := g.stats[g.current]
	switch {
	case !isCand:
		return best, "initial pick"
	case cur.dead():
		return best, fmt.Sprintf("failover: %s unreachable", g.current)
	case !cur.alive():
		return "", "" // current not probed yet
	}
	if !g.lastSwitchAt.IsZero() && now.Sub(g.lastSwitchAt) < g.minDwell() {
		return "", ""
	}
	curCand := g.candidate(g.current)
	curScore := cur.score(g.mode, curCand.UDPNative)
	if bestScore < curScore*switchRatio && curScore-bestScore > switchMinDeltaMs {
		return best, g.explain(cur, g.stats[best], curCand, bestCand)
	}
	return "", ""
}

func (g *Group) candidate(tag string) Candidate {
	for _, c := range g.cands {
		if c.Tag == tag {
			return c
		}
	}
	return Candidate{Tag: tag}
}

// explain names the score component that contributed most to the switch.
func (g *Group) explain(cur, best *nodeStats, curC, bestC Candidate) string {
	type part struct {
		gain float64
		text string
	}
	ms := func(v float64) int { return int(math.Round(v)) }
	pct := func(v float64) int { return int(math.Round(v * 100)) }
	parts := []part{{cur.ewma - best.ewma, fmt.Sprintf("latency %dms vs %dms", ms(best.ewma), ms(cur.ewma))}}
	jw, lw := 0.0, 0.0
	switch g.mode {
	case ModeBalanced:
		jw, lw = 2, 800
	case ModeStability:
		jw, lw = 3, 2000
		parts = append(parts, part{flapPenalty * float64(cur.flaps()-best.flaps()),
			fmt.Sprintf("flaps %d vs %d", best.flaps(), cur.flaps())})
	case ModeGame:
		jw, lw = 4, 3000
		if bestC.UDPNative && !curC.UDPNative {
			bonus := gameUDPBonus * scoreOf(ModeGame, false, best.ewma, best.jitter, best.loss(), 0)
			parts = append(parts, part{bonus, "UDP-native " + bestC.Type})
		}
	}
	if jw > 0 {
		parts = append(parts,
			part{jw * (cur.jitter - best.jitter), fmt.Sprintf("jitter %dms vs %dms", ms(best.jitter), ms(cur.jitter))},
			part{lw * (cur.loss() - best.loss()), fmt.Sprintf("loss %d%% vs %d%%", pct(best.loss()), pct(cur.loss()))},
		)
	}
	top := parts[0]
	for _, p := range parts[1:] {
		if p.gain > top.gain {
			top = p
		}
	}
	return top.text
}

// Status returns a snapshot of the group.
func (g *Group) Status() GroupStatus {
	g.mu.Lock()
	defer g.mu.Unlock()
	st := GroupStatus{
		Selector: g.selector,
		Auto:     g.auto,
		Mode:     g.mode,
		Current:  g.current,
		Nodes:    make([]NodeStatus, 0, len(g.cands)),
	}
	if g.lastSwitch != nil {
		ls := *g.lastSwitch
		st.LastSwitch = &ls
	}
	for _, c := range g.cands {
		s := g.stats[c.Tag]
		n := NodeStatus{
			Tag:       c.Tag,
			LatencyMs: int(math.Round(s.ewma)),
			JitterMs:  int(math.Round(s.jitter)),
			Loss:      math.Round(s.loss()*1000) / 1000,
			Score:     -1,
			Alive:     s.alive(),
			Samples:   s.samples,
			LastError: s.lastError,
		}
		if sc := s.score(g.mode, c.UDPNative); !math.IsInf(sc, 1) {
			n.Score = math.Round(sc*10) / 10
		}
		st.Nodes = append(st.Nodes, n)
	}
	return st
}

// SetAuto toggles automatic switching and re-evaluates immediately when on.
func (g *Group) SetAuto(ctx context.Context, auto bool) {
	g.mu.Lock()
	g.auto = auto
	g.mu.Unlock()
	if auto {
		g.evaluate(ctx)
	}
}

// SetMode changes the scoring mode and re-evaluates.
func (g *Group) SetMode(ctx context.Context, mode Mode) {
	g.mu.Lock()
	g.mode = mode
	g.mu.Unlock()
	g.evaluate(ctx)
}

// Probe forces a probe round now and applies the policy.
func (g *Group) Probe(ctx context.Context) { g.probeAndEvaluate(ctx) }

// Select manually selects tag and disables auto-select.
func (g *Group) Select(ctx context.Context, tag string) error {
	g.selectMu.Lock()
	defer g.selectMu.Unlock()
	if err := g.e.clash.Select(ctx, g.selector, tag); err != nil {
		return err
	}
	g.mu.Lock()
	from := g.current
	g.auto = false
	if from != tag {
		g.recordSwitchLocked(from, tag, "manual")
	}
	g.mu.Unlock()
	g.log.Info("manual select", "tag", tag)
	return nil
}
