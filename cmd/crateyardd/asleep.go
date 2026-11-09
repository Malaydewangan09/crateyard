package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

const maxRequestHead = 64 << 10

// errHeadTooLarge means a client sent more than maxRequestHead bytes without finishing its request headers.
var errHeadTooLarge = errors.New("request headers are larger than 64 KB")

// readHead returns the first request's line and its full header length, reading more from br until the blank line arrives.
func readHead(br *bufio.Reader) (line string, size int, err error) {
	for {
		buf, peekErr := br.Peek(br.Buffered())
		if end := bytes.Index(buf, []byte("\r\n\r\n")); end >= 0 {
			line, _, _ = strings.Cut(string(buf[:end]), "\r\n")
			return line, end + 4, nil
		}
		if peekErr != nil {
			return "", 0, peekErr
		}
		if br.Buffered() >= maxRequestHead {
			return "", 0, errHeadTooLarge
		}
		if _, err := br.Peek(br.Buffered() + 1); err != nil {
			return "", 0, err
		}
	}
}

// endpoint returns a request line's method and its API path without the /vX.Y prefix or query.
func endpoint(line string) (method, path string) {
	method, rest, _ := strings.Cut(line, " ")
	path, _, _ = strings.Cut(rest, " ")
	path, _, _ = strings.Cut(path, "?")
	if len(path) > 2 && path[1] == 'v' && path[2] >= '0' && path[2] <= '9' && strings.Count(path, "/") >= 2 {
		path = path[strings.Index(path[1:], "/")+1:]
	}
	return method, path
}

// isPing reports whether a request line is Docker's liveness check.
func isPing(line string) bool {
	method, path := endpoint(line)
	return (method == http.MethodGet || method == http.MethodHead) && path == "/_ping"
}

// isEventStream reports whether a request subscribes to Docker's event stream, which a watcher keeps open indefinitely.
func isEventStream(line string) bool {
	method, path := endpoint(line)
	return method == http.MethodGet && path == "/events"
}

// holdEventStream gives a sleeping engine's event subscriber an open, empty stream, which is the truth: nothing happens while the VM sleeps.
// It returns when the client leaves or the VM wakes, and the caller then closes the connection so the client resubscribes to the real dockerd.
func holdEventStream(client net.Conn, isAsleep func() bool) {
	if _, err := io.WriteString(client, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"); err != nil {
		return
	}
	left := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, client)
		close(left)
	}()
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case <-left:
			return
		case <-tick.C:
			if !isAsleep() {
				// End the chunked body cleanly, so `docker events` sees the stream end instead of a broken response.
				_, _ = io.WriteString(client, "0\r\n\r\n")
				return
			}
		}
	}
}

// writePing answers a ping the way dockerd does, using the headers dockerd sent last time it was awake, so clients negotiate the same API version.
func writePing(w io.Writer, line string, saved http.Header) error {
	h := saved.Clone()
	if h == nil {
		h = http.Header{}
	}
	h.Del("Date")
	h.Set("Content-Type", "text/plain; charset=utf-8")
	h.Set("Content-Length", "2")
	h.Set("Cache-Control", "no-cache, no-store, must-revalidate")
	h.Set("Pragma", "no-cache")
	var b bytes.Buffer
	b.WriteString("HTTP/1.1 200 OK\r\n")
	_ = h.Write(&b)
	b.WriteString("\r\n")
	if !strings.HasPrefix(line, http.MethodHead) {
		b.WriteString("OK")
	}
	_, err := w.Write(b.Bytes())
	return err
}

// firstRequest reads up to the first request that needs dockerd and returns it with every byte read so far.
// While the VM sleeps it answers pings itself: editors and Docker Desktop ping every socket they know about, and booting a VM for each would undo sleep.
func firstRequest(client net.Conn, isAsleep func() bool, saved func() http.Header) (pending []byte, line string, err error) {
	br := bufio.NewReaderSize(client, maxRequestHead)
	for {
		line, size, err := readHead(br)
		if err != nil {
			return nil, "", err
		}
		if !isAsleep() || !isPing(line) {
			buf, _ := br.Peek(br.Buffered())
			return bytes.Clone(buf), line, nil
		}
		if _, err := br.Discard(size); err != nil {
			return nil, "", err
		}
		if err := writePing(client, line, saved()); err != nil {
			return nil, "", fmt.Errorf("answer ping: %w", err)
		}
	}
}
