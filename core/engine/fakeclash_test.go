package engine

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
)

// fakeClash mimics the subset of sing-box's Clash API the engine uses.
type fakeClash struct {
	t      *testing.T
	srv    *httptest.Server
	secret string

	mu      sync.Mutex
	now     map[string]string // selector -> current
	delay   map[string]int    // tag -> ms; <=0 means failure (503)
	seq     map[string][]int  // tag -> per-call delays, consumed first
	calls   map[string]int    // delay calls per tag
	puts    []string          // "selector=tag"
	unauth  int
	putFail bool
}

func newFakeClash(t *testing.T, secret string) *fakeClash {
	f := &fakeClash{
		t:      t,
		secret: secret,
		now:    map[string]string{},
		delay:  map[string]int{},
		seq:    map[string][]int{},
		calls:  map[string]int{},
	}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeClash) addr() string { return strings.TrimPrefix(f.srv.URL, "http://") }

func (f *fakeClash) setDelay(tag string, ms int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.delay[tag] = ms
}

func (f *fakeClash) setSeq(tag string, ms ...int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.seq[tag] = append([]int(nil), ms...)
}

func (f *fakeClash) current(sel string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now[sel]
}

func (f *fakeClash) putCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.puts)
}

func (f *fakeClash) callCount(tag string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[tag]
}

func (f *fakeClash) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.secret != "" && r.Header.Get("Authorization") != "Bearer "+f.secret {
		f.unauth++
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"message":"Unauthorized"}`))
		return
	}
	if r.URL.Path == "/" {
		_, _ = w.Write([]byte(`{"hello":"clash"}`))
		return
	}
	rest, ok := strings.CutPrefix(r.URL.EscapedPath(), "/proxies/")
	if !ok {
		http.NotFound(w, r)
		return
	}
	isDelay := strings.HasSuffix(rest, "/delay")
	rest = strings.TrimSuffix(rest, "/delay")
	name, err := url.PathUnescape(rest)
	if err != nil {
		http.Error(w, "bad name", http.StatusBadRequest)
		return
	}
	switch {
	case isDelay && r.Method == http.MethodGet:
		if r.URL.Query().Get("timeout") == "" || r.URL.Query().Get("url") == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		f.calls[name]++
		d := f.delay[name]
		if s := f.seq[name]; len(s) > 0 {
			d, f.seq[name] = s[0], s[1:]
		}
		if d <= 0 {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"message":"An error occurred in the delay test"}`))
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]int{"delay": d})
	case r.Method == http.MethodGet:
		now, ok := f.now[name]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"message":"Resource not found"}`))
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"type": "Selector", "name": name, "now": now})
	case r.Method == http.MethodPut:
		var body struct {
			Name string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || f.putFail || body.Name == "missing" {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"message":"Selector update error: not found"}`))
			return
		}
		f.now[name] = body.Name
		f.puts = append(f.puts, name+"="+body.Name)
		w.WriteHeader(http.StatusNoContent)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}
