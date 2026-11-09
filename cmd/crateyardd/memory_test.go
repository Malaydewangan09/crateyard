package main

import (
	"strings"
	"testing"
)

func TestParseUsedMemory(t *testing.T) {
	meminfo := "MemTotal:        8000000 kB\nMemFree:          100000 kB\nMemAvailable:    6000000 kB\nCached:          5000000 kB\n"
	used, err := parseUsedMemory(strings.NewReader(meminfo))
	if err != nil {
		t.Fatal(err)
	}
	if want := uint64(2000000 * 1024); used != want {
		t.Fatalf("used = %d, want %d", used, want)
	}
}

func TestParseUsedMemoryRejectsIncompleteInput(t *testing.T) {
	for _, in := range []string{"", "MemTotal: 100 kB\n", "MemTotal: 100 kB\nMemAvailable: 200 kB\n"} {
		if _, err := parseUsedMemory(strings.NewReader(in)); err == nil {
			t.Fatalf("expected an error for %q", in)
		}
	}
}

func TestParseUsedMemoryExcludesBalloonPages(t *testing.T) {
	stats := "MemTotal: 8000000 kB\nMemAvailable: 1000000 kB\nballoon_inflate 1500000\nballoon_deflate 250000\n"
	used, err := parseUsedMemory(strings.NewReader(stats))
	if err != nil {
		t.Fatal(err)
	}
	if want := uint64((7000000 - 1250000*4) * 1024); used != want {
		t.Fatalf("used = %d, want %d", used, want)
	}
}
