package main

import "testing"

func TestParseHostPorts(t *testing.T) {
	got := parseHostPorts([]byte(
		"* 5001 tcp 10.244.0.5 5000\n" +
			"0.0.0.0 53 udp 10.244.0.6 5353\n" +
			"192.168.1.29 81 tcp 10.244.0.5 80\n" +
			"* 8080 tcp 10.244.0.7\n" + // an older ferry-cri: no container port
			"* 9999 sctp 10.244.0.8 9999\n" +
			"garbage\n"))
	want := []hostPortMapping{
		{"", 5001, "tcp", "10.244.0.5", 5000},
		{"", 53, "udp", "10.244.0.6", 5353},
		{"192.168.1.29", 81, "tcp", "10.244.0.5", 80},
		{"", 8080, "tcp", "10.244.0.7", 0},
		{"", 9999, "sctp", "10.244.0.8", 9999},
	}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("line %d: got %+v, want %+v", i, got[i], want[i])
		}
	}
}
