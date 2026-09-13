package main

// Keeps ferry-gpud's grants matching the pods that actually exist, and puts
// what the GPU has done where the cluster can see it.
//
// ferry-cri hands a grant back when the pod stops, which covers the ordinary
// case. It cannot cover the others: if ferry-gpud restarts it re-binds every
// socket it had, including ones whose pods were deleted while it was down, and
// nothing would ever release those -- the node's only GPU slot, held by a pod
// that no longer exists. ferry-cri cannot fix it either, since its own view of
// sandboxes does not survive a restart.
//
// What does know is the API server, and this already talks to it. So: any grant
// older than a grace period whose pod is gone, or finished, is revoked.
//
// The same pass writes each pod's GPU usage onto the pod as annotations.
// `kubectl top` will never show this -- it reads the kubelet's summary API,
// which knows about CPU and memory and nothing else -- so the pod object is the
// nearest place the cluster can see it.

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"strings"
	"time"

	v1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

// Long enough that a grant made for a pod the API has not caught up on is never
// mistaken for an orphan. Grants are made at CreateContainer, by which point the
// pod has existed for a while, so this is generous.
const gpuGrantGrace = 60 * time.Second

const (
	gpuSecondsAnnotation  = "ferry.dev/gpu-seconds"
	gpuQueuedAnnotation   = "ferry.dev/gpu-queued-seconds"
	gpuRequestsAnnotation = "ferry.dev/gpu-requests"
)

type gpuGrant struct {
	UID       string `json:"uid"`
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	GrantedAt string `json:"grantedAt"`
	Usage     struct {
		Requests      int     `json:"requests"`
		Failures      int     `json:"failures"`
		GPUSeconds    float64 `json:"gpuSeconds"`
		QueuedSeconds float64 `json:"queuedSeconds"`
		Yields        int     `json:"yields"`
	} `json:"usage"`
}

// reconcilePods revokes grants whose pods are gone and annotates the ones whose
// pods are still here.
func (g *gpuPublisher) reconcilePods(ctx context.Context) {
	grants, err := g.grants(ctx)
	if err != nil || len(grants) == 0 {
		return
	}

	pods, err := g.client.CoreV1().Pods("").List(ctx, metav1.ListOptions{
		FieldSelector: "spec.nodeName=" + g.nodeName,
	})
	if err != nil {
		// Without the list there is no way to tell an orphan from a live pod,
		// and revoking on a guess would take the GPU from something using it.
		return
	}

	live := make(map[string]*v1.Pod, len(pods.Items))
	for i := range pods.Items {
		pod := &pods.Items[i]
		if pod.Status.Phase == v1.PodSucceeded || pod.Status.Phase == v1.PodFailed {
			continue
		}
		live[string(pod.UID)] = pod
	}

	for _, grant := range grants {
		if pod, ok := live[grant.UID]; ok {
			g.annotate(ctx, pod, grant)
			continue
		}
		// Young grants are left alone: the pod may simply not be listed yet.
		if granted, err := time.Parse(time.RFC3339, grant.GrantedAt); err == nil {
			if time.Since(granted) < gpuGrantGrace {
				continue
			}
		}
		if g.revoke(ctx, grant.UID) {
			fmt.Printf("    gpu: revoked %s/%s -- its pod is gone\n", grant.Namespace, grant.Name)
		}
	}
}

func (g *gpuPublisher) grants(ctx context.Context) ([]gpuGrant, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://gpud/pods", nil)
	if err != nil {
		return nil, err
	}
	response, err := g.http.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("pods: HTTP %d", response.StatusCode)
	}
	var grants []gpuGrant
	if err := json.NewDecoder(response.Body).Decode(&grants); err != nil {
		return nil, err
	}
	return grants, nil
}

func (g *gpuPublisher) revoke(ctx context.Context, uid string) bool {
	request, err := http.NewRequestWithContext(
		ctx, http.MethodDelete, "http://gpud/pods/"+uid, nil)
	if err != nil {
		return false
	}
	response, err := g.http.Do(request)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	return response.StatusCode == http.StatusOK
}

// annotate writes this pod's GPU usage onto the pod, when it has moved enough to
// be worth an API call.
func (g *gpuPublisher) annotate(ctx context.Context, pod *v1.Pod, grant gpuGrant) {
	if g.annotationsDenied {
		return
	}
	seconds := fmt.Sprintf("%.1f", grant.Usage.GPUSeconds)
	queued := fmt.Sprintf("%.1f", grant.Usage.QueuedSeconds)
	requests := fmt.Sprintf("%d", grant.Usage.Requests)

	// A tenth of a second is the resolution here, so a pod doing nothing costs
	// no writes at all and a busy one costs one per tick.
	if pod.Annotations[gpuSecondsAnnotation] == seconds &&
		pod.Annotations[gpuQueuedAnnotation] == queued &&
		pod.Annotations[gpuRequestsAnnotation] == requests {
		return
	}
	if math.IsNaN(grant.Usage.GPUSeconds) {
		return
	}

	patch := fmt.Sprintf(
		`{"metadata":{"annotations":{%q:%q,%q:%q,%q:%q}}}`,
		gpuSecondsAnnotation, seconds,
		gpuQueuedAnnotation, queued,
		gpuRequestsAnnotation, requests)

	if _, err := g.client.CoreV1().Pods(pod.Namespace).Patch(
		ctx, pod.Name, types.MergePatchType, []byte(patch), metav1.PatchOptions{}); err != nil {
		// A node credential may not be allowed to write pod metadata. That is a
		// standing condition, not a transient failure, so stop asking rather
		// than logging it every ten seconds forever.
		if apierrors.IsForbidden(err) {
			g.annotationsDenied = true
			fmt.Fprintf(os.Stderr,
				"gpu: not permitted to annotate pods; usage stays on ferry-gpud's socket\n")
			return
		}
		if !apierrors.IsNotFound(err) && !strings.Contains(err.Error(), "context canceled") {
			fmt.Fprintf(os.Stderr, "gpu: could not annotate %s/%s: %v\n",
				pod.Namespace, pod.Name, err)
		}
	}
}
