package main

import (
	"regexp"
	"testing"
)

// Every name gets a valid id, however long: the hash overflows at about 13
// characters, and a signed one that wrapped negative panicked the controller.
func TestTokenIDOfAnyName(t *testing.T) {
	valid := regexp.MustCompile(`^[a-z0-9]{6}$`)
	for _, name := range []string{"m0", "mac-0", "default-abcde", "macos-vm-6tc9j", "macos-vm-df7nf",
		"a-machine-name-far-longer-than-karpenter-would-ever-make-0123456789"} {
		if id := tokenID(name); !valid.MatchString(id) {
			t.Errorf("%s: token id %q", name, id)
		}
	}
	if tokenID("mac-0") != tokenID("mac-0") {
		t.Error("not deterministic")
	}
}
