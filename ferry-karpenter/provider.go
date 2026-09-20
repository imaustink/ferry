package main

// ferry as a Karpenter cloud provider.
//
// Karpenter's model is: pods will not fit, so pick a shape and ask the provider
// for a node of it; later, that node is empty, so ask the provider to take it
// away. A cloud provider turns that into an API call. ferry turns it into a
// Machine object, which ferry-machined already knows how to make into a VM.
//
// So this is a translation layer and almost nothing else. The one place it has
// to think is capacity: a cloud region does not run out because you asked for
// one more node, and a Mac does.

import (
	"cmp"
	"context"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/awslabs/operatorpkg/status"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	"sigs.k8s.io/karpenter/pkg/cloudprovider"
	"sigs.k8s.io/karpenter/pkg/scheduling"
)

var machineGVR = schema.GroupVersionResource{
	Group: group, Version: version, Resource: "machines",
}

// providerID is how Karpenter refers to a node it created. ferry's machines are
// named, and the name is enough to find one again.
const providerIDPrefix = "ferry://"

func providerIDFor(name string) string { return providerIDPrefix + name }

func nameFromProviderID(id string) (string, bool) {
	if !strings.HasPrefix(id, providerIDPrefix) {
		return "", false
	}
	name := strings.TrimPrefix(id, providerIDPrefix)
	return name, name != ""
}

type Provider struct {
	dynamic dynamic.Interface
	// The NodeClass every machine is made from. One per installation: the node
	// image and what the Mac will spend are facts about the machine ferry is
	// running on, not about a workload.
	nodeClass *FerryNodeClass
	// Held across the whole of Create: read the budget, decide, write the
	// Machine. See the comment there.
	creating sync.Mutex
}

func NewProvider(d dynamic.Interface, n *FerryNodeClass) *Provider {
	return &Provider{dynamic: d, nodeClass: n}
}

func (p *Provider) Name() string { return "ferry" }

func (p *Provider) GetSupportedNodeClasses() []status.Object {
	return []status.Object{&FerryNodeClass{}}
}

// RepairPolicies is empty on purpose. Karpenter can be told to replace a node
// whose conditions say it is unhealthy; on one Mac, a machine that has gone bad
// is more likely to be a symptom of the host being out of something than of one
// VM being sick, and replacing it automatically turns that into a loop. Delete
// the Machine by hand and the controller makes a new one.
func (p *Provider) RepairPolicies() []cloudprovider.RepairPolicy { return nil }

// --- the catalogue --------------------------------------------------------

func (p *Provider) GetInstanceTypes(ctx context.Context, _ *karpv1.NodePool) ([]*cloudprovider.InstanceType, error) {
	b := p.nodeClass.bounds()
	committed, err := p.committed(ctx)
	if err != nil {
		return nil, err
	}

	var out []*cloudprovider.InstanceType
	for _, s := range b.shapes() {
		// Karpenter wants every instance type returned even when it cannot be
		// had right now, with availability expressed on the offering. That is
		// what lets it explain "this pod does not fit" rather than behaving as
		// though the shape never existed.
		available := b.fits(committed, s)
		out = append(out, &cloudprovider.InstanceType{
			Name:         s.name(),
			Capacity:     s.capacity(p.nodeClass.maxPods()),
			Requirements: requirementsFor(s),
			Offerings: cloudprovider.Offerings{{
				Requirements: scheduling.NewRequirements(
					scheduling.NewRequirement(karpv1.CapacityTypeLabelKey, corev1.NodeSelectorOpIn, karpv1.CapacityTypeOnDemand),
					scheduling.NewRequirement(corev1.LabelTopologyZone, corev1.NodeSelectorOpIn, zone),
				),
				// Everything costs the same here in money, because it does:
				// the memory comes from one Mac either way. A non-zero price
				// keeps Karpenter's cheapest-fit logic choosing the smallest
				// shape that works rather than an arbitrary one, and it is the
				// same number `Create` orders candidates by.
				Price:     s.cost(),
				Available: available,
			}},
			Overhead: &cloudprovider.InstanceTypeOverhead{
				// The guest's own kernel, containerd and kubelet. Measured at
				// roughly 2.3 GiB for an idle single-node cluster in
				// experiment 21; most of that is the control plane's, so this
				// is the node's share rather than the whole figure.
				KubeReserved: corev1.ResourceList{
					corev1.ResourceCPU:    *resource.NewMilliQuantity(250, resource.DecimalSI),
					corev1.ResourceMemory: *resource.NewQuantity(512*1024*1024, resource.BinarySI),
				},
			},
		})
	}
	return out, nil
}

