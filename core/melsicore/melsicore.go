// Package melsicore is the gomobile-exported bridge to the engine. It is bound
// together with sing-box's libbox, so every exported signature must stay
// gomobile-compatible (strings, error, no structs).
package melsicore

import (
	"encoding/json"
	"os"
	"sync"

	"github.com/zondaxxx/melsi/core/engine"
	"github.com/zondaxxx/melsi/core/version"
)

var (
	mu      sync.Mutex
	current *engine.Engine
	paused  bool
)

// StartEngine starts (or restarts) the singleton engine from engine JSON
// (CONTRACT §2). The control API has no /stop on mobile.
func StartEngine(engineJSON string) error {
	cfg, err := engine.ParseConfig([]byte(engineJSON))
	if err != nil {
		return err
	}
	e, err := engine.New(cfg, engine.Options{
		Logger: engine.NewLogger(os.Stderr, cfg.LogLevel),
		// Network extensions share a tight memory budget with all transports.
		ProbeConcurrency: 2,
	})
	if err != nil {
		return err
	}
	mu.Lock()
	defer mu.Unlock()
	if current != nil {
		_ = current.Close()
		current = nil
	}
	if paused {
		e.Pause()
	}
	if err := e.Start(); err != nil {
		return err
	}
	current = e
	return nil
}

// StopEngine stops the engine; safe to call when not running.
func StopEngine() {
	mu.Lock()
	e := current
	current = nil
	mu.Unlock()
	if e != nil {
		_ = e.Close()
	}
}

// PauseEngine suspends probes during device sleep while keeping the VPN alive.
func PauseEngine() {
	mu.Lock()
	defer mu.Unlock()
	paused = true
	if current != nil {
		current.Pause()
	}
}

// ResumeEngine resumes probing after wake; safe when the engine is stopped.
func ResumeEngine() {
	mu.Lock()
	defer mu.Unlock()
	paused = false
	if current != nil {
		current.Resume()
	}
}

// EngineStatus returns the same JSON as GET /status ({"groups":[]} when stopped).
func EngineStatus() string {
	mu.Lock()
	e := current
	mu.Unlock()
	resp := engine.StatusResponse{Groups: []engine.GroupStatus{}}
	if e != nil {
		resp.Groups = e.Status()
	}
	data, err := json.Marshal(resp)
	if err != nil {
		return `{"groups":[]}`
	}
	return string(data)
}

// Version returns the Melsi core version.
func Version() string { return version.Melsi }
