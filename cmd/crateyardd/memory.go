package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/Code-Hex/vz/v3"
)

const (
	// meminfoVsockPort serves the guest's /proc/meminfo.
	meminfoVsockPort = 2376
	memoryHeadroom   = 2 << 30
	memoryFloor      = 1 << 30
	// shrinkStep avoids resizing the balloon for small swings.
	shrinkStep   = 256 << 20
	shrinkAfter  = 10 * time.Second
	memoryPeriod = time.Second
)

// balanceMemory keeps the VM sized to what Linux really uses plus headroom, so idle memory goes back to macOS.
// It grows at once and shrinks only after usage has stayed low for shrinkAfter.
func balanceMemory(ctx context.Context, vm *vz.VirtualMachine, dial func() (net.Conn, error), limit uint64, report func(used, target uint64)) {
	devices := vm.MemoryBalloonDevices()
	if len(devices) == 0 {
		return
	}
	balloon := vz.AsVirtioTraditionalMemoryBalloonDevice(devices[0])
	if balloon == nil {
		return
	}
	var lowSince time.Time
	var lastUsed uint64
	ticker := time.NewTicker(memoryPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		current := balloon.GetTargetVirtualMachineMemorySize()
		used, err := guestUsedMemory(dial)
		if err != nil {
			// Under memory pressure the guest cannot fork the process that reports its usage, so a failed read is a pressure signal.
			// Growing to the limit is the safe answer, a stale reading would keep starving whatever is using the memory.
			if current < limit {
				balloon.SetTargetVirtualMachineMemorySize(limit)
				fmt.Printf("memory: cannot read usage from the VM (%v), grown to the %d MB limit\n", err, limit>>20)
			}
			report(lastUsed, limit)
			lowSince = time.Time{}
			continue
		}
		lastUsed = used
		want := clamp(used+memoryHeadroom, memoryFloor, limit)
		switch {
		case want > current:
			balloon.SetTargetVirtualMachineMemorySize(want)
			lowSince = time.Time{}
			fmt.Printf("memory: guest uses %d MB, VM grown to %d MB\n", used>>20, want>>20)
		case current-want >= shrinkStep:
			if lowSince.IsZero() {
				lowSince = time.Now()
			} else if time.Since(lowSince) >= shrinkAfter {
				balloon.SetTargetVirtualMachineMemorySize(want)
				lowSince = time.Time{}
				fmt.Printf("memory: guest uses %d MB, VM shrunk to %d MB\n", used>>20, want>>20)
			}
		default:
			lowSince = time.Time{}
		}
		report(used, balloon.GetTargetVirtualMachineMemorySize())
	}
}

// guestUsedMemory returns what containers and the kernel really use. Page cache counts as available, so it is given back too.
func guestUsedMemory(dial func() (net.Conn, error)) (uint64, error) {
	conn, err := dial()
	if err != nil {
		return 0, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(time.Second))
	return parseUsedMemory(conn)
}

func parseUsedMemory(r io.Reader) (uint64, error) {
	values := map[string]uint64{}
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 {
			continue
		}
		// meminfo lines are in kB, vmstat balloon counters are in 4 KiB pages.
		value, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			continue
		}
		values[strings.TrimSuffix(fields[0], ":")] = value
	}
	total, hasTotal := values["MemTotal"]
	available, hasAvailable := values["MemAvailable"]
	if !hasTotal || !hasAvailable || available > total {
		return 0, fmt.Errorf("meminfo from the VM is incomplete")
	}
	// Pages held by the balloon stay inside MemTotal and look used, so leaving them in would make the balloon chase itself.
	balloonKB := (values["balloon_inflate"] - min(values["balloon_deflate"], values["balloon_inflate"])) * 4
	used := total - available
	if balloonKB > used {
		return 0, nil
	}
	return (used - balloonKB) * 1024, nil
}

func clamp(v, lo, hi uint64) uint64 {
	return min(max(v, lo), hi)
}
