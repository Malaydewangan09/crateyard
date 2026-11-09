package main

import (
	"testing"
	"time"
)

func TestIdleTrackerSleepsAfterAQuietPeriod(t *testing.T) {
	now := time.Unix(0, 0)
	tr := newIdleTracker(5 * time.Minute)
	tr.reset(now)
	if tr.observe(now.Add(4*time.Minute), 0) {
		t.Fatal("slept before the idle period ended")
	}
	if at := tr.sleepsAt(); at == nil || !at.Equal(now.Add(5*time.Minute).UTC()) {
		t.Fatalf("sleep time %v, want five minutes after the quiet period began", at)
	}
	if !tr.observe(now.Add(5*time.Minute), 0) {
		t.Fatal("did not sleep after five quiet minutes")
	}
}

func TestIdleTrackerStaysAwakeWhileContainersRun(t *testing.T) {
	now := time.Unix(0, 0)
	tr := newIdleTracker(5 * time.Minute)
	tr.reset(now)
	if tr.observe(now.Add(10*time.Minute), 1) {
		t.Fatal("slept with a running container")
	}
	if tr.sleepsAt() != nil {
		t.Fatal("reported a sleep time while a container runs")
	}
	// The quiet period restarts when the last container stops.
	if tr.observe(now.Add(14*time.Minute), 0) {
		t.Fatal("slept less than five minutes after the container stopped")
	}
}

func TestIdleTrackerStaysAwakeWhileALongConnectionHasTraffic(t *testing.T) {
	now := time.Unix(0, 0)
	tr := newIdleTracker(5 * time.Minute)
	tr.reset(now)
	build := tr.begin(now.Add(time.Minute))
	for m := 2; m <= 10; m++ {
		tr.touch(build, now.Add(time.Duration(m)*time.Minute))
		if tr.observe(now.Add(time.Duration(m)*time.Minute+time.Second), 0) {
			t.Fatalf("slept during a build that was still sending output at minute %d", m)
		}
	}
	tr.end(build)
	if !tr.observe(now.Add(16*time.Minute), 0) {
		t.Fatal("did not sleep five minutes after the build ended")
	}
}

// A keep-alive pool (Testcontainers, dockerode) parks idle sockets for hours. They must not keep the VM awake.
func TestIdleTrackerSleepsDespiteAQuietPooledConnection(t *testing.T) {
	now := time.Unix(0, 0)
	tr := newIdleTracker(5 * time.Minute)
	tr.reset(now)
	tr.begin(now)
	tr.observe(now.Add(time.Minute), 0)
	if !tr.observe(now.Add(6*time.Minute), 0) {
		t.Fatal("an idle pooled connection kept the VM awake")
	}
}

// A docker run that arrives a second before the idle period ends must not have the VM stopped under it.
func TestIdleTrackerDefersSleepForARequestInFlight(t *testing.T) {
	now := time.Unix(0, 0)
	tr := newIdleTracker(5 * time.Minute)
	tr.reset(now)
	run := tr.begin(now.Add(5*time.Minute - time.Second))
	if tr.observe(now.Add(5*time.Minute), 0) {
		t.Fatal("slept with a request in flight")
	}
	tr.end(run)
	if !tr.observe(now.Add(5*time.Minute+10*time.Second), 0) {
		t.Fatal("a finished quick call restarted the idle period")
	}
}
