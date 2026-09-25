package main

import "testing"

// A Machine's durability is the cluster's vocabulary; ferry-node speaks
// Virtualization.framework's. Unset has to stay unset, so ferry-node falls
// back to the cluster's default rather than to one of these.
func TestDiskSync(t *testing.T) {
	for durability, want := range map[string]string{
		"":              "",
		"power-loss":    "full",
		"os-crash":      "fsync",
		"process-crash": "none",
	} {
		got, err := diskSync(durability)
		if err != nil || got != want {
			t.Errorf("diskSync(%q) = %q, %v; want %q", durability, got, err, want)
		}
	}
	// The old cluster-level names are not machine levels: `full` here would
	// be ambiguous between the cluster's power-loss and the disk's barrier.
	for _, bad := range []string{"full", "relaxed", "fsync", "none"} {
		if _, err := diskSync(bad); err == nil {
			t.Errorf("diskSync(%q) accepted", bad)
		}
	}
}
