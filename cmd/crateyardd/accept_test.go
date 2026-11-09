package main

import (
	"net"
	"syscall"
	"testing"
	"time"
)

// flakyListener fails its first Accept with EMFILE, then hands out one real connection, then reports closed.
type flakyListener struct {
	net.Listener
	calls int
	conn  net.Conn
}

func (f *flakyListener) Accept() (net.Conn, error) {
	f.calls++
	switch f.calls {
	case 1:
		return nil, &net.OpError{Op: "accept", Err: syscall.EMFILE}
	case 2:
		return f.conn, nil
	default:
		return nil, net.ErrClosed
	}
}

func TestAcceptLoopSurvivesTransientError(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	served := make(chan net.Conn, 1)
	done := make(chan struct{})
	go func() {
		acceptLoop(&flakyListener{conn: a}, "test", func(c net.Conn) { served <- c })
		close(done)
	}()
	select {
	case c := <-served:
		if c != a {
			t.Fatal("served a different connection")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("acceptLoop stopped after a transient Accept error")
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("acceptLoop did not return after the listener closed")
	}
}
