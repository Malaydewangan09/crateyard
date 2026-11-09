package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

type engineState string

const (
	stateStarting engineState = "starting"
	stateRunning  engineState = "running"
	stateStopping engineState = "stopping"
	// stateSleeping means the VM is stopped to free memory. crateyardd still listens, and the next docker command wakes it.
	stateSleeping engineState = "sleeping"
)

// statusData is what Crateyard.app shows. Memory comes from macOS, not from the balloon target, so the app never shows a flattering number.
type statusData struct {
	State              engineState `json:"state"`
	BootSeconds        float64     `json:"bootSeconds"`
	StartedAt          time.Time   `json:"startedAt"`
	VMFootprintBytes   uint64      `json:"vmFootprintBytes"`
	GuestUsedBytes     uint64      `json:"guestUsedBytes"`
	BalloonTargetBytes uint64      `json:"balloonTargetBytes"`
	MemoryLimitBytes   uint64      `json:"memoryLimitBytes"`
	DataDiskBytes      uint64      `json:"dataDiskBytes"`
	Ports              []string    `json:"ports"`
	// SleepsAt is when the VM sleeps if nothing starts first. Absent while containers run or a client is busy.
	SleepsAt *time.Time `json:"sleepsAt,omitempty"`
	// LastError says why the last wake failed. Cleared by the next successful boot.
	LastError    string `json:"lastError,omitempty"`
	DockerSocket string `json:"dockerSocket"`
}

type engineStatus struct {
	mu sync.Mutex
	d  statusData
}

func (s *engineStatus) update(fn func(*statusData)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	fn(&s.d)
}

func (s *engineStatus) MarshalJSON() ([]byte, error) {
	s.mu.Lock()
	snapshot := s.d
	s.mu.Unlock()
	if snapshot.Ports == nil {
		snapshot.Ports = []string{}
	}
	return json.Marshal(snapshot)
}

// sampleHost refreshes what only the Mac side can see: the VM's real memory and the data disk's allocated size.
func sampleHost(ctx context.Context, st *engineStatus, dataDisk string) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		fp := vmFootprint()
		var disk uint64
		var info syscall.Stat_t
		if syscall.Stat(dataDisk, &info) == nil {
			disk = uint64(info.Blocks) * 512
		}
		st.update(func(s *statusData) { s.VMFootprintBytes, s.DataDiskBytes = fp, disk })
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// serveControl answers Crateyard.app on a socket only the current user can open.
// POST /stop shuts crateyardd down. POST /wake and POST /sleep boot or stop the VM in the background.
func serveControl(dir string, st *engineStatus, stop chan<- struct{}, wake, sleep func()) (func(), error) {
	path := filepath.Join(dir, "crateyardd.sock")
	l, err := listenUnix(path)
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("content-type", "application/json")
		_ = json.NewEncoder(w).Encode(st)
	})
	var once sync.Once
	mux.HandleFunc("POST /stop", func(w http.ResponseWriter, _ *http.Request) {
		st.update(func(s *statusData) { s.State = stateStopping })
		once.Do(func() { close(stop) })
		w.WriteHeader(http.StatusAccepted)
	})
	mux.HandleFunc("POST /wake", func(w http.ResponseWriter, _ *http.Request) {
		go wake()
		w.WriteHeader(http.StatusAccepted)
	})
	mux.HandleFunc("POST /sleep", func(w http.ResponseWriter, _ *http.Request) {
		go sleep()
		w.WriteHeader(http.StatusAccepted)
	})
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := srv.Serve(l); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Fprintln(os.Stderr, "crateyardd: control socket stopped:", err)
		}
	}()
	return func() {
		_ = srv.Close()
		_ = os.Remove(path)
	}, nil
}
