package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"sync"
	"syscall"
	"time"

	"github.com/Code-Hex/vz/v3"
)

const (
	// idleAfter is how long Crateyard waits with nothing running before it stops the VM and hands all its memory back to macOS.
	idleAfter = 5 * time.Minute
	idleCheck = 10 * time.Second
	// longConnection separates real work (a build, a pull, an attached run) from quick API calls like Crateyard.app's polling.
	longConnection = 2 * time.Second
	// quietConnection is how long a long connection may go without traffic before it stops counting as work.
	// Pooled keep-alive clients (Testcontainers, dockerode) hold idle sockets for hours.
	quietConnection = 30 * time.Second
	// wakeRetryAfter stops a queue of clients from each retrying a boot that just failed.
	wakeRetryAfter = 10 * time.Second
)

// engine owns the VM across sleeps. The Docker socket stays open while the VM sleeps, and the first client wakes it.
type engine struct {
	spec   machineSpec
	status *engineStatus
	idle   *idleTracker
	// crashed reports a VM that stopped without Crateyard asking it to.
	crashed chan error

	// lifecycle serialises wake and sleep, so a client arriving mid-sleep waits and then boots a fresh VM.
	lifecycle sync.Mutex
	mu        sync.Mutex
	vm        *vz.VirtualMachine
	stopped   chan error
	cancel    context.CancelFunc
	ping      http.Header
	isClosed  bool
	wakeErr   error
	wakeErrAt time.Time
}

func newEngine(spec machineSpec, status *engineStatus) *engine {
	return &engine{spec: spec, status: status, idle: newIdleTracker(idleAfter), crashed: make(chan error, 1)}
}

func (e *engine) current() *vz.VirtualMachine {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.vm
}

func (e *engine) savedPing() http.Header {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.ping
}

// vsockDialTimeout bounds a connect to the guest. Virtualization.framework never answers a connect to a port whose
// listener has stopped accepting, so without it every docker client would hang forever.
const vsockDialTimeout = 5 * time.Second

// dialVsock connects to a guest port, retrying a reset: the guest's socat queues only a few pending connections,
// so a burst of clients (Docker Desktop polls with about 16 at once) gets some refused that succeed a moment later.
func dialVsock(vm *vz.VirtualMachine, port uint32) (net.Conn, error) {
	var err error
	for attempt := range 4 {
		var conn net.Conn
		if conn, err = dialVsockOnce(vm, port); err == nil || !isConnReset(err) {
			return conn, err
		}
		time.Sleep(time.Duration(attempt+1) * 20 * time.Millisecond)
	}
	return nil, err
}

func isConnReset(err error) bool {
	var ns *vz.NSError
	return errors.As(err, &ns) && ns.Domain == "NSPOSIXErrorDomain" && ns.Code == int(syscall.ECONNRESET)
}

func dialVsockOnce(vm *vz.VirtualMachine, port uint32) (net.Conn, error) {
	if vm == nil {
		return nil, errors.New("the VM is not running")
	}
	devices := vm.SocketDevices()
	if len(devices) == 0 {
		return nil, errors.New("the VM has no vsock device")
	}
	type result struct {
		conn net.Conn
		err  error
	}
	done := make(chan result, 1)
	go func() {
		c, err := devices[0].Connect(port)
		if err != nil {
			// c is a typed nil pointer here, which a net.Conn would report as non-nil.
			done <- result{nil, err}
			return
		}
		done <- result{c, nil}
	}()
	select {
	case r := <-done:
		return r.conn, r.err
	case <-time.After(vsockDialTimeout):
		// Close a connect that completes after the caller gave up, so it does not leak.
		go func() {
			if r := <-done; r.conn != nil {
				r.conn.Close()
			}
		}()
		return nil, fmt.Errorf("the VM did not accept a connection on port %d within %v, see ~/.crateyard/console.log", port, vsockDialTimeout)
	}
}

// dialDocker connects a client to dockerd, booting the VM first if it is asleep.
func (e *engine) dialDocker() (net.Conn, error) {
	if vm := e.current(); vm != nil {
		return dialVsock(vm, dockerVsockPort)
	}
	if err := e.wake(); err != nil {
		return nil, err
	}
	return dialVsock(e.current(), dockerVsockPort)
}

