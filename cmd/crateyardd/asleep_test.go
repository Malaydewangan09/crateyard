package main

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

func TestIsPing(t *testing.T) {
	cases := map[string]bool{
		"GET /_ping HTTP/1.1":              true,
		"HEAD /_ping HTTP/1.1":             true,
		"GET /v1.47/_ping HTTP/1.1":        true,
		"GET /_ping?x=1 HTTP/1.1":          true,
		"POST /_ping HTTP/1.1":             false,
		"GET /containers/json HTTP/1.1":    false,
		"GET /v1.47/images/_ping HTTP/1.1": false,
		"GET /vfoo HTTP/1.1":               false,
		"GET /volumes/_ping HTTP/1.1":      false,
	}
	for line, want := range cases {
		if got := isPing(line); got != want {
			t.Errorf("isPing(%q) = %v, want %v", line, got, want)
		}
	}
}

// A client that pings and then asks for real work on the same keep-alive connection gets its pings answered
// and the real request handed back byte for byte, so it can be forwarded once the VM wakes.
func TestFirstRequestAnswersPingsAndHandsBackTheFirstRealRequest(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	// net.Pipe has no buffering, so a bug that stops answering would hang the test without this.
	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	saved := http.Header{"Api-Version": {"1.47"}, "Date": {"stale"}}
	type result struct {
		pending []byte
		line    string
		err     error
	}
	done := make(chan result, 1)
	go func() {
		p, l, err := firstRequest(server, func() bool { return true }, func() http.Header { return saved })
		done <- result{p, l, err}
	}()

	const real = "GET /v1.47/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n"
	go func() {
		_, _ = io.WriteString(client, "HEAD /_ping HTTP/1.1\r\nHost: docker\r\n\r\n")
		_, _ = io.WriteString(client, "GET /_ping HTTP/1.1\r\nHost: docker\r\n\r\n")
		_, _ = io.WriteString(client, real)
	}()
	br := bufio.NewReader(client)
	for _, method := range []string{http.MethodHead, http.MethodGet} {
		resp, err := http.ReadResponse(br, &http.Request{Method: method})
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != 200 || resp.Header.Get("Api-Version") != "1.47" || resp.Header.Get("Date") != "" {
			t.Fatalf("%s ping: status %d, headers %v", method, resp.StatusCode, resp.Header)
		}
		if want := map[string]string{"HEAD": "", "GET": "OK"}[method]; string(body) != want {
			t.Fatalf("%s ping body %q, want %q", method, body, want)
		}
	}
	r := <-done
	if r.err != nil {
		t.Fatal(r.err)
	}
	if string(r.pending) != real || r.line != "GET /v1.47/containers/json HTTP/1.1" {
		t.Fatalf("handed back %q (line %q), want the containers request", r.pending, r.line)
	}
}

func TestIsEventStream(t *testing.T) {
	if !isEventStream("GET /v1.51/events?filters=%7B%7D HTTP/1.1") || !isEventStream("GET /events HTTP/1.1") {
		t.Fatal("did not recognise an event subscription")
	}
	if isEventStream("GET /v1.51/containers/json HTTP/1.1") || isEventStream("POST /events HTTP/1.1") {
		t.Fatal("treated a normal request as an event subscription")
	}
}
