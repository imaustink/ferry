package main

// The reconcile loop: what a Machine says, made true.
//
// Deliberately a poll rather than an informer. There are a handful of machines
// on one Mac, each taking seconds to create, and a two-second list is both
// simpler to read and simpler to reason about than a cache with its own
// lifecycle. If this ever manages hundreds of machines it should become a
// proper informer; it does not today.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
)

var machineGVR = schema.GroupVersionResource{
	Group: "ferry.dev", Version: "v1alpha1", Resource: "machines",
}

// finalizer keeps a Machine's object alive until its VM is actually gone.
// Without it the resource disappears on delete and the machine is left running
// with nothing pointing at it.
const finalizer = "ferry.dev/machine"

type machine struct {
	name    string
	address string
	token   string
	podCIDR string
}

// machineSpec is what ferry-node serve reads out of the machines directory.
// Writing the file asks for a machine; removing it stops one.
type machineSpec struct {
	Name      string `json:"name"`
	Disk      string `json:"disk"`
	CPUs      int    `json:"cpus"`
	MemoryMiB int64  `json:"memoryMiB"`
	Token     string `json:"token"`
	PodCIDR   string `json:"podCIDR"`
	// Taints the kubelet registers the Node with, rather than ones patched on
	// once it is already schedulable -- see ensureProviderID for why the same
	// argument did not win for the mode label.
	Taints []string `json:"taints,omitempty"`
	// The root disk's barrier, from spec.durability; see diskSync. Empty
	// leaves it to ferry-node's own default, which is the cluster's.
	DiskSync string `json:"diskSync,omitempty"`
}

// diskSync is what a durability level means for a machine's root disk, in
// Virtualization.framework's terms:
//
//	power-loss     full   every guest flush is a full barrier on the Mac's SSD
//	os-crash       fsync  every guest flush is an fsync(2): survives the Mac
//	                      crashing, not the SSD losing power mid-write
//	process-crash  none   flushes return before the data leaves the Mac's
//	                      cache: survives ferry-node crashing, nothing more
//
// The same words as the cluster's own durability, plus the level between them
// that only a disk has: macOS's fsync(2) reaches the drive without flushing
// its cache, which is exactly what a machine got before it could choose.
func diskSync(durability string) (string, error) {
	switch durability {
	case "":
		return "", nil
	case "power-loss":
		return "full", nil
	case "os-crash":
		return "fsync", nil
	case "process-crash":
		return "none", nil
	}
	return "", fmt.Errorf("spec.durability %q: expected power-loss, os-crash or process-crash", durability)
}

// machineStatus is what it writes back.
type machineStatus struct {
	Name    string `json:"name"`
	Address string `json:"address"`
	Phase   string `json:"phase"`
	Message string `json:"message"`
}

// Pod CIDRs are not ferry's to allocate. kube-controller-manager hands each
// Node a slice of the cluster CIDR when it registers, every node's routes point
// at those slices, and a second allocator here produced pods with addresses no
// other node could reach. The machine is told nothing and reads its own from
// the API once it has registered; this only reports what was chosen.

type controller struct {
	kube     kubernetes.Interface
	dynamic  dynamic.Interface
	machines map[string]*machine
	// The cluster's default runtime as last read; see defaultruntime.go.
	policy string
}

func (c *controller) reconcileAll(ctx context.Context) error {
	// First, so a machine created below is born with the taint the current
	// default asks for rather than getting it a tick later.
	c.reconcileDefaultRuntime(ctx)

	list, err := c.dynamic.Resource(machineGVR).List(ctx, metav1.ListOptions{})
	if err != nil {
		return err
	}

	seen := map[string]bool{}
	for i := range list.Items {
		item := &list.Items[i]
		seen[item.GetName()] = true
		if err := c.reconcile(ctx, item); err != nil {
			log.Printf("machine %s: %v", item.GetName(), err)
		}
	}

	// A machine whose resource vanished without going through deletion -- the
	// finalizer makes this rare, but a controller that was not running when the
	// object was removed would otherwise leave the VM behind forever.
	for name, m := range c.machines {
		if !seen[name] {
			log.Printf("machine %s: resource is gone, stopping the VM", name)
			c.stop(m)
			delete(c.machines, name)
		}
	}
	return nil
}