// One zone, because there is one Mac. Karpenter requires the well-known labels
// to be defined even when they only ever take one value.
const zone = "ferry"

func requirementsFor(s shape) scheduling.Requirements {
	return scheduling.NewRequirements(
		scheduling.NewRequirement(corev1.LabelInstanceTypeStable, corev1.NodeSelectorOpIn, s.name()),
		scheduling.NewRequirement(corev1.LabelTopologyZone, corev1.NodeSelectorOpIn, zone),
		scheduling.NewRequirement(corev1.LabelTopologyRegion, corev1.NodeSelectorOpIn, zone),
		scheduling.NewRequirement(corev1.LabelOSStable, corev1.NodeSelectorOpIn, string(corev1.Linux)),
		scheduling.NewRequirement(corev1.LabelArchStable, corev1.NodeSelectorOpIn, karpv1.ArchitectureArm64),
		scheduling.NewRequirement(karpv1.CapacityTypeLabelKey, corev1.NodeSelectorOpIn, karpv1.CapacityTypeOnDemand),
		// What mode 2 is for. A node made here shares its kernel between pods,
		// and a pod says so with nodeSelector.
		scheduling.NewRequirement(modeLabel, corev1.NodeSelectorOpIn, modeShared),
	)
}

const (
	modeLabel  = "ferry.dev/mode"
	modeShared = "shared"
)

// --- the budget -----------------------------------------------------------

// committed is what the machines that already exist have been promised. Read
// from the Machine objects rather than from the nodes, because a machine that
// is still booting has taken its memory from the Mac without having registered
// a node yet, and provisioning against the node list would double-spend during
// exactly the window Karpenter is most likely to ask again.
func (p *Provider) committed(ctx context.Context) (shape, error) {
	list, err := p.dynamic.Resource(machineGVR).List(ctx, metav1.ListOptions{})
	if err != nil {
		return shape{}, fmt.Errorf("listing machines: %w", err)
	}
	var total shape
	for i := range list.Items {
		cpus, memoryGi := machineShape(&list.Items[i])
		total.cpus += cpus
		total.memoryGi += memoryGi
	}
	return total, nil
}

func machineShape(m *unstructured.Unstructured) (cpus, memoryGi int64) {
	cpus, _, _ = unstructured.NestedInt64(m.Object, "spec", "cpus")
	mem, _, _ := unstructured.NestedString(m.Object, "spec", "memory")
	if q, err := resource.ParseQuantity(mem); err == nil {
		memoryGi = q.Value() / gibibyte
	}
	return cpus, memoryGi
}

// --- the lifecycle --------------------------------------------------------

