package engine

import (
	"encoding/json"
	"fmt"
	"strings"
)

// Mode selects the scoring formula used to rank candidates.
type Mode string

const (
	ModeLatency   Mode = "latency"
	ModeBalanced  Mode = "balanced"
	ModeStability Mode = "stability"
	ModeGame      Mode = "game"
)

// ParseMode validates a mode string.
func ParseMode(s string) (Mode, error) {
	switch m := Mode(strings.ToLower(strings.TrimSpace(s))); m {
	case ModeLatency, ModeBalanced, ModeStability, ModeGame:
		return m, nil
	case "":
		return ModeBalanced, nil
	default:
		return "", fmt.Errorf("unknown mode %q", s)
	}
}

// Config is the engine configuration produced by the app (CONTRACT §2).
type Config struct {
	ClashAPI      string        `json:"clash_api"`
	Secret        string        `json:"secret"`
	ControlListen string        `json:"control_listen"`
	LogLevel      string        `json:"log_level"`
	Groups        []GroupConfig `json:"groups"`
}

// GroupConfig describes one selector the engine drives.
type GroupConfig struct {
	Selector    string      `json:"selector"`
	Auto        bool        `json:"auto"`
	Mode        Mode        `json:"mode"`
	ProbeURL    string      `json:"probe_url"`
	IntervalSec int         `json:"interval_sec"`
	TimeoutMs   int         `json:"timeout_ms"`
	Candidates  []Candidate `json:"candidates"`
}

// Candidate is one outbound tag of a selector.
type Candidate struct {
	Tag       string `json:"tag"`
	Type      string `json:"type"`
	UDPNative bool   `json:"udp_native"`
}

const (
	DefaultClashAPI      = "127.0.0.1:9790"
	DefaultControlListen = "127.0.0.1:9791"
	DefaultProbeURL      = "https://www.gstatic.com/generate_204"
	defaultIntervalSec   = 60
	defaultTimeoutMs     = 3000
	minIntervalSec       = 5
	// The Clash API parses timeout as int16 milliseconds.
	maxTimeoutMs = 32000
)

// ParseConfig decodes engine JSON and fills defaults.
func ParseConfig(data []byte) (*Config, error) {
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("decode engine config: %w", err)
	}
	if err := cfg.normalize(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func (c *Config) normalize() error {
	if c.ClashAPI == "" {
		c.ClashAPI = DefaultClashAPI
	}
	if c.LogLevel == "" {
		c.LogLevel = "info"
	}
	seen := make(map[string]bool)
	for i := range c.Groups {
		g := &c.Groups[i]
		if g.Selector == "" {
			return fmt.Errorf("group %d: empty selector", i)
		}
		if seen[g.Selector] {
			return fmt.Errorf("duplicate group %q", g.Selector)
		}
		seen[g.Selector] = true
		mode, err := ParseMode(string(g.Mode))
		if err != nil {
			return fmt.Errorf("group %q: %w", g.Selector, err)
		}
		g.Mode = mode
		if g.ProbeURL == "" {
			g.ProbeURL = DefaultProbeURL
		}
		if g.IntervalSec <= 0 {
			g.IntervalSec = defaultIntervalSec
		} else if g.IntervalSec < minIntervalSec {
			g.IntervalSec = minIntervalSec
		}
		if g.TimeoutMs <= 0 {
			g.TimeoutMs = defaultTimeoutMs
		} else if g.TimeoutMs > maxTimeoutMs {
			g.TimeoutMs = maxTimeoutMs
		}
		tags := make(map[string]bool)
		cands := g.Candidates[:0]
		for _, cand := range g.Candidates {
			if cand.Tag == "" || tags[cand.Tag] {
				continue
			}
			tags[cand.Tag] = true
			cands = append(cands, cand)
		}
		g.Candidates = cands
	}
	return nil
}
