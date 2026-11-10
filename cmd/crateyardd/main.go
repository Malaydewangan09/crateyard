package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/Code-Hex/vz/v3"
)

const (
	// dockerVsockPort is where socat in the guest exposes /var/run/docker.sock.
	dockerVsockPort = 2375
	// maxMachineMemory is the most the VM can use. The balloon keeps it near what containers actually need.
	maxMachineMemory = 8 << 30
)

// machineMemory caps the VM at half the Mac's memory, so a VM grown to its limit cannot starve macOS on an 8 GB Mac.
func machineMemory() uint64 {
	raw, err := syscall.Sysctl("hw.memsize")
	if err != nil || len(raw) < 4 {
		return maxMachineMemory
	}
	// Sysctl trims a trailing zero byte, so pad back to eight before decoding the little-endian uint64.
	b := append([]byte(raw), make([]byte, 8)...)[:8]
	return min(maxMachineMemory, binary.LittleEndian.Uint64(b)/2)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: crateyardd image | run")
		os.Exit(2)
	}
	// Started by Crateyard.app, crateyardd gets launchd's PATH, which misses where Homebrew and Docker Desktop put the docker CLI.
	os.Setenv("PATH", os.Getenv("PATH")+":/opt/homebrew/bin:/usr/local/bin")
	dir, err := stateDir()
	var unlock func()
	if err == nil {
		unlock, err = lockStateDir(dir)
	}
	if err == nil {
		defer unlock()
		switch os.Args[1] {
		case "image":
			err = buildImage(dir)
		case "run":
			err = run(dir)
		default:
			err = fmt.Errorf("unknown command %q, use image or run", os.Args[1])
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "crateyardd:", err)
		os.Exit(1)
	}
}

// lockStateDir makes sure only one crateyardd uses ~/.crateyard, since two would share the data disk and steal each other's sockets.
func lockStateDir(dir string) (func(), error) {
	f, err := os.OpenFile(filepath.Join(dir, "crateyardd.lock"), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, errors.New("another crateyardd is already running, quit Crateyard first")
	}
	return func() { f.Close() }, nil
}

func stateDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, ".crateyard")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	// The data disk holds every volume, so other users on this Mac must not read it. Chmod covers installs made before 0700.
	return dir, os.Chmod(dir, 0o700)
}

func run(dir string) error {
	for _, name := range []string{"Image", "initramfs", "root.img", "data.img", rootMarker} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			return fmt.Errorf("%s is missing in %s, run 'crateyardd image' first", name, dir)
		}
	}
	console, err := os.Create(filepath.Join(dir, "console.log"))
	if err != nil {
		return err
	}
	defer console.Close()

	socketPath := filepath.Join(dir, "docker.sock")
	memory := machineMemory()
	st := &engineStatus{d: statusData{State: stateStarting, StartedAt: time.Now(), MemoryLimitBytes: memory, DockerSocket: socketPath}}
	e := newEngine(machineSpec{
		kernel: filepath.Join(dir, "Image"),
		initrd: filepath.Join(dir, "initramfs"),
		// init_on_alloc=0: Alpine zeroes every allocated page by default, so inflating the balloon would write to,
		// and make macOS back, all the memory it is meant to give back.
		cmdline: "console=hvc0 root=/dev/vda rootfstype=ext4 modules=virtio_blk,ext4 init_on_alloc=0",
		cpus:    4,
		memory:  memory,
		disks:   []string{filepath.Join(dir, "root.img"), filepath.Join(dir, "data.img")},
		console: console,
		share:   "/Users",
	}, st)

	stop := make(chan struct{})
	closeControl, err := serveControl(dir, st, stop, func() {
		if err := e.wake(); err != nil {
			fmt.Fprintln(os.Stderr, "crateyardd: wake:", err)
		}
	}, func() {
		if err := e.sleep(); err != nil {
			fmt.Fprintln(os.Stderr, "crateyardd: sleep:", err)
		}
	})
	if err != nil {
		return err
	}
	defer closeControl()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)

	if err := e.wake(); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go sampleHost(ctx, st, filepath.Join(dir, "data.img"))
	go e.watchIdle(ctx)

	listener, err := listenUnix(socketPath)
	if err != nil {
		return err
	}
	defer listener.Close()
	go serveProxy(listener, e)
	defer useDockerContext(dir, "unix://"+socketPath)()

	select {
	case err := <-e.crashed:
		return err
	case <-signals:
	case <-stop:
	}
	st.update(func(s *statusData) { s.State = stateStopping })
	// Stop taking clients first, or a late docker command would boot a fresh VM that is then killed mid-boot.
	listener.Close()
	return e.shutdownAll()
}

