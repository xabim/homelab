// Package downpage is a Traefik middleware plugin that answers every request
// with a fixed HTML page and never calls the next handler. It backs the
// lowest-priority fallback router, so a stopped service shows a friendly page
// instead of Traefik's bare "404 page not found".
package downpage

import (
	"context"
	"html"
	"net/http"
	"strings"
)

// Config is the middleware configuration. %HOST% in Body is replaced with
// the (escaped) requested host.
type Config struct {
	Body   string `json:"body,omitempty"`
	Status int    `json:"status,omitempty"`
}

// CreateConfig returns the default configuration.
func CreateConfig() *Config {
	return &Config{Status: http.StatusServiceUnavailable}
}

// DownPage serves the configured page.
type DownPage struct {
	body   string
	status int
}

// New creates the middleware. next is deliberately unused.
func New(_ context.Context, _ http.Handler, cfg *Config, _ string) (http.Handler, error) {
	return &DownPage{body: cfg.Body, status: cfg.Status}, nil
}

func (d *DownPage) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	host := req.Host
	if i := strings.LastIndex(host, ":"); i > 0 && !strings.Contains(host[i:], "]") {
		host = host[:i]
	}
	body := strings.ReplaceAll(d.body, "%HOST%", html.EscapeString(host))
	rw.Header().Set("Content-Type", "text/html; charset=utf-8")
	rw.Header().Set("Cache-Control", "no-store")
	rw.WriteHeader(d.status)
	_, _ = rw.Write([]byte(body))
}
