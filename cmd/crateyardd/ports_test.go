package main

import "testing"

func TestWantedListenersMapsDockerBindingsToMacAddresses(t *testing.T) {
	containers := []struct{ Ports []publishedPort }{
		{Ports: []publishedPort{
			{IP: "0.0.0.0", PublicPort: 8080, Type: "tcp"},
			{IP: "::", PublicPort: 8080, Type: "tcp"},
			{IP: "127.0.0.1", PublicPort: 5432, Type: "tcp"},
			{IP: "0.0.0.0", PublicPort: 53, Type: "udp"},
			{PublicPort: 0, Type: "tcp"},
		}},
	}
	got := wantedListeners(containers)
	want := map[string]uint16{"0.0.0.0:8080": 8080, "127.0.0.1:5432": 5432}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for addr, port := range want {
		if got[addr] != port {
			t.Errorf("got[%q] = %d, want %d", addr, got[addr], port)
		}
	}
}
