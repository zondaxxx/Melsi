package engine

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// ClashClient talks to sing-box's Clash-compatible REST API.
type ClashClient struct {
	base   string
	secret string
	http   *http.Client
}

// NewClashClient creates a client for addr ("host:port" or a full URL).
func NewClashClient(addr, secret string) *ClashClient {
	base := addr
	if !strings.Contains(base, "://") {
		base = "http://" + base
	}
	return &ClashClient{
		base:   strings.TrimRight(base, "/"),
		secret: secret,
		// Loopback only; never route through a system proxy.
		http: &http.Client{Transport: &http.Transport{
			Proxy:               nil,
			MaxIdleConnsPerHost: 16,
			IdleConnTimeout:     30 * time.Second,
		}},
	}
}

// APIError is a non-2xx answer from the Clash API.
type APIError struct {
	Status  int
	Message string
}

func (e *APIError) Error() string {
	if e.Message != "" {
		return fmt.Sprintf("clash api %d: %s", e.Status, e.Message)
	}
	return fmt.Sprintf("clash api %d", e.Status)
}

func (c *ClashClient) do(ctx context.Context, method, path string, body any, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, rd)
	if err != nil {
		return err
	}
	if c.secret != "" {
		req.Header.Set("Authorization", "Bearer "+c.secret)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		var msg struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(data, &msg)
		return &APIError{Status: resp.StatusCode, Message: msg.Message}
	}
	if out != nil && len(data) > 0 {
		return json.Unmarshal(data, out)
	}
	return nil
}

func proxyPath(name string) string { return "/proxies/" + url.PathEscape(name) }

// Ping checks that the API answers an authenticated request.
func (c *ClashClient) Ping(ctx context.Context) error {
	return c.do(ctx, http.MethodGet, "/", nil, nil)
}

// Delay runs a URL test through outbound tag and returns the delay in ms.
func (c *ClashClient) Delay(ctx context.Context, tag, probeURL string, timeoutMs int) (int, error) {
	q := url.Values{}
	q.Set("url", probeURL)
	q.Set("timeout", strconv.Itoa(timeoutMs))
	// Give the HTTP round trip a little slack beyond the probe timeout.
	ctx, cancel := context.WithTimeout(ctx, time.Duration(timeoutMs)*time.Millisecond+2*time.Second)
	defer cancel()
	var out struct {
		Delay int `json:"delay"`
	}
	if err := c.do(ctx, http.MethodGet, proxyPath(tag)+"/delay?"+q.Encode(), nil, &out); err != nil {
		return 0, err
	}
	if out.Delay <= 0 {
		return 0, fmt.Errorf("invalid delay %d", out.Delay)
	}
	return out.Delay, nil
}

// Now returns the currently selected member of a selector group.
func (c *ClashClient) Now(ctx context.Context, selector string) (string, error) {
	var out struct {
		Now string `json:"now"`
	}
	if err := c.do(ctx, http.MethodGet, proxyPath(selector), nil, &out); err != nil {
		return "", err
	}
	return out.Now, nil
}

// Select switches a selector group to tag.
func (c *ClashClient) Select(ctx context.Context, selector, tag string) error {
	return c.do(ctx, http.MethodPut, proxyPath(selector), map[string]string{"name": tag}, nil)
}

// WaitReady polls the API until it answers or ctx ends.
func (c *ClashClient) WaitReady(ctx context.Context, every time.Duration) error {
	for {
		pctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		err := c.Ping(pctx)
		cancel()
		if err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("clash api not ready: %w", err)
		case <-time.After(every):
		}
	}
}

// Close releases idle connections.
func (c *ClashClient) Close() { c.http.CloseIdleConnections() }