func shutdown(vm *vz.VirtualMachine, stopped <-chan error) error {
	if vm.CanRequestStop() {
		if _, err := vm.RequestStop(); err == nil {
			select {
			case err := <-stopped:
				return err
			case <-time.After(15 * time.Second):
			}
		}
	}
	if vm.CanStop() {
		return vm.Stop()
	}
	return nil
}

// dockerHTTP is an HTTP client for dockerd over the given dial. Keep-alive is off: a pooled vsock connection
// outlives the VM it belongs to, and each one also holds a socat process in the guest.
func dockerHTTP(dial func() (net.Conn, error), timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			DialContext:       func(context.Context, string, string) (net.Conn, error) { return dial() },
			DisableKeepAlives: true,
		},
	}
}

// waitForDocker polls dockerd until it answers a ping and returns that ping's headers.
func waitForDocker(dial func() (net.Conn, error), timeout time.Duration) (http.Header, error) {
	client := dockerHTTP(dial, time.Second)
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		resp, err := client.Get("http://docker/_ping")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return resp.Header, nil
			}
			err = fmt.Errorf("status %s", resp.Status)
		}
		lastErr = err
		time.Sleep(50 * time.Millisecond)
	}
	return nil, fmt.Errorf("docker did not answer over vsock in time (last error: %v), check ~/.crateyard/console.log", lastErr)
}

func listenUnix(path string) (net.Listener, error) {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("remove stale socket %s: %w", path, err)
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("listen on %s: %w", path, err)
	}
	return l, os.Chmod(path, 0o600)
}

// serveProxy pipes each docker CLI connection on the Mac socket to dockerd in the guest, waking the VM if it sleeps.
func serveProxy(l net.Listener, e *engine) {
	isAsleep := func() bool { return e.current() == nil }
	acceptLoop(l, "docker socket", func(client net.Conn) {
		defer client.Close()
		pending, line, err := firstRequest(client, isAsleep, e.savedPing)
		if err != nil {
			return
		}
		var guest net.Conn
		var onData func()
		if isEventStream(line) {
			// An event watcher stays connected for hours, so it neither counts as work nor wakes the VM.
			vm := e.current()
			if vm == nil {
				holdEventStream(client, isAsleep)
				return
			}
			guest, err = dialVsock(vm, dockerVsockPort)
		} else {
			id := e.idle.begin(time.Now())
			defer e.idle.end(id)
			onData = func() { e.idle.touch(id, time.Now()) }
			if isAsleep() {
				fmt.Printf("wake: %s from %s\n", line, peerProcess(client))
			}
			guest, err = e.dialDocker()
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "crateyardd: connect to docker in the VM:", err)
			return
		}
		defer guest.Close()
		if _, err := guest.Write(pending); err != nil {
			fmt.Fprintln(os.Stderr, "crateyardd: forward request to docker in the VM:", err)
			return
		}
		pipe(client, guest, onData)
	})
}

// peerProcess names the process on the other end of a unix socket, for the wake log.
func peerProcess(c net.Conn) string {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return "unknown"
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return "unknown"
	}
	pid := 0
	_ = raw.Control(func(fd uintptr) {
		// SOL_LOCAL and LOCAL_PEERPID from <sys/un.h>.
		pid, _ = syscall.GetsockoptInt(int(fd), 0, 2)
	})
	if pid == 0 {
		return "unknown"
	}
	name, err := exec.Command("ps", "-o", "comm=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return fmt.Sprintf("pid %d", pid)
	}
	return fmt.Sprintf("%s (pid %d)", strings.TrimSpace(string(name)), pid)
}

