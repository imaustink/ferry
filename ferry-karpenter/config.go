package main

// ferry's own settings, read from the environment rather than from flags.
//
// Karpenter's operator parses the command line itself, with its own flag set,
// and rejects anything it does not recognise -- so a `--kubeconfig` of ferry's
// own is not merely a collision with controller-runtime's, it is an argument
// the operator refuses to start with. The command line therefore belongs
// entirely to Karpenter, and everything ferry needs to say arrives another way.
//
// KUBECONFIG is the exception that is not an exception: it is the variable
// controller-runtime already reads to find a cluster from outside one, so
// pointing it at ferry's admin.conf is how the operator is told where to
// connect, with no ferry-specific mechanism at all.

import (
	"os"
	"strconv"
)

type config struct {
	image      string
	durability string
	bounds     bounds
	maxPods    int64
}

func configFromEnv() config {
	return config{
		// FERRY_MACHINE_IMAGE rather than FERRY_NODE_IMAGE, which the ferry
		// script already uses for something else -- the OCI layout the node
		// image is built from, not the disk a machine is cloned from. Sharing
		// the name means a checkout with a custom layout silently sets a node
		// class image that is a directory of OCI blobs.
		image: os.Getenv("FERRY_MACHINE_IMAGE"),
		// machineDurability in ferry's config file. Validated by the
		// Machine CRD's enum when the machine is created, which is where
		// a wrong value would otherwise be discovered too late.
		durability: os.Getenv("FERRY_MACHINE_DURABILITY"),
		maxPods:    envInt("FERRY_MACHINE_MAX_PODS", 110),
		bounds: bounds{
			minCPUs:     envInt("FERRY_MACHINE_MIN_CPUS", 2),
			maxCPUs:     envInt("FERRY_MACHINE_MAX_CPUS", 8),
			minMemoryGi: envInt("FERRY_MACHINE_MIN_MEMORY_GI", 2),
			maxMemoryGi: envInt("FERRY_MACHINE_MAX_MEMORY_GI", 16),
			// What every machine together may be, which is a different number
			// from what one machine may be. Collapsing them gives either a
			// single machine that can eat the whole budget or a budget that
			// silently caps machine size.
			limitCPUs:     envInt("FERRY_MACHINE_LIMIT_CPUS", 8),
			limitMemoryGi: envInt("FERRY_MACHINE_LIMIT_MEMORY_GI", 16),
		},
	}
}

func (c config) nodeClass() *FerryNodeClass {
	n := &FerryNodeClass{}
	n.Spec.Image = c.image
	n.Spec.Durability = c.durability
	n.Spec.CPUs = Range{Min: c.bounds.minCPUs, Max: c.bounds.maxCPUs}
	n.Spec.MemoryGi = Range{Min: c.bounds.minMemoryGi, Max: c.bounds.maxMemoryGi}
	n.Spec.Limits = Limits{CPUs: c.bounds.limitCPUs, MemoryGi: c.bounds.limitMemoryGi}
	n.Spec.MaxPods = c.maxPods
	return n
}

func envInt(name string, fallback int64) int64 {
	v := os.Getenv(name)
	if v == "" {
		return fallback
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}
