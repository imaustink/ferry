package main

import "testing"

// The instance type name is the only thing Karpenter carries between choosing a
// shape and asking for it, so a name that does not parse back is a Create that
// cannot know what to build.
func TestShapeNamesRoundTrip(t *testing.T) {
	b := bounds{minCPUs: 1, maxCPUs: 16, minMemoryGi: 1, maxMemoryGi: 64}
	shapes := b.shapes()
	if len(shapes) == 0 {
		t.Fatal("no shapes to round trip")
	}
	for _, s := range shapes {
		got, ok := parseShapeName(s.name())
		if !ok {
			t.Errorf("%s did not parse back", s.name())
			continue
		}
		if got != s {
			t.Errorf("%s parsed back as %d cpu %d GiB", s.name(), got.cpus, got.memoryGi)
		}
	}
}

func TestParseShapeNameRejectsNonsense(t *testing.T) {
	for _, in := range []string{"", "ferry", "ferry-4cpu", "m5.large", "ferry-xcpu-8gi", "ferry-4cpu-xgi"} {
		if _, ok := parseShapeName(in); ok {
			t.Errorf("parseShapeName(%q) accepted a name it should not", in)
		}
	}
}

// A provider id has to survive the trip to Karpenter and back: Delete and Get
// are given nothing else to find the machine with.
func TestProviderIDRoundTrips(t *testing.T) {
	name, ok := nameFromProviderID(providerIDFor("worker-0"))
	if !ok || name != "worker-0" {
		t.Errorf("provider id round trip gave %q, %v", name, ok)
	}
	for _, in := range []string{"", "aws:///i-123", "ferry://"} {
		if _, ok := nameFromProviderID(in); ok {
			t.Errorf("nameFromProviderID(%q) accepted a foreign id", in)
		}
	}
}

// An empty NodeClass has to provision something sensible, because the common
// case is ferry starting this with no NodeClass in the cluster at all.
func TestAnEmptyNodeClassStillOffersShapes(t *testing.T) {
	n := &FerryNodeClass{}
	if got := len(n.bounds().shapes()); got == 0 {
		t.Fatal("a default NodeClass offered no shapes")
	}
	if n.maxPods() != 110 {
		t.Errorf("default maxPods is %d, want Kubernetes' own 110", n.maxPods())
	}
	b := n.bounds()
	if b.limitCPUs == 0 || b.limitMemoryGi == 0 {
		t.Error("a default NodeClass has no host budget; a provisioner with no ceiling finds it by hitting it")
	}
}

// Every shape a default NodeClass offers must be one the default budget can
// actually afford, or Karpenter is offered types it can never get.
func TestDefaultShapesFitTheDefaultBudget(t *testing.T) {
	b := (&FerryNodeClass{}).bounds()
	for _, s := range b.shapes() {
		if !b.fits(shape{}, s) {
			t.Errorf("%s cannot fit an empty Mac under the default budget of %d cpus and %d GiB",
				s.name(), b.limitCPUs, b.limitMemoryGi)
		}
	}
}
