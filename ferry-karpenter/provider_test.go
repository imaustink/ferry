package main

import (
	"sort"
	"testing"

	corev1 "k8s.io/api/core/v1"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
)

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

// Karpenter hands Create every instance type the pod would accept and leaves
// the choice here. The values arrive sorted by name -- Requirement.
// NodeSelectorRequirement serialises them with sets.List -- so taking the first
// one takes the lexicographically smallest name, which is not the smallest
// machine. With FERRY_MACHINE_MIN_CPUS=4 it is the largest one in the
// catalogue, and a pod asking for 100m takes the whole Mac.
func TestCreatePicksTheSmallestOfferedShape(t *testing.T) {
	b := bounds{minCPUs: 4, maxCPUs: 8, minMemoryGi: 4, maxMemoryGi: 32,
		limitCPUs: 8, limitMemoryGi: 16}
	offered := b.shapes()
	if len(offered) < 2 {
		t.Fatalf("need a few shapes to choose between, got %d", len(offered))
	}

	// As Karpenter would present them: names, sorted.
	var names []string
	for _, s := range offered {
		names = append(names, s.name())
	}
	sort.Strings(names)
	if names[0] != "ferry-4cpu-16gi" {
		t.Fatalf("this test assumes %q sorts first; it is %q", "ferry-4cpu-16gi", names[0])
	}

	claim := &karpv1.NodeClaim{}
	claim.Spec.Requirements = []karpv1.NodeSelectorRequirementWithMinValues{{
		Key:      corev1.LabelInstanceTypeStable,
		Operator: corev1.NodeSelectorOpIn,
		Values:   names,
	}}

	got, ok := cheapestThatFits(b, shape{}, shapesFromRequirements(claim))
	if !ok {
		t.Fatal("nothing fitted an empty Mac")
	}
	if got.cpus != 4 || got.memoryGi != 4 {
		t.Errorf("chose %s, want the smallest offered shape ferry-4cpu-4gi", got.name())
	}
}

// A NotIn lists the shapes the claim has ruled out. Reading its values as
// candidates provisions exactly what was excluded.
func TestExcludedInstanceTypesAreNotCandidates(t *testing.T) {
	claim := &karpv1.NodeClaim{}
	claim.Spec.Requirements = []karpv1.NodeSelectorRequirementWithMinValues{{
		Key:      corev1.LabelInstanceTypeStable,
		Operator: corev1.NodeSelectorOpNotIn,
		Values:   []string{"ferry-8cpu-32gi"},
	}}
	if got := shapesFromRequirements(claim); len(got) != 0 {
		t.Errorf("a NotIn requirement offered %s as a candidate", got[0].name())
	}
}

// What is left when the budget is nearly spent: the shapes that still fit, and
// no answer at all rather than the first one when none do.
func TestTheBudgetNarrowsTheChoice(t *testing.T) {
	b := bounds{limitCPUs: 8, limitMemoryGi: 16}
	candidates := []shape{{cpus: 2, memoryGi: 2}, {cpus: 4, memoryGi: 8}}

	got, ok := cheapestThatFits(b, shape{cpus: 6, memoryGi: 12}, candidates)
	if !ok || got.cpus != 2 {
		t.Errorf("with 2 cpus left, chose %v (ok=%v); want the 2-cpu shape", got, ok)
	}
	if _, ok := cheapestThatFits(b, shape{cpus: 8, memoryGi: 16}, candidates); ok {
		t.Error("a spent budget still afforded a machine")
	}
}