func (c *controller) reconcile(ctx context.Context, item *unstructured.Unstructured) error {
	name := item.GetName()

	if item.GetDeletionTimestamp() != nil {
		return c.delete(ctx, item)
	}

	if !hasFinalizer(item) {
		item.SetFinalizers(append(item.GetFinalizers(), finalizer))
		updated, err := c.dynamic.Resource(machineGVR).Update(ctx, item, metav1.UpdateOptions{})
		if err != nil {
			return fmt.Errorf("adding finalizer: %w", err)
		}
		item = updated
	}

	if existing, running := c.machines[name]; running {
		// Already asked for. The remaining work is telling the cluster what the
		// node is doing, which is the Node object's business rather than the VM's.
		return c.updateStatus(ctx, item, existing)
	}
	return c.create(ctx, item)
}

func (c *controller) create(ctx context.Context, item *unstructured.Unstructured) error {
	name := item.GetName()
	log.Printf("machine %s: provisioning", name)
	_ = c.setStatus(ctx, item, map[string]any{"phase": "Provisioning"})

	cpus, memoryMiB, diskGiB, image, err := spec(item)
	if err != nil {
		_ = c.setStatus(ctx, item, map[string]any{"phase": "Failed", "message": err.Error()})
		return err
	}
	if image == "" {
		image = *baseImage
	}

	// Checked before anything is created: a bootstrap token and a disk clone
	// are side effects worth not leaving behind on a spec that cannot be met.
	if err := checkDisk(image, diskGiB); err != nil {
		_ = c.setStatus(ctx, item, map[string]any{"phase": "Failed", "message": err.Error()})
		return err
	}

	token, err := c.createBootstrapToken(ctx, name)
	if err != nil {
		return fmt.Errorf("bootstrap token: %w", err)
	}

	// A clone rather than a copy: on APFS this is instant and costs nothing
	// until the node writes, which is what makes a machine cheap to replace.
	disk := diskPath(name)
	_ = os.Remove(disk)
	if out, err := exec.Command("cp", "-c", image, disk).CombinedOutput(); err != nil {
		if out2, err2 := exec.Command("cp", image, disk).CombinedOutput(); err2 != nil {
			return fmt.Errorf("cloning %s: %v %s / %v %s", image, err, out, err2, out2)
		}
	}

	// Asking the server rather than starting a process: one vmnet network
	// belongs to the process that made it (experiment 19), so every machine has
	// to be hosted by the same one or they land on networks vmnet keeps apart.
	taints, _, _ := unstructured.NestedStringSlice(item.Object, "spec", "node", "taints")
	// At registration rather than patched on afterwards, for the reason the
	// taints field exists at all: a pod that names no RuntimeClass must not
	// get onto a machine in the moment before its taint arrives.
	taints = withRegistrationTaint(taints, c.policy)
	durability, _, _ := unstructured.NestedString(item.Object, "spec", "durability")
	sync, err := diskSync(durability)
	if err != nil {
		// The CRD's enum refuses this before it gets here; an older CRD
		// does not, and a disk opened with the wrong barrier is not a
		// thing to find out about later.
		_ = c.setStatus(ctx, item, map[string]any{"phase": "Failed", "message": err.Error()})
		return err
	}
	spec := machineSpec{
		Name: name, Disk: disk, CPUs: cpus, MemoryMiB: memoryMiB,
		Token: token, Taints: taints, DiskSync: sync,
	}
	body, err := json.MarshalIndent(spec, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(specFile(name), body, 0o644); err != nil {
		return fmt.Errorf("asking for machine %s: %w", name, err)
	}

	m := &machine{name: name, token: token}
	c.machines[name] = m
	if durability == "" {
		durability = "the cluster's"
	}
	log.Printf("machine %s: asked for %d cpu, %d MiB, disk from %s, durability %s",
		name, cpus, memoryMiB, image, durability)

	return c.updateStatus(ctx, item, m)
}

func (c *controller) delete(ctx context.Context, item *unstructured.Unstructured) error {
	name := item.GetName()
	if !hasFinalizer(item) {
		return nil
	}
	log.Printf("machine %s: deleting", name)
	_ = c.setStatus(ctx, item, map[string]any{"phase": "Deleting"})

	if m, ok := c.machines[name]; ok {
		c.stop(m)
		delete(c.machines, name)
	}

	// The Node outlives the VM otherwise, and the scheduler keeps placing pods
	// on a machine that no longer exists.
	if err := c.kube.CoreV1().Nodes().Delete(ctx, name, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		log.Printf("machine %s: deleting node: %v", name, err)
	}
	_ = c.kube.CoreV1().Secrets("kube-system").Delete(ctx, bootstrapSecretName(name), metav1.DeleteOptions{})
	_ = os.Remove(statusFile(name))
	_ = os.Remove(diskPath(name))
	_ = os.Remove(diskPath(name) + ".config.ext4")

	remaining := []string{}
	for _, f := range item.GetFinalizers() {
		if f != finalizer {
			remaining = append(remaining, f)
		}
	}
	item.SetFinalizers(remaining)
	_, err := c.dynamic.Resource(machineGVR).Update(ctx, item, metav1.UpdateOptions{})
	return err
}

// stop asks the server to let the machine go, which it does by noticing the
// spec file is gone.
func (c *controller) stop(m *machine) {
	_ = os.Remove(specFile(m.name))
}

// adopt takes back the machines a previous controller asked for.
//
// Without it a restart is destructive twice over: an empty map makes reconcile
// treat a running machine as new, and create() removes the live disk, clones
// the image over it and mints a fresh token -- so a controller crash would
// rebuild every node in the cluster. The finalizer exists to let a VM outlive
// control-plane churn, and this is the other half of that promise.
func (c *controller) adopt() error {
	entries, err := os.ReadDir(*machinesDir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		n := e.Name()
		if e.IsDir() || !strings.HasSuffix(n, ".json") || strings.HasSuffix(n, ".status.json") {
			continue
		}
		body, err := os.ReadFile(specFile(strings.TrimSuffix(n, ".json")))
		if err != nil {
			continue
		}
		var asked machineSpec
		if json.Unmarshal(body, &asked) != nil || asked.Name == "" {
			continue
		}
		c.machines[asked.Name] = &machine{name: asked.Name, token: asked.Token}
		log.Printf("machine %s: adopted, still running", asked.Name)
	}
	return nil
}

// checkDisk holds spec.disk to what a clone can actually deliver.
//
// A machine's disk is a clone of the image, and the image's ext4 is built
// without resize_inode, so it cannot be grown in place -- not online in the
// guest, not offline on the Mac. Truncating the file up would produce a disk
// that looks like the size asked for and holds the size of the image, which is
// worse than the silent no-op this field used to be. So a size that disagrees
// with the image is refused, and says how to get the one asked for.
func checkDisk(image string, gib int64) error {
	if gib <= 0 {
		return nil // unset: whatever the image is
	}
	info, err := os.Stat(image)
	if err != nil {
		return fmt.Errorf("reading image %s: %w", image, err)
	}
	const giB = 1024 * 1024 * 1024
	if have := info.Size() / giB; gib != have {
		return fmt.Errorf("spec.disk is %dGi but the image it clones is %dGi, and that filesystem cannot be resized in place; build one with `ferry-node build --size-gib %d` and point spec.image at it, or omit spec.disk to take the image's size",
			gib, have, gib)
	}
	return nil
}

// updateStatus reports what is true rather than what was asked for: the address
// comes from the machine once it has one, and the node reference only once the
// kubelet has actually registered.
func (c *controller) updateStatus(ctx context.Context, item *unstructured.Unstructured, m *machine) error {
	status := map[string]any{"phase": "Provisioning"}

	if m.address == "" {
		if body, err := os.ReadFile(statusFile(m.name)); err == nil {
			var reported machineStatus
			if json.Unmarshal(body, &reported) == nil {
				m.address = strings.SplitN(reported.Address, "/", 2)[0]
				if reported.Phase == "Failed" {
					// Without the phase this reads as Provisioning forever,
					// which is the one thing a machine that died is not.
					status["phase"] = "Failed"
					status["message"] = reported.Message
				}
			}
		}
	}
	if m.address != "" {
		status["address"] = m.address
	}

	if node, err := c.kube.CoreV1().Nodes().Get(ctx, m.name, metav1.GetOptions{}); err == nil {
		status["nodeRef"] = map[string]any{"name": node.Name}
		status["phase"] = "Running"
		c.ensureModeLabel(ctx, node)
		c.ensureProviderID(ctx, node)
		if node.Spec.PodCIDR != "" {
			m.podCIDR = node.Spec.PodCIDR
			status["podCIDR"] = node.Spec.PodCIDR
		}
		for _, condition := range node.Status.Conditions {
			if condition.Type == corev1.NodeReady && condition.Status == corev1.ConditionTrue {
				status["message"] = "node is Ready"
			}
		}
	}
	return c.setStatus(ctx, item, status)
}

// modeLabel says which of ferry's two modes a node is, and is how a pod picks
// between them: `nodeSelector: {ferry.dev/mode: shared}` for a kernel shared
// with its neighbours, `vm-per-pod` for one of its own. The Mac node sets
// vm-per-pod on its own kubelet; a machine's is set here.
const (
	modeLabel  = "ferry.dev/mode"
	modeShared = "shared"
	hostLabel  = "ferry.dev/host"
)

// Applied here rather than through the kubelet's --node-labels, which would be
// the race-free place to do it, because the kubelet inside a machine is
// configured from the kernel command line and adding a label there means
// threading it through ferry-machined, ferry-node, the boot arguments and
// init.sh for a value that is the same on every machine.
//
// The cost of that shortcut is a window between the node registering and the
// label arriving, up to one reconcile interval, in which a pod selecting
// `shared` will not schedule here. That is the safe direction: the label is
// missing rather than wrong, so the scheduler declines to place a pod rather
// than placing it somewhere it does not belong.
func (c *controller) ensureModeLabel(ctx context.Context, node *corev1.Node) {
	host := *hostNode
	if node.Labels[modeLabel] == modeShared && (host == "" || node.Labels[hostLabel] == host) {
		return
	}
	patch := fmt.Sprintf(`{"metadata":{"labels":{%q:%q}}}`, modeLabel, modeShared)
	if host != "" {
		patch = fmt.Sprintf(`{"metadata":{"labels":{%q:%q,%q:%q}}}`, modeLabel, modeShared, hostLabel, host)
	}
	if _, err := c.kube.CoreV1().Nodes().Patch(ctx, node.Name,
		types.StrategicMergePatchType, []byte(patch), metav1.PatchOptions{}); err != nil {
		// Not fatal: the machine is running and useful, it just will not match
		// a selector yet. Logged because a node that never gets the label is a
		// pod that never schedules, and that is hard to diagnose from outside.
		log.Printf("machine %s: could not label node %s: %v", node.Name, modeLabel, err)
	}
}

// providerIDPrefix is how a provisioner refers to a machine it asked for.
// ferry-karpenter builds the same string from the machine's name.
const providerIDPrefix = "ferry://"

// ensureProviderID gives the Node the identifier a provisioner finds it by.
//
// Karpenter creates a NodeClaim, ferry makes a machine, and the two are
// reconciled by matching spec.providerID -- so a Node without one is a claim
// that never registers. Karpenter waits, decides the machine failed to join,
// deletes it and asks for another, forever, while the node it is deleting sits
// there Ready with pods on it.
//
// The canonical place to set this is the kubelet's --provider-id, which for a
// machine means the guest's boot arguments and therefore a rebuilt node image.
// Doing it here instead is the same value by a cheaper route, and it is safe
// because the field is settable exactly once: Kubernetes rejects a change to a
// providerID that is already set, so this cannot fight anything.
func (c *controller) ensureProviderID(ctx context.Context, node *corev1.Node) {
	if node.Spec.ProviderID != "" {
		return
	}
	patch := fmt.Sprintf(`{"spec":{"providerID":%q}}`, providerIDPrefix+node.Name)
	if _, err := c.kube.CoreV1().Nodes().Patch(ctx, node.Name,
		types.StrategicMergePatchType, []byte(patch), metav1.PatchOptions{}); err != nil {
		log.Printf("machine %s: could not set providerID: %v", node.Name, err)
	}
}

func (c *controller) setStatus(ctx context.Context, item *unstructured.Unstructured, status map[string]any) error {
	current, _, _ := unstructured.NestedMap(item.Object, "status")
	if current == nil {
		current = map[string]any{}
	}
	changed := false
	for k, v := range status {
		if fmt.Sprint(current[k]) != fmt.Sprint(v) {
			changed = true
		}
		current[k] = v
	}
	if !changed {
		return nil
	}
	if err := unstructured.SetNestedMap(item.Object, current, "status"); err != nil {
		return err
	}
	_, err := c.dynamic.Resource(machineGVR).UpdateStatus(ctx, item, metav1.UpdateOptions{})
	return err
}

// spec reads what the machine asked for, with the API's defaults already
// applied by the server.
func spec(item *unstructured.Unstructured) (cpus int, memoryMiB int64, diskGiB int64, image string, err error) {
	cpus64, _, _ := unstructured.NestedInt64(item.Object, "spec", "cpus")
	cpus = int(cpus64)
	if cpus == 0 {
		cpus = 2
	}
	memory, _, _ := unstructured.NestedString(item.Object, "spec", "memory")
	if memory == "" {
		memory = "2Gi"
	}
	quantity, parseErr := resource.ParseQuantity(memory)
	if parseErr != nil {
		return 0, 0, 0, "", fmt.Errorf("spec.memory %q: %w", memory, parseErr)
	}
	memoryMiB = quantity.Value() / (1024 * 1024)

	// Left at zero when unset, which means "whatever the image is" rather than
	// a number this controller made up.
	if disk, _, _ := unstructured.NestedString(item.Object, "spec", "disk"); disk != "" {
		diskQuantity, parseErr := resource.ParseQuantity(disk)
		if parseErr != nil {
			return 0, 0, 0, "", fmt.Errorf("spec.disk %q: %w", disk, parseErr)
		}
		diskGiB = diskQuantity.Value() / (1024 * 1024 * 1024)
	}

	image, _, _ = unstructured.NestedString(item.Object, "spec", "image")
	return cpus, memoryMiB, diskGiB, image, nil
}

func hasFinalizer(item *unstructured.Unstructured) bool {
	for _, f := range item.GetFinalizers() {
		if f == finalizer {
			return true
		}
	}
	return false
}

func bootstrapSecretName(machine string) string {
	// The token id is derived from the machine's name so the secret is
	// recognisable and so a rebuild replaces its own token rather than adding
	// to a pile of them.
	return "bootstrap-token-" + tokenID(machine)
}

// tokenID is six lowercase alphanumerics, which is what Kubernetes requires of
// a bootstrap token id.
func tokenID(machine string) string {
	sum := 0
	for _, r := range machine {
		sum = sum*31 + int(r)
	}
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	id := make([]byte, 6)
	for i := range id {
		id[i] = alphabet[sum%len(alphabet)]
		sum /= len(alphabet)
		sum += i * 7
	}
	return string(id)
}

func (c *controller) createBootstrapToken(ctx context.Context, machine string) (string, error) {
	id := tokenID(machine)
	secretBytes := make([]byte, 8)
	if _, err := rand.Read(secretBytes); err != nil {
		return "", err
	}
	secret := hex.EncodeToString(secretBytes)

	name := bootstrapSecretName(machine)
	_ = c.kube.CoreV1().Secrets("kube-system").Delete(ctx, name, metav1.DeleteOptions{})
	_, err := c.kube.CoreV1().Secrets("kube-system").Create(ctx, &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "kube-system"},
		Type:       corev1.SecretTypeBootstrapToken,
		StringData: map[string]string{
			"token-id":                       id,
			"token-secret":                   secret,
			"usage-bootstrap-authentication": "true",
			"usage-bootstrap-signing":        "true",
			"auth-extra-groups":              "system:bootstrappers:ferry:default-node-token",
			"description":                    "ferry-machined, for machine " + machine,
		},
	}, metav1.CreateOptions{})
	if err != nil {
		return "", err
	}
	return id + "." + secret, nil
}

