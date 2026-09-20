package main

import "testing"

// The catalogue is the part of this provider with no upstream to copy, so it is
// the part with tests. Everything else is plumbing between Karpenter's types
// and ferry's, which the compiler checks and a cluster proves.

func TestShapesStayInsideTheirBounds(t *testing.T) {
	b := bounds{minCPUs: 2, maxCPUs: 8, minMemoryGi: 2, maxMemoryGi: 32}
	for _, s := range b.shapes() {
		if s.cpus < b.minCPUs || s.cpus > b.maxCPUs {
			t.Errorf("%s has %d cpus, outside %d-%d", s.name(), s.cpus, b.minCPUs, b.maxCPUs)
		}
		if s.memoryGi < b.minMemoryGi || s.memoryGi > b.maxMemoryGi {
			t.Errorf("%s has %d GiB, outside %d-%d", s.name(), s.memoryGi, b.minMemoryGi, b.maxMemoryGi)
		}
	}
}

func TestShapesAreDistinctAndNotEmpty(t *testing.T) {
	b := bounds{minCPUs: 2, maxCPUs: 8, minMemoryGi: 2, maxMemoryGi: 32}
	got := b.shapes()
	if len(got) == 0 {
		t.Fatal("no shapes offered; Karpenter would have nothing to provision")
	}
	seen := map[string]bool{}
	for _, s := range got {
		if seen[s.name()] {
			t.Errorf("duplicate shape %s: Karpenter expects offerings to be unique", s.name())
		}
		seen[s.name()] = true
	}
}

// A catalogue that grows with the range would make every scheduling pass more
// expensive for no benefit on a machine that will hold a handful of nodes.
func TestTheCatalogueStaysSmall(t *testing.T) {
	b := bounds{minCPUs: 1, maxCPUs: 64, minMemoryGi: 1, maxMemoryGi: 512}
	if n := len(b.shapes()); n > 32 {
		t.Errorf("%d shapes for a wide range; the ladder is too fine", n)
	}
}

// A NodeClass whose floor is not a power of two still has to be satisfiable,
// or a cluster configured with min cpus 3 provisions nothing and says nothing.
func TestAnAwkwardFloorStillOffersSomething(t *testing.T) {
	b := bounds{minCPUs: 3, maxCPUs: 3, minMemoryGi: 6, maxMemoryGi: 6}
	got := b.shapes()
	if len(got) == 0 {
		t.Fatal("a 3-cpu-only NodeClass offered nothing")
	}
	for _, s := range got {
		if s.cpus != 3 || s.memoryGi != 6 {
			t.Errorf("unexpected shape %s for an exact-bounds NodeClass", s.name())
		}
	}
}

func TestMemoryLaddersAboveCPUs(t *testing.T) {
	b := bounds{minCPUs: 2, maxCPUs: 2, minMemoryGi: 2, maxMemoryGi: 8}
	var memories []int64
	for _, s := range b.shapes() {
		memories = append(memories, s.memoryGi)
	}
	// 2 cpus should be offered with 2, 4 and 8 GiB: a workload can ask for
	// memory without being made to take cores it will not use.
	for _, want := range []int64{2, 4, 8} {
		found := false
		for _, m := range memories {
			if m == want {
				found = true
			}
		}
		if !found {
			t.Errorf("no 2-cpu shape with %d GiB; memory cannot be scaled independently", want)
		}
	}
}

// The host budget. A cloud region does not run out because you asked for one
// more node; a Mac does, at a number the operator chose.
func TestTheBudgetIsEnforced(t *testing.T) {
	b := bounds{limitCPUs: 8, limitMemoryGi: 16}
	committed := shape{cpus: 6, memoryGi: 12}

	if !b.fits(committed, shape{cpus: 2, memoryGi: 4}) {
		t.Error("a shape that exactly reaches the limit should fit")
	}
	if b.fits(committed, shape{cpus: 4, memoryGi: 4}) {
		t.Error("a shape past the cpu limit was allowed")
	}
	if b.fits(committed, shape{cpus: 2, memoryGi: 8}) {
		t.Error("a shape past the memory limit was allowed")
	}
}

func TestNoLimitMeansNoCeiling(t *testing.T) {
	b := bounds{}
	if !b.fits(shape{cpus: 999, memoryGi: 999}, shape{cpus: 999, memoryGi: 999}) {
		t.Error("an unset limit should not bound anything")
	}
}

func TestRoundUpPow2(t *testing.T) {
	for in, want := range map[int64]int64{0: 1, 1: 1, 2: 2, 3: 4, 5: 8, 8: 8, 9: 16} {
		if got := roundUpPow2(in); got != want {
			t.Errorf("roundUpPow2(%d) = %d, want %d", in, got, want)
		}
	}
}

// The catalogue is handed out in the order it is built, and two callers read
// that order as meaning: `Create` takes the first shape the budget affords, and
// the startup banner takes both ends as the range offered.
func TestShapesComeBackCheapestFirst(t *testing.T) {
	b := bounds{minCPUs: 3, maxCPUs: 8, minMemoryGi: 3, maxMemoryGi: 32}
	got := b.shapes()
	for i := 1; i < len(got); i++ {
		if got[i-1].cost() > got[i].cost() {
			t.Errorf("%s came before %s, which is cheaper", got[i-1].name(), got[i].name())
		}
	}
	// The floor entry is built last and is the smallest; unsorted, it would sit
	// at the end and the banner would print it as the ceiling.
	if len(got) > 0 && (got[0].cpus != 3 || got[0].memoryGi != 3) {
		t.Errorf("cheapest shape is %s, want the 3-cpu 3-GiB floor", got[0].name())
	}
}

// Bounds that cross admit nothing. That is a configuration a Mac reaches
// without doing anything strange -- the memory ceiling is derived from the
// host -- so it has to be an empty catalogue rather than a crash.
func TestImpossibleBoundsOfferNothingRatherThanPanicking(t *testing.T) {
	b := bounds{minCPUs: 2, maxCPUs: 8, minMemoryGi: 4, maxMemoryGi: 2}
	if got := b.shapes(); len(got) != 0 {
		t.Errorf("bounds whose memory floor is above its ceiling offered %d shapes", len(got))
	}
}
