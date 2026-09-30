package main

// The shapes a machine may take, and what the Mac will commit to them.
//
// Karpenter provisions by picking an instance type, so ferry has to offer a
// catalogue. It does not have one: a machine can be any shape the hypervisor
// will boot. So the catalogue is synthesised from a range -- powers of two
// between a floor and a ceiling -- which gives Karpenter something to bin-pack
// against without pretending a Mac has instance types.
//
// Powers of two rather than a fine-grained ladder for a reason. Karpenter's
// scheduling cost is per instance type considered, and a laptop gains nothing
// from choosing between a 5 and a 6 cpu node. Doubling keeps the catalogue to a
// handful of entries that differ enough to matter.

import (
	"cmp"
	"fmt"
	"slices"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
)

// shape is one synthesised instance type: a cpu count and a memory ceiling.
type shape struct {
	cpus     int64
	memoryGi int64
	// "darwin" for a macOS machine (experiment 39), whose pods are macOS
	// processes; empty is Linux.
	os string
	// vm is a macOS machine that is one pod's VM -- mode 1, for macOS: the
	// pod gets an XNU kernel of its own, at the price of a whole guest.
	vm bool
}

func (s shape) name() string {
	if s.os == osDarwin {
		return fmt.Sprintf("ferry-macvm-%dcpu-%dgi", s.cpus, s.memoryGi)
	}
	return fmt.Sprintf("ferry-%dcpu-%dgi", s.cpus, s.memoryGi)
}

// macOS machines are a short catalogue of their own. A macOS guest needs 4 GiB
// to install and touches all the memory it is given, so there is no cheap
// rung to offer below that, and the Mac runs two of them at most -- so a few
// sizes, capped by the same per-machine maximum Linux shapes are.
const osDarwin = "darwin"

// maxMacOSGuests is Virtualization.framework's limit, and the macOS licence's:
// the third macOS guest is refused at start, whatever else is free.
const maxMacOSGuests = 2

// Every macOS machine is one pod's VM (mode 1, for macOS): the pod gets an XNU
// kernel of its own. Shared-kernel macOS machines were removed, so there is no
// non-vm darwin shape.
func (b bounds) macosShapes() []shape {
	var out []shape
	for _, s := range []shape{{cpus: 4, memoryGi: 4}, {cpus: 4, memoryGi: 8}, {cpus: 8, memoryGi: 16}} {
		if b.maxCPUs > 0 && s.cpus > b.maxCPUs || b.maxMemoryGi > 0 && s.memoryGi > b.maxMemoryGi {
			continue
		}
		s.os = osDarwin
		s.vm = true
		out = append(out, s)
	}
	return out
}

// cost is what this shape is worth to Karpenter's cheapest-fit logic, and what
// "smallest" means everywhere else here.
//
// Everything on a Mac costs the same in money; what a shape actually spends is
// the host's cores and memory, so the price is those. Cores dominate because a
// machine that is not running anything still holds its vcpus against the Mac's
// scheduler, while untouched guest memory is nearly free (experiment 14).
func (s shape) cost() float64 { return float64(s.cpus)*1.0 + float64(s.memoryGi)*0.1 }

func (s shape) capacity(maxPods int64) corev1.ResourceList {
	if s.vm {
		maxPods = 1 // what makes it one pod's VM
	}
	return corev1.ResourceList{
		corev1.ResourceCPU:    *resource.NewQuantity(s.cpus, resource.DecimalSI),
		corev1.ResourceMemory: *resource.NewQuantity(s.memoryGi*gibibyte, resource.BinarySI),
		corev1.ResourcePods:   *resource.NewQuantity(maxPods, resource.DecimalSI),
	}
}

const (
	mebibyte = 1024 * 1024
	gibibyte = 1024 * mebibyte
)

// bounds is what a NodeClass allows a machine to be, and what the Mac will
// spend in total.
type bounds struct {
	minCPUs, maxCPUs         int64
	minMemoryGi, maxMemoryGi int64
	limitCPUs, limitMemoryGi int64
}

