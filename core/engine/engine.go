// Package engine implements Melsi's Smart Auto-Select and Game Booster.
//
// It drives sing-box selector outbounds exclusively through the Clash API,
// so the same code runs in the desktop daemon and in the mobile tunnel.
package engine

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Options customizes an Engine. The zero value is valid.
type Options struct {
	// Logger receives engine logs; nil discards them.
	Logger *slog.Logger
	// OnStop, if set, enables POST /stop and is called (asynchronously)
	// after the response is written.
	OnStop func()
	// ProbeConcurrency bounds active node probes across all groups. Zero uses 8.
	ProbeConcurrency int
}

// Engine owns all groups and the control API server.
type Engine struct {
	cfg    *Config
	clash  *ClashClient
	log    *slog.Logger
	onStop func()

	groups  []*Group
	byName  map[string]*Group
	started time.Time

	// Tunables; overridden in tests.
	now           func() time.Time
	sampleSpacing time.Duration
	retryDelay    time.Duration
	failoverEvery time.Duration

	mu       sync.Mutex
	ctx      context.Context
	cancel   context.CancelFunc
	wg       sync.WaitGroup
	server   *http.Server
	listener net.Listener

	// Pausing cancels probe work while preserving selector state and the API.
	paused      bool
	workCtx     context.Context
	workCancel  context.CancelFunc
	workChanged chan struct{}
	probeSlots  chan struct{}
}

// New builds an engine; call Start to run it.
func New(cfg *Config, opts Options) (*Engine, error) {
	if cfg == nil {
		return nil, errors.New("nil config")
	}
	if err := cfg.normalize(); err != nil {
		return nil, err
	}
	logger := opts.Logger
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	concurrency := opts.ProbeConcurrency
	if concurrency <= 0 {
		concurrency = 8
	}
	e := &Engine{
		cfg:           cfg,
		clash:         NewClashClient(cfg.ClashAPI, cfg.Secret),
		log:           logger,
		onStop:        opts.OnStop,
		byName:        make(map[string]*Group),
		now:           time.Now,
		sampleSpacing: 250 * time.Millisecond,
		retryDelay:    time.Second,
		failoverEvery: 5 * time.Second,
		workChanged:   make(chan struct{}),
		probeSlots:    make(chan struct{}, concurrency),
	}
	for _, gc := range cfg.Groups {
		g := newGroup(e, gc)
		e.groups = append(e.groups, g)
		e.byName[gc.Selector] = g
	}
	return e, nil
}

// NewLogger returns a text logger writing to w at the given level name.
func NewLogger(w io.Writer, level string) *slog.Logger {
	var lv slog.Level
	switch strings.ToLower(level) {
	case "trace", "debug":
		lv = slog.LevelDebug
	case "warn", "warning":
		lv = slog.LevelWarn
	case "error", "fatal", "panic":
		lv = slog.LevelError
	default:
		lv = slog.LevelInfo
	}
	return slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{Level: lv})).With("component", "engine")
}

// Start launches the probe loops and, if configured, the control API.
// It returns once the control listener is bound.
func (e *Engine) Start() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.ctx != nil {
		return errors.New("engine already started")
	}
	if e.cfg.ControlListen != "" {
		ln, err := net.Listen("tcp", e.cfg.ControlListen)
		if err != nil {
			return err
		}
		e.listener = ln
		e.server = &http.Server{Handler: e.Handler(), ReadHeaderTimeout: 10 * time.Second}
	}
	e.started = e.now()
	e.ctx, e.cancel = context.WithCancel(context.Background())
	if !e.paused {
		e.workCtx, e.workCancel = context.WithCancel(e.ctx)
	}
	for _, g := range e.groups {
		e.wg.Add(1)
		go func() {
			defer e.wg.Done()
			g.run(e.ctx)
		}()
	}
	if e.server != nil {
		e.wg.Add(1)
		go func() {
			defer e.wg.Done()
			if err := e.server.Serve(e.listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
				e.log.Error("control api", "err", err)
			}
		}()
		e.log.Info("control api listening", "addr", e.listener.Addr().String())
	}
	e.log.Info("engine started", "groups", len(e.groups))
	return nil
}

// Pause suspends probing without closing the tunnel or losing latency history.
// Existing probes are cancelled so sleep cannot be counted as a failed server.
func (e *Engine) Pause() {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.paused || (e.ctx != nil && e.cancel == nil) {
		return
	}
	e.paused = true
	if e.workCancel != nil {
		e.workCancel()
	}
	close(e.workChanged)
	e.workChanged = make(chan struct{})
}

// Resume restarts probe work immediately after a transient device sleep.
func (e *Engine) Resume() {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.paused || (e.ctx != nil && e.cancel == nil) {
		return
	}
	e.paused = false
	if e.cancel != nil {
		e.workCtx, e.workCancel = context.WithCancel(e.ctx)
	}
	close(e.workChanged)
	e.workChanged = make(chan struct{})
}

func (e *Engine) waitWork(ctx context.Context) context.Context {
	for {
		if ctx.Err() != nil {
			return nil
		}
		e.mu.Lock()
		work, changed, paused := e.workCtx, e.workChanged, e.paused
		e.mu.Unlock()
		if !paused && work != nil {
			return work
		}
		select {
		case <-ctx.Done():
			return nil
		case <-changed:
		}
	}
}

// Addr returns the control API address, or "" when not listening.
func (e *Engine) Addr() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.listener == nil {
		return ""
	}
	return e.listener.Addr().String()
}

// Close stops all loops and the control API and waits for them to exit.
func (e *Engine) Close() error {
	e.mu.Lock()
	if e.ctx == nil || e.cancel == nil {
		e.mu.Unlock()
		return nil
	}
	cancel, server := e.cancel, e.server
	e.cancel = nil
	e.mu.Unlock()

	cancel()
	if server != nil {
		sctx, done := context.WithTimeout(context.Background(), 3*time.Second)
		if err := server.Shutdown(sctx); err != nil {
			server.Close()
		}
		done()
	}
	e.wg.Wait()
	e.clash.Close()
	e.log.Info("engine stopped")
	return nil
}

// Status returns every group's status in config order.
func (e *Engine) Status() []GroupStatus {
	out := make([]GroupStatus, 0, len(e.groups))
	for _, g := range e.groups {
		out = append(out, g.Status())
	}
	return out
}

// Group looks up a group by selector tag.
func (e *Engine) Group(selector string) (*Group, bool) {
	g, ok := e.byName[selector]
	return g, ok
}

// Uptime is the time since Start.
func (e *Engine) Uptime() time.Duration {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.started.IsZero() {
		return 0
	}
	return e.now().Sub(e.started)
}

// runCtx is cancelled when the request ends, the engine pauses, or it stops.
func (e *Engine) runCtx(parent context.Context) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(parent)
	e.mu.Lock()
	ectx, paused := e.workCtx, e.paused
	e.mu.Unlock()
	if paused || (ectx != nil && ectx.Err() != nil) {
		cancel()
		return ctx, cancel
	}
	if ectx == nil {
		return ctx, cancel
	}
	stop := context.AfterFunc(ectx, cancel)
	return ctx, func() { stop(); cancel() }
}