// ensureBootstrapRBAC grants a joining kubelet the right to ask for a
// certificate and to have that request approved. Without it a machine
// authenticates with its token and is then refused, which reads as a network
// problem and is not one.
func (c *controller) ensureBootstrapRBAC(ctx context.Context) error {
	bindings := []struct {
		name, clusterRole, group string
	}{
		{"ferry:node-bootstrapper", "system:node-bootstrapper", "system:bootstrappers:ferry:default-node-token"},
		{"ferry:node-autoapprove", "system:certificates.k8s.io:certificatesigningrequests:nodeclient", "system:bootstrappers:ferry:default-node-token"},
		{"ferry:node-autoapprove-renew", "system:certificates.k8s.io:certificatesigningrequests:selfnodeclient", "system:nodes"},
	}
	for _, b := range bindings {
		_, err := c.kube.RbacV1().ClusterRoleBindings().Create(ctx, &rbacv1.ClusterRoleBinding{
			ObjectMeta: metav1.ObjectMeta{Name: b.name},
			RoleRef: rbacv1.RoleRef{
				APIGroup: rbacv1.GroupName, Kind: "ClusterRole", Name: b.clusterRole,
			},
			Subjects: []rbacv1.Subject{{
				APIGroup: rbacv1.GroupName, Kind: "Group", Name: b.group,
			}},
		}, metav1.CreateOptions{})
		if err != nil && !apierrors.IsAlreadyExists(err) {
			return err
		}
	}
	return nil
}
