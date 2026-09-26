package main

// The memory machines hold, published for the Mac's kubelet.
//
// The Mac node and every machine draw on the same RAM, and the scheduler sees
// them as separate nodes with separate capacity. Left alone, the Mac node
// advertises all of the Mac's memory and each machine advertises its own on
// top, so the cluster can be promised more memory than the Mac has. The Mac's
// kubelet closes that by reserving what machines hold out of its allocatable
// (patches/kubelet/pkg/kubelet/cm/ferry_machine_reservation_darwin.go); this is
// where it learns the number.
//
// A file rather than the API because the kubelet cannot read Machines -- the
// Node authorizer gives a node its own objects and nothing else -- and because
// both processes are on the same Mac by construction: machines run where
// ferry-machined runs.
//
// Every Machine that exists counts, whatever its phase. One still provisioning
// has already been promised its memory, and one being deleted holds it until
// its VM is gone; ferry-karpenter counts the same set for the same reason.

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// committedMemory is the sum of spec.memory across machines, in bytes.
func committedMemory(items []unstructured.Unstructured) int64 {
	var total int64
	for i := range items {
		mem, _, _ := unstructured.NestedString(items[i].Object, "spec", "memory")
		if q, err := resource.ParseQuantity(mem); err == nil {
			total += q.Value()
		}
	}
	return total
}

// writeLedger replaces the file with the total, atomically and only when it
// has changed. The kubelet reads it every ten seconds and this runs every two,
// so a torn write would be read eventually, and an unchanged one rewritten
// thirty times a minute is only noise.
func writeLedger(path string, bytes int64) error {
	want := strconv.FormatInt(bytes, 10) + "\n"
	if have, err := os.ReadFile(path); err == nil && strings.TrimSpace(string(have)) == strings.TrimSpace(want) {
		return nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".machines-memory-*")
	if err != nil {
		return fmt.Errorf("memory ledger: %w", err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(want); err != nil {
		tmp.Close()
		return fmt.Errorf("memory ledger: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("memory ledger: %w", err)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return fmt.Errorf("memory ledger: %w", err)
	}
	return nil
}
