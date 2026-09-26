package main

import (
	"context"
	"errors"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	"sigs.k8s.io/karpenter/pkg/cloudprovider"
)

func macMachine(name string) *unstructured.Unstructured {
	m := machineWith(name, "")
	_ = unstructured.SetNestedField(m.Object, osDarwin, "spec", "os")
	_ = unstructured.SetNestedField(m.Object, "4Gi", "spec", "memory")
	return m
}

func claimForShape(s shape) *karpv1.NodeClaim {
	c := &karpv1.NodeClaim{}
	c.Name = "claim-" + s.name()
	c.Spec.Requirements = []karpv1.NodeSelectorRequirementWithMinValues{{
		Key: corev1.LabelInstanceTypeStable, Operator: corev1.NodeSelectorOpIn, Values: []string{s.name()},
	}}
	return c
}

// A macOS shape's name is its own family and parses back to a macOS shape, or
// Create would make a Linux machine for a macOS pod.
func TestMacOSShapeNamesRoundTrip(t *testing.T) {
	b := bounds{minCPUs: 1, maxCPUs: 16, minMemoryGi: 1, maxMemoryGi: 64}
	shapes := b.macosShapes()
	if len(shapes) == 0 {
		t.Fatal("no macOS shapes")
	}
	for _, s := range shapes {
		got, ok := parseShapeName(s.name())
		if !ok || got != s {
			t.Errorf("%s parsed back as %+v, %v", s.name(), got, ok)
		}
		if s.memoryGi < 4 {
			t.Errorf("%s is under the 4 GiB a macOS guest needs", s.name())
		}
	}
	if _, ok := parseShapeName("ferry-macos-4cpu"); ok {
		t.Error("a truncated macOS name parsed")
	}
}

// The per-machine maximum caps macOS shapes too.
func TestMacOSShapesRespectTheMaximum(t *testing.T) {
	b := bounds{minCPUs: 1, maxCPUs: 4, minMemoryGi: 1, maxMemoryGi: 8}
	for _, s := range b.macosShapes() {
		if s.cpus > 4 || s.memoryGi > 8 {
			t.Errorf("%s exceeds the maximum", s.name())
		}
	}
}

// A macOS instance type says darwin and shared-macos, so only a pod that asks
// for a macOS node is ever given one -- and a Linux one never says either.
func TestInstanceTypesNameTheirOS(t *testing.T) {
	p := providerWith("")
	types, err := p.GetInstanceTypes(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var mac, macvm, linux int
	for _, it := range types {
		s, ok := parseShapeName(it.Name)
		if !ok {
			t.Fatalf("%s does not parse", it.Name)
		}
		os := it.Requirements.Get(corev1.LabelOSStable).Any()
		mode := it.Requirements.Get(modeLabel).Any()
		switch {
		case s.os == osDarwin && !s.vm && os == "darwin" && mode == modeSharedMacOS:
			mac++
		case s.vm && os == "darwin" && mode == modeMacOSVM:
			macvm++
			if pods := it.Capacity[corev1.ResourcePods]; pods.Value() != 1 {
				t.Errorf("%s holds %d pods; a pod's VM holds one", it.Name, pods.Value())
			}
		case s.os == "" && os == "linux" && mode == modeShared:
			linux++
		default:
			t.Errorf("%s says os %q, mode %q", it.Name, os, mode)
		}
	}
	if mac == 0 || macvm == 0 || linux == 0 {
		t.Errorf("%d macOS, %d macOS VM and %d Linux instance types; want all three", mac, macvm, linux)
	}
}

// Two macOS machines fill the Mac's macOS guest slots: every macOS type goes
// unavailable, with Linux types unaffected, so a third macOS pod waits in the
// scheduler rather than making a machine that cannot boot.
func TestTwoMacOSMachinesFillTheSlots(t *testing.T) {
	p := providerWith("", macMachine("mac-a"), macMachine("mac-b"))
	types, err := p.GetInstanceTypes(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range types {
		s, _ := parseShapeName(it.Name)
		available := it.Offerings[0].Available
		if s.os == osDarwin && available {
			t.Errorf("%s offered with both slots taken", it.Name)
		}
		if s.os == "" && !available && s.cpus <= 2 {
			t.Errorf("%s withheld; macOS slots have nothing to do with Linux machines", it.Name)
		}
	}

	_, err = p.Create(context.Background(), claimForShape(p.nodeClass.bounds().macosShapes()[0]))
	var ice *cloudprovider.InsufficientCapacityError
	if !errors.As(err, &ice) {
		t.Errorf("a third macOS machine: %v, want InsufficientCapacityError", err)
	}
}

// Create turns a macOS shape into a Machine that ferry-machined boots from its
// macOS image: spec.os darwin, and not the NodeClass's Linux disk.
func TestCreateMakesADarwinMachine(t *testing.T) {
	p := providerWith("")
	p.nodeClass.Spec.Image = "/some/linux/node.ext4"
	s := p.nodeClass.bounds().macosShapes()[0]
	out, err := p.Create(context.Background(), claimForShape(s))
	if err != nil {
		t.Fatal(err)
	}
	if out.Labels[corev1.LabelOSStable] != "darwin" {
		t.Errorf("claim labelled os %q", out.Labels[corev1.LabelOSStable])
	}
	m, err := p.dynamic.Resource(machineGVR).Get(context.Background(), "claim-"+s.name(), metav1GetOptions())
	if err != nil {
		t.Fatal(err)
	}
	if got := machineOS(m); got != osDarwin {
		t.Errorf("machine spec.os %q", got)
	}
	if img, _, _ := unstructured.NestedString(m.Object, "spec", "image"); img != "" {
		t.Errorf("a macOS machine was given the Linux image %q", img)
	}
	// And its image is not one it can drift from.
	claim := claimFor("claim-" + s.name())
	if reason, _ := p.IsDrifted(context.Background(), claim); reason != "" {
		t.Errorf("a macOS machine drifted: %s", reason)
	}
}

func metav1GetOptions() metav1.GetOptions { return metav1.GetOptions{} }

// A macvm shape is a Machine with spec.isolation vm, and reads back as one: the
// claim for it holds one pod, and it takes a macOS guest slot like any other.
func TestCreateMakesAMacOSVMMachine(t *testing.T) {
	p := providerWith("", macMachine("mac-a"))
	var s shape
	for _, c := range p.nodeClass.bounds().macosShapes() {
		if c.vm {
			s = c
			break
		}
	}
	if !s.vm {
		t.Fatal("no macvm shape")
	}
	out, err := p.Create(context.Background(), claimForShape(s))
	if err != nil {
		t.Fatal(err)
	}
	if pods := out.Status.Capacity[corev1.ResourcePods]; pods.Value() != 1 {
		t.Errorf("claim holds %d pods", pods.Value())
	}
	m, err := p.dynamic.Resource(machineGVR).Get(context.Background(), "claim-"+s.name(), metav1GetOptions())
	if err != nil {
		t.Fatal(err)
	}
	if !machineIsVM(m) {
		t.Errorf("machine spec %v is not a macOS VM", m.Object["spec"])
	}
	if got := p.claimFor(m).Labels[corev1.LabelInstanceTypeStable]; got != s.name() {
		t.Errorf("machine reads back as %s", got)
	}
	// That was the second slot.
	if _, err := p.Create(context.Background(), claimForShape(s)); err == nil {
		t.Error("a third macOS guest was created")
	}
}
