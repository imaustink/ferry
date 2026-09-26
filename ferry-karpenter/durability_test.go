package main

import (
	"context"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
)

func machineWith(name, durability string) *unstructured.Unstructured {
	spec := map[string]any{"cpus": int64(2), "memory": "2Gi"}
	if durability != "" {
		spec["durability"] = durability
	}
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": group + "/" + version,
		"kind":       "Machine",
		"metadata":   map[string]any{"name": name},
		"spec":       spec,
	}}
}

func providerWith(durability string, objects ...runtime.Object) *Provider {
	scheme := runtime.NewScheme()
	d := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(scheme,
		map[schema.GroupVersionResource]string{machineGVR: "MachineList"}, objects...)
	n := &FerryNodeClass{}
	n.Spec.Durability = durability
	return &Provider{dynamic: d, nodeClass: n}
}

func claimFor(name string) *karpv1.NodeClaim {
	c := &karpv1.NodeClaim{}
	c.Status.ProviderID = providerIDFor(name)
	return c
}

// A disk's barrier is fixed when its VM boots, so a machine made before the
// class asked for another one is replaced, the way a changed image is.
func TestADurabilityChangeIsDrift(t *testing.T) {
	p := providerWith("power-loss", machineWith("m0", "os-crash"), machineWith("m1", "power-loss"))
	reason, err := p.IsDrifted(context.Background(), claimFor("m0"))
	if err != nil || reason != "NodeClassDurabilityChanged" {
		t.Errorf("m0: drift %q, %v; want NodeClassDurabilityChanged", reason, err)
	}
	if reason, _ := p.IsDrifted(context.Background(), claimFor("m1")); reason != "" {
		t.Errorf("m1 already matches and drifted: %q", reason)
	}
}

// A class that says nothing about durability leaves every machine alone,
// whatever it was made with.
func TestNoDurabilityIsNoDrift(t *testing.T) {
	p := providerWith("", machineWith("m0", "process-crash"))
	if reason, _ := p.IsDrifted(context.Background(), claimFor("m0")); reason != "" {
		t.Errorf("drifted with no durability asked for: %q", reason)
	}
}

func TestDurabilityComesFromTheEnvironment(t *testing.T) {
	t.Setenv("FERRY_MACHINE_DURABILITY", "os-crash")
	if got := configFromEnv().nodeClass().Spec.Durability; got != "os-crash" {
		t.Errorf("node class durability %q", got)
	}
}
