package main

import "testing"

func TestMachineMemoryIsHalfTheMacCappedAtTheMax(t *testing.T) {
	m := machineMemory()
	if m == 0 || m > maxMachineMemory || m%(1<<20) != 0 {
		t.Fatalf("machineMemory() = %d, want a whole number of MB up to %d", m, uint64(maxMachineMemory))
	}
}