func (p *Provider) Create(ctx context.Context, claim *karpv1.NodeClaim) (*karpv1.NodeClaim, error) {
	candidates := shapesFromRequirements(claim)
	if len(candidates) == 0 {
		return nil, fmt.Errorf("node claim %s names no instance type this provider offers", claim.Name)
	}

	// Read the budget, decide against it, and write the Machine without letting
	// another Create in between.
	//
	// Karpenter launches a batch of NodeClaims through
	// workqueue.ParallelizeUntil, one goroutine per claim, so several Creates
	// run at once whenever more than one pod is pending -- which is the normal
	// case rather than a rare one. Each would read the same `committed`, each
	// would find room for itself, and every one of them would be allowed: the
	// budget holds against one machine at a time and against nothing else. The
	// lock makes `committed` mean what the next line assumes it means.
	//
	// It serialises provisioning to one machine at a time. That is the right
	// trade here: the API round trip is local, and the thing being protected is
	// a Mac that has no headroom to discover its limit by exceeding it.
	p.creating.Lock()
	defer p.creating.Unlock()

	committed, err := p.committed(ctx)
	if err != nil {
		return nil, err
	}
	b := p.nodeClass.bounds()

	// The cheapest candidate that still fits, not the first one.
	//
	// Karpenter offers every compatible instance type in the claim's
	// requirements and leaves the choice to the provider; the values arrive
	// through Requirement.NodeSelectorRequirement, which serialises them with
	// sets.List -- sorted by name, with the price ordering thrown away. So the
	// first value is the lexicographically smallest name. With the shipped
	// defaults that happens to be the smallest shape; with FERRY_MACHINE_MIN_CPUS=4
	// it is ferry-4cpu-16gi, and a pod asking for 100m and 128Mi would take the
	// largest machine in the catalogue and the whole budget with it.
	s, ok := cheapestThatFits(b, committed, candidates)
	if !ok {
		// The error that matters. Karpenter treats this as "that shape is not
		// available right now", marks it unavailable for a while and stops
		// asking; any other error is a failure it retries, which against a
		// hypervisor is a loop that makes and destroys nothing at speed.
		return nil, cloudprovider.NewInsufficientCapacityError(fmt.Errorf(
			"the Mac has committed %d cpus and %d GiB to machines; %s would exceed the limit of %d cpus and %d GiB",
			committed.cpus, committed.memoryGi, candidates[0].name(),
			b.limitCPUs, b.limitMemoryGi))
	}

	machine := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": group + "/" + version,
		"kind":       "Machine",
		"metadata": map[string]any{
			"name": claim.Name,
			"labels": map[string]any{
				karpv1.NodePoolLabelKey: claim.Labels[karpv1.NodePoolLabelKey],
			},
		},
		"spec": map[string]any{
			"cpus":   s.cpus,
			"memory": fmt.Sprintf("%dGi", s.memoryGi),
			"node": map[string]any{
				"taints": registrationTaints(claim),
			},
		},
	}}
	if img := p.nodeClass.Spec.Image; img != "" {
		_ = unstructured.SetNestedField(machine.Object, img, "spec", "image")
	}

	if _, err := p.dynamic.Resource(machineGVR).Create(ctx, machine, metav1.CreateOptions{}); err != nil {
		return nil, fmt.Errorf("creating machine %s: %w", claim.Name, err)
	}

	out := claim.DeepCopy()
	out.Status.ProviderID = providerIDFor(claim.Name)
	out.Status.Capacity = s.capacity(p.nodeClass.maxPods())
	out.Status.Allocatable = s.capacity(p.nodeClass.maxPods())
	if out.Labels == nil {
		out.Labels = map[string]string{}
	}
	out.Labels[corev1.LabelInstanceTypeStable] = s.name()
	out.Labels[corev1.LabelTopologyZone] = zone
	out.Labels[corev1.LabelArchStable] = karpv1.ArchitectureArm64
	out.Labels[corev1.LabelOSStable] = string(corev1.Linux)
	out.Labels[karpv1.CapacityTypeLabelKey] = karpv1.CapacityTypeOnDemand
	return out, nil
}

func (p *Provider) Delete(ctx context.Context, claim *karpv1.NodeClaim) error {
	name, ok := nameFromProviderID(claim.Status.ProviderID)
	if !ok {
		name = claim.Name
	}
	err := p.dynamic.Resource(machineGVR).Delete(ctx, name, metav1.DeleteOptions{})
	if err != nil {
		if isNotFound(err) {
			// Karpenter retries Delete until it is told the thing is gone, so
			// this is the success case rather than an error.
			return cloudprovider.NewNodeClaimNotFoundError(fmt.Errorf("machine %s is already gone", name))
		}
		return fmt.Errorf("deleting machine %s: %w", name, err)
	}
	return nil
}