// shapes enumerates the catalogue: every power-of-two cpu count and memory size
// inside the bounds, paired.
//
// Pairs rather than a cross product of all cpus against all memory. A 2 cpu
// node with 32 GiB and an 8 cpu node with 2 GiB are both shapes a hypervisor
// would happily boot and neither is a shape anybody wants, and every one of
// them is another instance type for Karpenter to consider on every scheduling
// pass. The ladder walks both together and then widens memory only, which
// covers the case the guest actually hits -- a workload that wants memory more
// than it wants cores.
func (b bounds) shapes() []shape {
	var out []shape
	seen := map[string]bool{}
	add := func(c, m int64) {
		if c < b.minCPUs || c > b.maxCPUs || m < b.minMemoryGi || m > b.maxMemoryGi {
			return
		}
		s := shape{cpus: c, memoryGi: m}
		if seen[s.name()] {
			return
		}
		seen[s.name()] = true
		out = append(out, s)
	}
	for c := roundUpPow2(b.minCPUs); c <= b.maxCPUs; c *= 2 {
		// The balanced rung, then twice and four times the memory. Untouched
		// guest memory is nearly free (experiment 14), so a generous ceiling
		// costs little and lets a memory-hungry workload land without taking
		// cores it will not use.
		for _, mult := range []int64{1, 2, 4} {
			add(c, c*mult)
		}
	}
	// A floor entry, so a NodeClass whose minimum is not a power of two still
	// has something to offer.
	add(b.minCPUs, b.minMemoryGi)
	// Cheapest first, so callers can say "the smallest shape" by taking the
	// front of the slice and "the range offered" by taking both ends. The floor
	// entry is appended last and is usually the smallest, so the unsorted order
	// is not the order anybody reading it would assume.
	slices.SortFunc(out, func(a, b shape) int {
		if c := cmp.Compare(a.cost(), b.cost()); c != 0 {
			return c
		}
		if c := cmp.Compare(a.cpus, b.cpus); c != 0 {
			return c
		}
		return cmp.Compare(a.memoryGi, b.memoryGi)
	})
	return out
}

func roundUpPow2(n int64) int64 {
	if n < 1 {
		return 1
	}
	p := int64(1)
	for p < n {
		p *= 2
	}
	return p
}

// fits reports whether committing this shape would stay inside what the Mac has
// agreed to spend, given what is already committed.
//
// This is the part of a Karpenter provider that has no cloud equivalent. A
// cloud region does not run out because you asked for one more node; a Mac
// does, and it does so at a number the operator chose rather than at a number
// the provider can discover. Past the limit `Create` has to refuse in a way
// that makes Karpenter stop asking -- see the insufficient-capacity error in
// provider.go -- rather than refuse in a way that makes it ask again
// immediately, which is a hot loop against the hypervisor.
func (b bounds) fits(committed shape, next shape) bool {
	if b.limitCPUs > 0 && committed.cpus+next.cpus > b.limitCPUs {
		return false
	}
	if b.limitMemoryGi > 0 && committed.memoryGi+next.memoryGi > b.limitMemoryGi {
		return false
	}
	return true
}

// host is the other half of the Mac's memory: what its own nodes have promised
// their pods, against what the Mac has.
//
// The limit above bounds machines against each other. It says nothing about
// the pod VMs the Mac node is running from the same RAM, and the Mac node
// cannot see machines either -- so each side could spend memory the other had
// already promised. The Mac's kubelet reserves what machines hold out of its
// allocatable (ferry-machined's ledger.go); this is the provisioner declining a
// machine whose memory the Mac's pods already hold. Both count the same
// promises the scheduler counts: machines by spec.memory, pods by their
// requests plus the RuntimeClass overhead.
type host struct {
	// Unknown when there is no Mac node to read -- one not registered yet, or a
	// provisioner started without being told its name. Then only the limit
	// applies, which is what applied before there was a host to count.
	known         bool
	capacity      int64 // bytes of memory the Mac node reports
	podMemory     int64 // bytes requested by pods on the Mac's own nodes
	machineMemory int64 // bytes machines hold, exact, as the kubelet reserves them
}

func (h host) fits(next shape) bool {
	if !h.known {
		return true
	}
	return h.machineMemory+next.memoryGi*gibibyte+h.podMemory <= h.capacity
}
