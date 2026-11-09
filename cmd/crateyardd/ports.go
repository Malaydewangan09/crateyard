package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"sync"
	"time"
)

// portVsockPort is where the guest forwarder reads a port number, then pipes to that port inside the VM.
const portVsockPort = 2377

type publishedPort struct {
	IP         string
	PublicPort uint16
	Type       string
}

// listenAddr returns where the Mac should listen for a published port. Docker's 0.0.0.0 and :: mean every interface, as with Docker Desktop.
func listenAddr(p publishedPort) (string, bool) {
	if p.Type != "tcp" || p.PublicPort == 0 {
		return "", false
	}
	host := "0.0.0.0"
	if p.IP == "127.0.0.1" || p.IP == "::1" {
		host = "127.0.0.1"
	}
	return net.JoinHostPort(host, strconv.Itoa(int(p.PublicPort))), true
}

// wantedListeners turns Docker's container list into the set of Mac addresses to listen on, keyed by address.
func wantedListeners(containers []struct{ Ports []publishedPort }) map[string]uint16 {
	want := map[string]uint16{}
	for _, c := range containers {
		for _, p := range c.Ports {
			if addr, ok := listenAddr(p); ok {
				want[addr] = p.PublicPort
			}
		}
	}
	return want
}

type portForwarder struct {
	docker    *http.Client
	dialGuest func(port uint32) (net.Conn, error)
	report    func([]string)

	mu        sync.Mutex
	listeners map[string]net.Listener
	failed    map[string]bool
}

// forwardPorts keeps one Mac listener per port that a running container publishes, until ctx ends.
func forwardPorts(ctx context.Context, dialDocker func() (net.Conn, error), dialGuest func(port uint32) (net.Conn, error), report func([]string)) {
	f := &portForwarder{
		docker:    dockerHTTP(dialDocker, 0),
		dialGuest: dialGuest,
		report:    report,
		listeners: map[string]net.Listener{},
		failed:    map[string]bool{},
	}
	defer f.closeAll()
	for ctx.Err() == nil {
		f.reconcile(ctx)
		// Any container event can change published ports. When the stream drops, poll once and reconnect after a pause,
		// so a stream that keeps closing at once cannot spin against dockerd.
		if err := f.waitForEvent(ctx); err != nil && ctx.Err() == nil {
			fmt.Fprintln(os.Stderr, "crateyardd: container events:", err)
		}
		select {
		case <-ctx.Done():
		case <-time.After(time.Second):
		}
	}
}

func (f *portForwarder) waitForEvent(ctx context.Context) error {
	filters := `{"type":["container"],"event":["start","die","stop","destroy","pause","unpause"]}`
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://docker/events?filters="+url.QueryEscape(filters), nil)
	if err != nil {
		return err
	}
	resp, err := f.docker.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("docker answered %s to the event subscription", resp.Status)
	}
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		f.reconcile(ctx)
	}
	return scanner.Err()
}

func (f *portForwarder) reconcile(ctx context.Context) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://docker/containers/json", nil)
	if err != nil {
		return
	}
	resp, err := f.docker.Do(req)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	var containers []struct{ Ports []publishedPort }
	if err := json.NewDecoder(resp.Body).Decode(&containers); err != nil {
		fmt.Fprintln(os.Stderr, "crateyardd: read container list:", err)
		return
	}
	want := wantedListeners(containers)

	f.mu.Lock()
	defer f.mu.Unlock()
	for addr, l := range f.listeners {
		if _, ok := want[addr]; !ok {
			l.Close()
			delete(f.listeners, addr)
			fmt.Println("ports: stopped", addr)
		}
	}
	for addr := range f.failed {
		if _, ok := want[addr]; !ok {
			delete(f.failed, addr)
		}
	}
	for addr, port := range want {
		if _, ok := f.listeners[addr]; ok || f.failed[addr] {
			continue
		}
		l, err := net.Listen("tcp", addr)
		if err != nil {
			f.failed[addr] = true
			fmt.Fprintf(os.Stderr, "crateyardd: cannot forward %s, something on the Mac already uses it: %v\n", addr, err)
			continue
		}
		f.listeners[addr] = l
		fmt.Println("ports: forwarding", addr)
		go f.serve(l, port)
	}
	f.report(sortedKeys(f.listeners))
}

func (f *portForwarder) serve(l net.Listener, port uint16) {
	acceptLoop(l, l.Addr().String(), func(client net.Conn) {
		defer client.Close()
		guest, err := f.dialGuest(portVsockPort)
		if err != nil {
			fmt.Fprintln(os.Stderr, "crateyardd: connect to port forwarder in the VM:", err)
			return
		}
		defer guest.Close()
		if _, err := fmt.Fprintf(guest, "%d\n", port); err != nil {
			return
		}
		pipe(client, guest, nil)
	})
}

func (f *portForwarder) closeAll() {
	f.mu.Lock()
	defer f.mu.Unlock()
	for addr, l := range f.listeners {
		l.Close()
		delete(f.listeners, addr)
	}
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