// acceptLoop serves each connection in its own goroutine until l is closed.
// Any other Accept error (EMFILE, ECONNABORTED) is logged and retried with backoff, since returning would leave the socket open with nobody accepting.
func acceptLoop(l net.Listener, name string, handle func(net.Conn)) {
	backoff := 5 * time.Millisecond
	for {
		conn, err := l.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			fmt.Fprintf(os.Stderr, "crateyardd: accept on %s: %v, retrying in %v\n", name, err, backoff)
			time.Sleep(backoff)
			backoff = min(backoff*2, time.Second)
			continue
		}
		backoff = 5 * time.Millisecond
		go handle(conn)
	}
}

// pipe copies both ways and forwards a half-close, which `docker run -i` relies on to signal end of stdin.
// onData, when set, runs on every chunk read from either side.
func pipe(a, b net.Conn, onData func()) {
	var wg sync.WaitGroup
	copyHalf := func(dst, src net.Conn) {
		defer wg.Done()
		var r io.Reader = src
		if onData != nil {
			r = activityReader{src, onData}
		}
		_, _ = io.Copy(dst, r)
		if err := closeWrite(dst); err != nil {
			_ = dst.Close()
		}
	}
	wg.Add(2)
	go copyHalf(a, b)
	go copyHalf(b, a)
	wg.Wait()
}

type activityReader struct {
	r      io.Reader
	onData func()
}

func (a activityReader) Read(p []byte) (int, error) {
	n, err := a.r.Read(p)
	if n > 0 {
		a.onData()
	}
	return n, err
}

type halfCloser interface{ CloseWrite() error }

func closeWrite(c net.Conn) error {
	if vc, ok := c.(*vz.VirtioSocketConnection); ok {
		c = virtioRawConn(vc)
	}
	if cw, ok := c.(halfCloser); ok {
		return cw.CloseWrite()
	}
	return errors.New("connection does not support half-close")
}

// virtioRawConn reaches the unexported unix socket inside vz's connection, since vz v3.8.0 does not expose CloseWrite.
// If a vz upgrade renames the field, it falls back to vc, which only loses the half-close.
func virtioRawConn(vc *vz.VirtioSocketConnection) net.Conn {
	field := reflect.ValueOf(vc).Elem().FieldByName("rawConn")
	if !field.IsValid() || field.Type() != reflect.TypeOf((*net.Conn)(nil)).Elem() {
		return vc
	}
	return *(*net.Conn)(unsafe.Pointer(field.UnsafeAddr()))
}

// useDockerContext points the docker CLI at Crateyard and returns a func that switches back to the context the user had before.
// The previous name lives in a file, so a crash followed by a restart still restores the right one on the next clean quit.
func useDockerContext(dir, host string) (restore func()) {
	if exec.Command("docker", "context", "inspect", "crateyard").Run() == nil {
		_ = exec.Command("docker", "context", "update", "crateyard", "--docker", "host="+host).Run()
	} else if err := exec.Command("docker", "context", "create", "crateyard", "--docker", "host="+host).Run(); err != nil {
		fmt.Println("docker CLI not found or context create failed, set DOCKER_HOST=" + host)
		return func() {}
	}
	saved := filepath.Join(dir, "previous-context")
	if current := currentDockerContext(); current != "" && current != "crateyard" {
		_ = os.WriteFile(saved, []byte(current), 0o644)
	}
	if err := exec.Command("docker", "context", "use", "crateyard").Run(); err != nil {
		fmt.Println("could not switch the docker context, run: docker context use crateyard")
		return func() {}
	}
	fmt.Println("docker context: crateyard")
	return func() {
		previous, err := os.ReadFile(saved)
		if err != nil || currentDockerContext() != "crateyard" {
			return
		}
		if exec.Command("docker", "context", "use", string(previous)).Run() == nil {
			_ = os.Remove(saved)
			fmt.Println("docker context: back to " + string(previous))
		}
	}
}

func currentDockerContext() string {
	out, err := exec.Command("docker", "context", "show").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