func (p *Provider) Get(ctx context.Context, providerID string) (*karpv1.NodeClaim, error) {
	name, ok := nameFromProviderID(providerID)
	if !ok {
		return nil, cloudprovider.NewNodeClaimNotFoundError(fmt.Errorf("%q is not a ferry provider id", providerID))
	}
	m, err := p.dynamic.Resource(machineGVR).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		if isNotFound(err) {
			return nil, cloudprovider.NewNodeClaimNotFoundError(fmt.Errorf("machine %s not found", name))
		}
		return nil, err
	}
	return p.claimFor(m), nil
}

func (p *Provider) List(ctx context.Context) ([]*karpv1.NodeClaim, error) {
	list, err := p.dynamic.Resource(machineGVR).List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("listing machines: %w", err)
	}
	out := make([]*karpv1.NodeClaim, 0, len(list.Items))
	for i := range list.Items {
		out = append(out, p.claimFor(&list.Items[i]))
	}
	return out, nil
}

func (p *Provider) claimFor(m *unstructured.Unstructured) *karpv1.NodeClaim {
	cpus, memoryGi := machineShape(m)
	s := shape{cpus: cpus, memoryGi: memoryGi}
	claim := &karpv1.NodeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:   m.GetName(),
			Labels: map[string]string{},
		},
	}
	for k, v := range m.GetLabels() {
		claim.Labels[k] = v
	}
	claim.Labels[corev1.LabelInstanceTypeStable] = s.name()
	claim.Labels[corev1.LabelTopologyZone] = zone
	claim.Labels[corev1.LabelArchStable] = karpv1.ArchitectureArm64
	claim.Labels[corev1.LabelOSStable] = string(corev1.Linux)
	claim.Labels[karpv1.CapacityTypeLabelKey] = karpv1.CapacityTypeOnDemand
	claim.Status.ProviderID = providerIDFor(m.GetName())
	claim.Status.Capacity = s.capacity(p.nodeClass.maxPods())
	claim.Status.Allocatable = s.capacity(p.nodeClass.maxPods())
	return claim
}

// IsDrifted says whether a machine no longer matches what the NodeClass asks
// for. Only the image is checked: cpus and memory cannot be changed on a
// running VM (experiment 14), so a machine of the wrong size is replaced by
// Karpenter's own consolidation rather than by drift.
func (p *Provider) IsDrifted(ctx context.Context, claim *karpv1.NodeClaim) (cloudprovider.DriftReason, error) {
	name, ok := nameFromProviderID(claim.Status.ProviderID)
	if !ok {
		return "", nil
	}
	m, err := p.dynamic.Resource(machineGVR).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		if isNotFound(err) {
			return "", nil
		}
		return "", err
	}
	want := p.nodeClass.Spec.Image
	if want == "" {
		return "", nil
	}
	got, _, _ := unstructured.NestedString(m.Object, "spec", "image")
	if got != want {
		return cloudprovider.DriftReason("NodeClassImageChanged"), nil
	}
	return "", nil
}

// --- helpers --------------------------------------------------------------

// shapesFromRequirements is every shape the claim says it would accept,
// cheapest first. Plural on purpose: the choice among them is the provider's,
// and the order they arrive in does not express it -- see `Create`.
//
// Only In requirements are read. A NotIn on the instance type lists shapes the
// claim has ruled out, and reading its values as candidates would pick one of
// exactly the shapes it asked not to have.
func shapesFromRequirements(claim *karpv1.NodeClaim) []shape {
	var out []shape
	for _, r := range claim.Spec.Requirements {
		if r.Key != corev1.LabelInstanceTypeStable || r.Operator != corev1.NodeSelectorOpIn {
			continue
		}
		for _, v := range r.Values {
			if s, ok := parseShapeName(v); ok {
				out = append(out, s)
			}
		}
	}
	if len(out) == 0 {
		// Nothing usable in the requirements: a claim written by hand, or one
		// Karpenter has already resolved down to a label.
		if v, ok := claim.Labels[corev1.LabelInstanceTypeStable]; ok {
			if s, ok := parseShapeName(v); ok {
				out = append(out, s)
			}
		}
	}
	slices.SortFunc(out, func(a, b shape) int { return cmp.Compare(a.cost(), b.cost()) })
	return out
}