// wake boots a new VM and starts the per-boot work: memory balancing and port forwarding. It is a no-op when the VM runs.
func (e *engine) wake() error {
	e.lifecycle.Lock()
	defer e.lifecycle.Unlock()
	if e.current() != nil {
		return nil
	}
	if e.isClosed {
		return errors.New("crateyard is shutting down")
	}
	if e.wakeErr != nil && time.Since(e.wakeErrAt) < wakeRetryAfter {
		return e.wakeErr
	}
	ping, vm, stopped, started, err := e.boot()
	if err != nil {
		e.wakeErr, e.wakeErrAt = err, time.Now()
		e.status.update(func(s *statusData) { s.State, s.LastError = stateSleeping, err.Error() })
		return err
	}
	e.wakeErr = nil
	dial := func() (net.Conn, error) { return dialVsock(vm, dockerVsockPort) }
	boot := time.Since(started).Seconds()
	fmt.Printf("docker ready in %.2fs\n", boot)

	ctx, cancel := context.WithCancel(context.Background())
	e.mu.Lock()
	e.vm, e.stopped, e.cancel, e.ping = vm, stopped, cancel, ping
	e.mu.Unlock()
	e.idle.reset(time.Now())
	e.status.update(func(s *statusData) {
		s.State, s.BootSeconds, s.StartedAt, s.SleepsAt, s.LastError = stateRunning, boot, started, nil, ""
	})

	go balanceMemory(ctx, vm, func() (net.Conn, error) { return dialVsock(vm, meminfoVsockPort) }, e.spec.memory, func(used, target uint64) {
		e.status.update(func(s *statusData) { s.GuestUsedBytes, s.BalloonTargetBytes = used, target })
	})
	go forwardPorts(ctx, dial, func(port uint32) (net.Conn, error) { return dialVsock(vm, port) }, func(ports []string) {
		e.status.update(func(s *statusData) { s.Ports = ports })
	})
	go func() {
		select {
		case err := <-stopped:
			// A stop Crateyard asked for clears e.vm first, so anything else is a crash or a guest poweroff.
			if e.current() == vm {
				e.crashed <- errors.Join(errors.New("the VM stopped on its own"), err)
			}
		case <-ctx.Done():
		}
	}()
	return nil
}

// boot starts a VM and waits for dockerd inside it.
func (e *engine) boot() (ping http.Header, vm *vz.VirtualMachine, stopped chan error, started time.Time, err error) {
	e.status.update(func(s *statusData) { s.State = stateStarting })
	vm, err = newMachine(e.spec)
	if err != nil {
		return nil, nil, nil, started, err
	}
	started = time.Now()
	if err := vm.Start(); err != nil {
		return nil, nil, nil, started, fmt.Errorf("start machine: %w", err)
	}
	stopped = make(chan error, 1)
	go func() { stopped <- waitStopped(vm) }()
	ping, err = waitForDocker(func() (net.Conn, error) { return dialVsock(vm, dockerVsockPort) }, 60*time.Second)
	if err != nil {
		_ = shutdown(vm, stopped)
		return nil, nil, nil, started, err
	}
	return ping, vm, stopped, started, nil
}

// sleep stops the VM so macOS takes back every page it holds. Images, volumes and stopped containers stay on the data disk.
func (e *engine) sleep() error {
	e.lifecycle.Lock()
	defer e.lifecycle.Unlock()
	vm, stopped, cancel := e.detach()
	if vm == nil {
		return nil
	}
	// Report stopping before the guest shuts down (it takes several seconds), so Crateyard.app stops polling Docker and does not wake it again.
	e.status.update(func(s *statusData) { s.State = stateStopping })
	cancel()
	err := shutdown(vm, stopped)
	e.status.update(func(s *statusData) {
		s.State, s.GuestUsedBytes, s.BalloonTargetBytes, s.Ports, s.SleepsAt = stateSleeping, 0, 0, nil, nil
	})
	fmt.Println("idle: VM stopped, memory returned to macOS")
	return err
}

