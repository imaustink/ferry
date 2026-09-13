package main

// Where the other nodes' switches are.
//
// ferry's pod network is one flat segment carried by a switch in each node's
// ferry-cri, and those switches reach each other over UDP. Every node therefore
// needs the list of the others -- on this Mac and on any other.
//
// The cluster already knows who the nodes are, so nothing new has to be invented
// to distribute it: each node writes its own relay endpoint onto its Node object
// and reads everyone else's back. A node that joins is a Node that appears, and
// a node that leaves stops being one.

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

const relayAnnotation = "ferry.dev/relay-endpoint"

type peerPublisher struct {
	client   kubernetes.Interface
	nodeName string
	endpoint string
	file     string
}

func newPeerPublisher(kubeconfig, nodeName, endpoint, file string) (*peerPublisher, error) {
	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		return nil, fmt.Errorf("read kubeconfig: %w", err)
	}
	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("build client: %w", err)
	}
	return &peerPublisher{client: client, nodeName: nodeName, endpoint: endpoint, file: file}, nil
}

// run advertises this node's endpoint and keeps the peers file current. It polls
// rather than watches: the list changes when someone runs 'ferry node add' or
// 'ferry join', which is rare, and a watch here would be machinery for nothing.
func (p *peerPublisher) run(ctx context.Context) {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	var last string
	for {
		if err := p.advertise(ctx); err != nil {
			fmt.Fprintf(os.Stderr, "peers: could not advertise %s: %v\n", p.endpoint, err)
		}
		if listed, err := p.collect(ctx); err == nil {
			joined := strings.Join(listed, "\n") + "\n"
			if joined != last {
				if err := os.WriteFile(p.file, []byte(joined), 0o644); err == nil {
					last = joined
					fmt.Printf("    peers: %s\n", summarise(listed))
				}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// advertise puts this node's endpoint on its own Node object. A merge patch so
// it never fights the kubelet over the rest of the object.
func (p *peerPublisher) advertise(ctx context.Context) error {
	patch := fmt.Sprintf(`{"metadata":{"annotations":{%q:%q}}}`, relayAnnotation, p.endpoint)
	_, err := p.client.CoreV1().Nodes().Patch(
		ctx, p.nodeName, types.MergePatchType, []byte(patch), metav1.PatchOptions{})
	return err
}

// collect returns every node's endpoint, including this one -- ferry-cri drops
// its own, and having it in the file makes the cluster's shape obvious from the
// outside.
func (p *peerPublisher) collect(ctx context.Context) ([]string, error) {
	nodes, err := p.client.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, err
	}
	var listed []string
	for _, node := range nodes.Items {
		if endpoint := node.Annotations[relayAnnotation]; endpoint != "" {
			listed = append(listed, endpoint)
		}
	}
	sort.Strings(listed)
	return listed, nil
}

func summarise(listed []string) string {
	if len(listed) == 0 {
		return "none"
	}
	return strings.Join(listed, ", ")
}
