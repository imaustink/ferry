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
	"strconv"
	"strings"
	"syscall"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
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
	cmd     *exec.Cmd
	address string
	token   string
}

type controller struct {
	kube     kubernetes.Interface
	dynamic  dynamic.Interface
	machines map[string]*machine
}

func (c *controller) reconcileAll(ctx context.Context) error {
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

	existing, running := c.machines[name]
	if running && existing.cmd.ProcessState == nil {
		// Already up. The remaining work is telling the cluster what the node
		// is doing, which is the Node object's business rather than the VM's.
		return c.updateStatus(ctx, item, existing)
	}
	if running {
		log.Printf("machine %s: the VM exited, rebuilding", name)
		delete(c.machines, name)
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

	logFile, err := os.Create(logPath(name))
	if err != nil {
		return fmt.Errorf("log file: %w", err)
	}
	_ = os.Remove(statusPath(name))

	cmd := exec.Command(*ferryNode, "run",
		"--disk", disk,
		"--kernel", *kernel,
		"--ca", *caFile,
		"--node-name", name,
		"--api-server", *apiServer,
		"--token", token,
		"--cpus", strconv.Itoa(cpus),
		"--memory-mib", strconv.FormatInt(memoryMiB, 10),
		"--cluster-dns", *clusterDNS,
		"--status-file", statusPath(name),
	)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("starting ferry-node: %w", err)
	}
	// Reaped here so ProcessState is set when it exits, which is how the next
	// pass notices a machine that died.
	go func() { _ = cmd.Wait() }()

	m := &machine{name: name, cmd: cmd, token: token}
	c.machines[name] = m
	log.Printf("machine %s: %d cpu, %d MiB, %d GiB disk, pid %d",
		name, cpus, memoryMiB, diskGiB, cmd.Process.Pid)

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
	_ = os.Remove(diskPath(name))
	_ = os.Remove(diskPath(name) + ".config.ext4")
	_ = os.Remove(statusPath(name))

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

func (c *controller) stop(m *machine) {
	if m.cmd == nil || m.cmd.Process == nil {
		return
	}
	_ = m.cmd.Process.Signal(syscall.SIGTERM)
	_ = m.cmd.Process.Kill()
}

func (c *controller) shutdown() {
	for _, m := range c.machines {
		c.stop(m)
	}
}

// updateStatus reports what is true rather than what was asked for: the address
// comes from the machine once it has one, and the node reference only once the
// kubelet has actually registered.
func (c *controller) updateStatus(ctx context.Context, item *unstructured.Unstructured, m *machine) error {
	status := map[string]any{"phase": "Provisioning"}

	if m.address == "" {
		if body, err := os.ReadFile(statusPath(m.name)); err == nil {
			var reported struct {
				Address string `json:"address"`
			}
			if json.Unmarshal(body, &reported) == nil {
				m.address = strings.SplitN(reported.Address, "/", 2)[0]
			}
		}
	}
	if m.address != "" {
		status["address"] = m.address
	}

	if node, err := c.kube.CoreV1().Nodes().Get(ctx, m.name, metav1.GetOptions{}); err == nil {
		status["nodeRef"] = map[string]any{"name": node.Name}
		status["phase"] = "Running"
		for _, condition := range node.Status.Conditions {
			if condition.Type == corev1.NodeReady && condition.Status == corev1.ConditionTrue {
				status["message"] = "node is Ready"
			}
		}
	}
	return c.setStatus(ctx, item, status)
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

	disk, _, _ := unstructured.NestedString(item.Object, "spec", "disk")
	if disk == "" {
		disk = "8Gi"
	}
	diskQuantity, parseErr := resource.ParseQuantity(disk)
	if parseErr != nil {
		return 0, 0, 0, "", fmt.Errorf("spec.disk %q: %w", disk, parseErr)
	}
	diskGiB = diskQuantity.Value() / (1024 * 1024 * 1024)

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