// detach takes the running VM out of the engine, so its own crash watcher treats the coming stop as asked for.
func (e *engine) detach() (*vz.VirtualMachine, chan error, context.CancelFunc) {
	e.mu.Lock()
	defer e.mu.Unlock()
	vm, stopped, cancel := e.vm, e.stopped, e.cancel
	e.vm, e.stopped, e.cancel = nil, nil, nil
	return vm, stopped, cancel
}

// watchIdle puts the VM to sleep once nothing has run for idleAfter.
func (e *engine) watchIdle(ctx context.Context) {
	ticker := time.NewTicker(idleCheck)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		vm := e.current()
		if vm == nil {
			continue
		}
		running, err := runningContainers(func() (net.Conn, error) { return dialVsock(vm, dockerVsockPort) })
		if err != nil {
			// Unknown is treated as busy: sleeping on a guess could stop someone's containers.
			e.idle.reset(time.Now())
			continue
		}
		shouldSleep := e.idle.observe(time.Now(), running)
		e.status.update(func(s *statusData) { s.SleepsAt = e.idle.sleepsAt() })
		if shouldSleep {
			fmt.Printf("idle: nothing ran for %v\n", idleAfter)
			if err := e.sleep(); err != nil {
				fmt.Fprintln(os.Stderr, "crateyardd: stopping the idle VM:", err)
			}
		}
	}
}

func runningContainers(dial func() (net.Conn, error)) (int, error) {
	resp, err := dockerHTTP(dial, 5*time.Second).Get("http://docker/containers/json")
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("docker answered %s", resp.Status)
	}
	var list []json.RawMessage
	if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
		return 0, err
	}
	return len(list), nil
}

// shutdownAll stops the VM for good when crateyardd exits. Any later wake is refused.
func (e *engine) shutdownAll() error {
	e.lifecycle.Lock()
	defer e.lifecycle.Unlock()
	e.isClosed = true
	vm, stopped, cancel := e.detach()
	if vm == nil {
		return nil
	}
	cancel()
	return shutdown(vm, stopped)
}

// idleTracker decides when the VM may sleep: no running containers and no working client connection for a full idle period.
type idleTracker struct {
	after time.Duration

	mu        sync.Mutex
	open      map[uint64]*connection
	next      uint64
	idleSince time.Time
	isBusy    bool
}

type connection struct{ opened, lastActive time.Time }

func newIdleTracker(after time.Duration) *idleTracker {
	return &idleTracker{after: after, open: map[uint64]*connection{}}
}

// begin records a client connection and returns the id to pass to touch and end.
func (t *idleTracker) begin(now time.Time) uint64 {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.next++
	t.open[t.next] = &connection{opened: now, lastActive: now}
	return t.next
}

// touch records traffic on a connection.
func (t *idleTracker) touch(id uint64, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if c, ok := t.open[id]; ok {
		c.lastActive = now
	}
}

func (t *idleTracker) end(id uint64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.open, id)
}

func (t *idleTracker) reset(now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.idleSince = now
}

// observe reports whether the VM has been idle for the whole period as of now.
// A long connection with recent traffic (a build, a pull, an attached shell's output) is work and restarts the period.
// A request still in flight defers sleep without restarting it, so a docker run arriving at the last second is not cut off.
func (t *idleTracker) observe(now time.Time, running int) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	busy := running > 0
	hasFresh := false
	for _, c := range t.open {
		age := now.Sub(c.opened)
		switch {
		case age < longConnection:
			hasFresh = true
		case now.Sub(c.lastActive) < quietConnection:
			busy = true
		}
	}
	t.isBusy = busy
	if busy || t.idleSince.IsZero() {
		t.idleSince = now
		return false
	}
	return !hasFresh && now.Sub(t.idleSince) >= t.after
}

// sleepsAt returns when the VM will sleep if nothing changes, or nil while something keeps it awake.
func (t *idleTracker) sleepsAt() *time.Time {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.isBusy || t.idleSince.IsZero() {
		return nil
	}
	// Whole seconds in UTC, so Swift's .iso8601 date decoding accepts it.
	at := t.idleSince.Add(t.after).UTC().Truncate(time.Second)
	return &at
}
