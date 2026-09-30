package engine

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/zondaxxx/melsi/core/version"
)

// Handler returns the control API (CONTRACT §3).
func (e *Engine) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", e.handleHealth)
	mux.HandleFunc("GET /status", e.handleStatus)
	mux.HandleFunc("POST /groups/{selector}/auto", e.groupHandler(e.handleAuto))
	mux.HandleFunc("POST /groups/{selector}/mode", e.groupHandler(e.handleMode))
	mux.HandleFunc("POST /groups/{selector}/probe", e.groupHandler(e.handleProbe))
	mux.HandleFunc("POST /groups/{selector}/select", e.groupHandler(e.handleSelect))
	if e.onStop != nil {
		mux.HandleFunc("POST /stop", e.handleStop)
	}
	return e.auth(mux)
}

func (e *Engine) auth(next http.Handler) http.Handler {
	want := []byte("Bearer " + e.cfg.Secret)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if e.cfg.Secret != "" {
			got := []byte(r.Header.Get("Authorization"))
			if subtle.ConstantTimeCompare(got, want) != 1 {
				writeError(w, http.StatusUnauthorized, "unauthorized")
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func decodeBody(r *http.Request, v any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<16))
	if err := dec.Decode(v); err != nil {
		return errors.New("invalid JSON body: " + err.Error())
	}
	return nil
}

func (e *Engine) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":         true,
		"version":    version.Melsi,
		"sing_box":   version.SingBox(),
		"uptime_sec": int64(e.Uptime().Seconds()),
	})
}

// StatusResponse is the body of GET /status.
type StatusResponse struct {
	Groups []GroupStatus `json:"groups"`
}

func (e *Engine) handleStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, StatusResponse{Groups: e.Status()})
}

func (e *Engine) groupHandler(h func(http.ResponseWriter, *http.Request, *Group)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("selector")
		g, ok := e.Group(name)
		if !ok {
			writeError(w, http.StatusNotFound, "unknown group "+name)
			return
		}
		h(w, r, g)
	}
}

func (e *Engine) handleAuto(w http.ResponseWriter, r *http.Request, g *Group) {
	var body struct {
		Auto *bool `json:"auto"`
	}
	if err := decodeBody(r, &body); err != nil || body.Auto == nil {
		writeError(w, http.StatusBadRequest, `expected {"auto":bool}`)
		return
	}
	ctx, cancel := e.runCtx(r.Context())
	defer cancel()
	g.SetAuto(ctx, *body.Auto)
	writeJSON(w, http.StatusOK, g.Status())
}

func (e *Engine) handleMode(w http.ResponseWriter, r *http.Request, g *Group) {
	var body struct {
		Mode string `json:"mode"`
	}
	if err := decodeBody(r, &body); err != nil || strings.TrimSpace(body.Mode) == "" {
		writeError(w, http.StatusBadRequest, `expected {"mode":"latency|balanced|stability|game"}`)
		return
	}
	mode, err := ParseMode(body.Mode)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	ctx, cancel := e.runCtx(r.Context())
	defer cancel()
	g.SetMode(ctx, mode)
	writeJSON(w, http.StatusOK, g.Status())
}

func (e *Engine) handleProbe(w http.ResponseWriter, r *http.Request, g *Group) {
	ctx, cancel := e.runCtx(r.Context())
	defer cancel()
	g.Probe(ctx)
	writeJSON(w, http.StatusOK, g.Status())
}

func (e *Engine) handleSelect(w http.ResponseWriter, r *http.Request, g *Group) {
	var body struct {
		Tag string `json:"tag"`
	}
	if err := decodeBody(r, &body); err != nil || body.Tag == "" {
		writeError(w, http.StatusBadRequest, `expected {"tag":"..."}`)
		return
	}
	ctx, cancel := e.runCtx(r.Context())
	defer cancel()
	if err := g.Select(ctx, body.Tag); err != nil {
		status := http.StatusBadGateway
		var apiErr *APIError
		if errors.As(err, &apiErr) && apiErr.Status >= 400 && apiErr.Status < 500 {
			status = http.StatusBadRequest
		}
		writeError(w, status, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, g.Status())
}

func (e *Engine) handleStop(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
	go e.onStop()
}
