package main

// Keeps ferry.dev/gpu on this node matching what ferry-gpud will actually do.
//
// `ferry up` patches the capacity on once, which is enough until something
// moves: the Node object gets recreated and the resource goes with it, or
// ferry-gpud dies and the node keeps advertising a GPU that nothing serves. The
// second is the bad one -- the scheduler places a pod, ferry-cri cannot get it a
// socket, and CreateContainer fails on a node that looked fine.
//
// So the source of truth is the daemon itself, asked over its control socket
// rather than assumed from a flag. If it answers, its limit is what the node
// advertises. If it stops answering, the resource comes off and pods stay
// Pending, which is the correct way to be out of GPUs.
//
// No device plugin: the kubelet merges into status.capacity rather than
// replacing it, so a patch sticks. See docs/GPU.md.

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"time"

	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

// The resource name, JSON Patch escaped: "/" is ~1 in a pointer.
const gpuCapacityPath = "/status/capacity/ferry.dev~1gpu"

// How many consecutive failures before the resource is withdrawn. The daemon
// being restarted by hand should not flap the node's capacity; it staying dead
// should not go unnoticed either.
const gpuFailuresBeforeWithdrawal = 3

type gpuPublisher struct {
	client   kubernetes.Interface
	nodeName string
	// ferry-gpud's control socket. Empty disables all of this.
	socket   string
	http     *http.Client
	failures int
	// What the node currently advertises, so an unchanged value costs nothing.
	advertised string
}

func newGPUPublisher(kubeconfig, nodeName, socket string) (*gpuPublisher, error) {
	if socket == "" {
		return nil, nil
	}
	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		return nil, fmt.Errorf("read kubeconfig: %w", err)
	}
	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("build client: %w", err)
	}
	return &gpuPublisher{
		client:   client,
		nodeName: nodeName,
		socket:   socket,
		http: &http.Client{
			Timeout: 2 * time.Second,
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					var d net.Dialer
					return d.DialContext(ctx, "unix", socket)
				},
			},
		},
	}, nil
}

func (g *gpuPublisher) run(ctx context.Context) {
	if g == nil {
		return
	}
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		g.reconcile(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (g *gpuPublisher) reconcile(ctx context.Context) {
	limit, err := g.limit(ctx)
	if err != nil {
		g.failures++
		if g.failures < gpuFailuresBeforeWithdrawal {
			return
		}
		if g.advertised != "" {
			fmt.Fprintf(os.Stderr, "gpu: ferry-gpud unreachable (%v); withdrawing ferry.dev/gpu\n", err)
		}
		g.set(ctx, "")
		return
	}
	g.failures = 0
	g.set(ctx, fmt.Sprintf("%d", limit))
}

// limit asks the daemon how many pods it will serve.
func (g *gpuPublisher) limit(ctx context.Context) (int, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://gpud/capacity", nil)
	if err != nil {
		return 0, err
	}
	response, err := g.http.Do(request)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("capacity: HTTP %d", response.StatusCode)
	}
	var body struct {
		Limit int `json:"limit"`
	}
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		return 0, err
	}
	if body.Limit < 0 {
		return 0, fmt.Errorf("capacity: nonsensical limit %d", body.Limit)
	}
	return body.Limit, nil
}

// set makes the node say `value`, or removes the resource when value is empty.
// It reads first so an unchanged capacity costs one GET rather than a write.
func (g *gpuPublisher) set(ctx context.Context, value string) {
	node, err := g.client.CoreV1().Nodes().Get(ctx, g.nodeName, metav1.GetOptions{})
	if err != nil {
		return
	}
	current := ""
	if quantity, ok := node.Status.Capacity[v1.ResourceName(gpuResource)]; ok {
		current = quantity.String()
	}
	g.advertised = current
	if current == value {
		return
	}

	var patch string
	switch {
	case value == "":
		// Removing a path that is not there is an error, so only ask when it is.
		if current == "" {
			return
		}
		patch = fmt.Sprintf(`[{"op":"remove","path":%q}]`, gpuCapacityPath)
	default:
		patch = fmt.Sprintf(`[{"op":"add","path":%q,"value":%q}]`, gpuCapacityPath, value)
	}

	if _, err := g.client.CoreV1().Nodes().Patch(
		ctx, g.nodeName, types.JSONPatchType, []byte(patch),
		metav1.PatchOptions{}, "status"); err != nil {
		fmt.Fprintf(os.Stderr, "gpu: could not set %s=%q: %v\n", gpuResource, value, err)
		return
	}
	g.advertised = value
	if value == "" {
		fmt.Printf("    gpu: withdrew %s\n", gpuResource)
	} else {
		fmt.Printf("    gpu: node advertises %s: %s\n", gpuResource, value)
	}
}
