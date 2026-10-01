package engine

import (
	"math"
)

const (
	ewmaAlpha    = 0.3
	lossWindow   = 20
	deadAfter    = 2 // consecutive failed samples that mark a node dead
	flapPenalty  = 25.0
	gameUDPBonus = 0.15
)

// nodeStats holds rolling probe statistics for one candidate.
// It is not safe for concurrent use; Group guards it.
type nodeStats struct {
	ewma       float64 // ms
	jitter     float64 // ms, EWMA of |Δ| between consecutive successful samples
	lastOK     float64 // last successful sample, ms (0 = none yet)
	window     [lossWindow]bool
	wlen, wpos int
	consecFail int
	samples    int // total samples taken
	successes  int
	lastError  string
}

func (s *nodeStats) add(delayMs int, err error) {
	s.samples++
	ok := err == nil
	s.window[s.wpos] = ok
	s.wpos = (s.wpos + 1) % lossWindow
	if s.wlen < lossWindow {
		s.wlen++
	}
	if !ok {
		s.consecFail++
		s.lastError = err.Error()
		return
	}
	d := float64(delayMs)
	s.consecFail = 0
	s.lastError = ""
	if s.successes == 0 {
		s.ewma = d
	} else {
		s.ewma = ewmaAlpha*d + (1-ewmaAlpha)*s.ewma
		s.jitter = ewmaAlpha*math.Abs(d-s.lastOK) + (1-ewmaAlpha)*s.jitter
	}
	s.lastOK = d
	s.successes++
}

// alive reports whether the node has answered and is not failing now.
func (s *nodeStats) alive() bool { return s.successes > 0 && s.consecFail < deadAfter }

// dead reports whether the node has been probed and is considered down.
// A never-probed node is neither alive nor dead.
func (s *nodeStats) dead() bool { return s.samples > 0 && !s.alive() }

func (s *nodeStats) loss() float64 {
	if s.wlen == 0 {
		return 0
	}
	lost := 0
	for i := 0; i < s.wlen; i++ {
		if !s.window[i] {
			lost++
		}
	}
	return float64(lost) / float64(s.wlen)
}

// flaps counts ok<->fail transitions inside the loss window, oldest first.
func (s *nodeStats) flaps() int {
	if s.wlen < 2 {
		return 0
	}
	start := 0
	if s.wlen == lossWindow {
		start = s.wpos
	}
	n := 0
	prev := s.window[start]
	for i := 1; i < s.wlen; i++ {
		cur := s.window[(start+i)%lossWindow]
		if cur != prev {
			n++
		}
		prev = cur
	}
	return n
}

// score ranks a node for mode; lower is better, +Inf when not usable.
func (s *nodeStats) score(mode Mode, udpNative bool) float64 {
	if !s.alive() {
		return math.Inf(1)
	}
	return scoreOf(mode, udpNative, s.ewma, s.jitter, s.loss(), s.flaps())
}

func scoreOf(mode Mode, udpNative bool, ewma, jitter, loss float64, flaps int) float64 {
	switch mode {
	case ModeLatency:
		return ewma
	case ModeStability:
		return ewma + 3*jitter + 2000*loss + flapPenalty*float64(flaps)
	case ModeGame:
		sc := ewma + 4*jitter + 3000*loss
		if udpNative {
			sc *= 1 - gameUDPBonus
		}
		return sc
	default: // balanced
		return ewma + 2*jitter + 800*loss
	}
}
