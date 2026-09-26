//go:build darwin

/*
Copyright 2026 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Run by build-kubelet.sh against the patched tree: nothing else compiles it.
// Every way this reader answers "none" puts the Mac node back to advertising
// memory its machines hold, silently, so each one is pinned here.
package cm

import (
	"os"
	"path/filepath"
	"testing"

	v1 "k8s.io/api/core/v1"
)

func TestFerryMachineMemoryReserved(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		return path
	}
	for _, tc := range []struct {
		name  string
		path  string
		bytes int64
		ok    bool
	}{
		{"no file named", "", 0, false},
		{"no file there", filepath.Join(dir, "missing"), 0, false},
		{"a byte count", write("valid", "6442450944\n"), 6 << 30, true},
		{"zero machines", write("zero", "0\n"), 0, true},
		{"surrounding space", write("spaced", "  1024 \n"), 1024, true},
		{"not a number", write("garbage", "six gigs"), 0, false},
		{"negative", write("negative", "-1\n"), 0, false},
	} {
		bytes, ok := machineMemoryReserved(tc.path)
		if bytes != tc.bytes || ok != tc.ok {
			t.Errorf("%s: got (%d, %v), want (%d, %v)", tc.name, bytes, ok, tc.bytes, tc.ok)
		}
	}
}

func TestFerryReservationIsMemoryOnly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines-memory")
	if err := os.WriteFile(path, []byte("6442450944\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FERRY_MACHINE_MEMORY_FILE", path)
	got := (&darwinContainerManager{}).GetNodeAllocatableReservation()
	if len(got) != 1 {
		t.Fatalf("reserved %v, want memory and nothing else", got)
	}
	if q := got[v1.ResourceMemory]; q.Value() != 6<<30 {
		t.Errorf("reserved %s of memory, want 6Gi", q.String())
	}

	t.Setenv("FERRY_MACHINE_MEMORY_FILE", "")
	if got := (&darwinContainerManager{}).GetNodeAllocatableReservation(); got != nil {
		t.Errorf("with no ledger, reserved %v", got)
	}
}
