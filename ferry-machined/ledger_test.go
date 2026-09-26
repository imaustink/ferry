package main

import (
	"os"
	"path/filepath"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func machineOf(memory string) unstructured.Unstructured {
	spec := map[string]any{"cpus": int64(2)}
	if memory != "" {
		spec["memory"] = memory
	}
	return unstructured.Unstructured{Object: map[string]any{"spec": spec}}
}

// Every Machine counts, and one with no readable memory counts as nothing
// rather than stopping the sum.
func TestCommittedMemorySumsEveryMachine(t *testing.T) {
	got := committedMemory([]unstructured.Unstructured{
		machineOf("2Gi"), machineOf("4Gi"), machineOf(""), machineOf("nonsense"),
	})
	if want := int64(6 << 30); got != want {
		t.Errorf("committed %d bytes, want %d", got, want)
	}
}

// The kubelet parses the file as one integer, and an empty cluster has to
// say zero rather than leave the last machine's memory reserved.
func TestTheLedgerIsABareByteCount(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines-memory")
	if err := writeLedger(path, 6<<30); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(path); string(got) != "6442450944\n" {
		t.Errorf("ledger reads %q", got)
	}
	if err := writeLedger(path, 0); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(path); string(got) != "0\n" {
		t.Errorf("after the last machine went, ledger reads %q", got)
	}
	// Nothing left behind from the rename.
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		t.Errorf("%d files beside the ledger, want only the ledger", len(entries)-1)
	}
}
