package main

// ClusterIPs have to exist somewhere for the kernel to accept traffic addressed
// to them. Pods already default-route to the Mac, so packets for 10.96.0.0/16
// arrive here; adding each ClusterIP as a loopback alias makes the kernel treat
// it as a local address and deliver it to our listener.
//
// This is the reason ferry-proxy runs as root. Nothing else here needs it.

import (
	"fmt"
	"os/exec"
	"sync"

	"k8s.io/klog/v2"
)

type aliasManager struct {
	mu    sync.Mutex
	added map[string]bool
}

func newAliasManager() *aliasManager {
	return &aliasManager{added: map[string]bool{}}
}

func (a *aliasManager) ensure(ip string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.added[ip] {
		return nil
	}
	// A /32 alias: we are claiming exactly this address, not a subnet.
	out, err := exec.Command("ifconfig", "lo0", "alias", ip, "netmask", "255.255.255.255").CombinedOutput()
	if err != nil {
		// Already present from a previous run is not a failure.
		if _, probe := exec.Command("ifconfig", "lo0").Output(); probe == nil && containsAddress(ip) {
			a.added[ip] = true
			return nil
		}
		return fmt.Errorf("add loopback alias %s: %w (%s)", ip, err, out)
	}
	a.added[ip] = true
	klog.V(2).InfoS("Added loopback alias", "ip", ip)
	return nil
}

func (a *aliasManager) remove(ip string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.added[ip] {
		return
	}
	if out, err := exec.Command("ifconfig", "lo0", "-alias", ip).CombinedOutput(); err != nil {
		klog.ErrorS(err, "Failed to remove loopback alias", "ip", ip, "output", string(out))
	}
	delete(a.added, ip)
}

// removeAll drops every alias this process added. Aliases outlive the process,
// so without this a restart leaves the previous run's addresses bound.
func (a *aliasManager) removeAll() {
	a.mu.Lock()
	ips := make([]string, 0, len(a.added))
	for ip := range a.added {
		ips = append(ips, ip)
	}
	a.mu.Unlock()
	for _, ip := range ips {
		a.remove(ip)
	}
}

func containsAddress(ip string) bool {
	out, err := exec.Command("ifconfig", "lo0").Output()
	if err != nil {
		return false
	}
	return len(out) > 0 && containsWord(string(out), ip)
}

func containsWord(haystack, needle string) bool {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] != needle {
			continue
		}
		before := i == 0 || haystack[i-1] == ' ' || haystack[i-1] == '\t'
		afterIdx := i + len(needle)
		after := afterIdx == len(haystack) || haystack[afterIdx] == ' ' || haystack[afterIdx] == '\n'
		if before && after {
			return true
		}
	}
	return false
}