// cheapestThatFits walks candidates in cost order and returns the first the
// budget can still afford. Ordered rather than filtered-then-minimised because
// the caller wants the answer and the name of the shape it wanted when there
// is none.
func cheapestThatFits(b bounds, committed shape, candidates []shape) (shape, bool) {
	for _, s := range candidates {
		if b.fits(committed, s) {
			return s, true
		}
	}
	return shape{}, false
}

// parseShapeName turns ferry-4cpu-8gi back into the shape it names. The name is
// the only thing Karpenter carries between choosing a type and asking for it,
// so it has to be reversible.
func parseShapeName(name string) (shape, bool) {
	parts := strings.Split(name, "-")
	if len(parts) != 3 || parts[0] != "ferry" {
		return shape{}, false
	}
	cpus, err := strconv.ParseInt(strings.TrimSuffix(parts[1], "cpu"), 10, 64)
	if err != nil {
		return shape{}, false
	}
	mem, err := strconv.ParseInt(strings.TrimSuffix(parts[2], "gi"), 10, 64)
	if err != nil {
		return shape{}, false
	}
	return shape{cpus: cpus, memoryGi: mem}, true
}

// isNotFound asks the API machinery rather than the error text.
//
// A substring match on "not found" also matches an admission or conversion
// webhook reporting a missing service, an RBAC message, and a discovery
// failure. In `Delete` that reads as success: Karpenter is told the machine is
// gone, drops the NodeClaim, and nothing is left that would ever reap the VM
// still running behind it.
func isNotFound(err error) bool {
	return apierrors.IsNotFound(err)
}

// Checked at compile time rather than discovered at startup: an interface this
// large is easy to implement almost correctly.
var _ cloudprovider.CloudProvider = (*Provider)(nil)

// registrationTaints is what the machine's kubelet registers its Node with.
//
// The first is Karpenter's own, and it is the point of this function.
// Registration expects a node it asked for to arrive already carrying
// karpenter.sh/unregistered:NoExecute, and removes it once it has synced the
// NodePool's labels on. Without it Karpenter logs "missing taint prevents
// registration-related race conditions" and carries on, so machines work -- but
// the window it names is real: between the kubelet registering and the sync
// finishing, a pod with no nodeSelector can land on a node Karpenter has not
// finished describing.
//
// A taint cannot be patched on afterwards and mean anything, because by then
// the node is already schedulable. It has to come from the kubelet, so it
// travels the whole way down: NodeClaim to Machine.spec.node.taints to
// ferry-node to the kernel command line to --register-with-taints.
//
// Only machines the provisioner creates get it. A Machine written by hand has
// no NodeClaim behind it and nothing that would ever take the taint off, and a
// node nothing can schedule to is a worse failure than the race.
//
// The NodePool's own taints ride along for the same reason. Karpenter would
// sync those onto the node too, and just as late.
func registrationTaints(claim *karpv1.NodeClaim) []string {
	out := []string{taintString(karpv1.UnregisteredNoExecuteTaint)}
	for _, t := range append(slices.Clone(claim.Spec.Taints), claim.Spec.StartupTaints...) {
		out = append(out, taintString(t))
	}
	return out
}

// taintString writes a taint the way the kubelet's --register-with-taints reads
// it. The value is omitted when empty rather than written as `key=:Effect`:
// both parse, and the shorter one is what `kubectl taint` prints back.
func taintString(t corev1.Taint) string {
	if t.Value == "" {
		return fmt.Sprintf("%s:%s", t.Key, t.Effect)
	}
	return fmt.Sprintf("%s=%s:%s", t.Key, t.Value, t.Effect)
}
