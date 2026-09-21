//go:build darwin

/*
Copyright 2024 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// The NewProxier call only, because its signature is the one thing in
// ferry-proxyd that moves between minors. v1.34 through v1.36 take every knob
// as a positional argument; v1.37 collapses them into a
// KubeProxyConfiguration, so that minor has a shim of its own.
package main

import (
	"context"
	"net"
	"time"

	v1 "k8s.io/api/core/v1"
	"k8s.io/kubernetes/pkg/proxy/nftables"
	proxyutil "k8s.io/kubernetes/pkg/proxy/util"
)

func ferryNewProxier(ctx context.Context, nodeName string, nodeIP net.IP, syncPeriod time.Duration) (*nftables.Proxier, error) {
	// Traffic policies distinguish local from remote endpoints by node. Every
	// pod here is its own machine, so nothing is "local" in that sense and the
	// no-op detector is the honest answer.
	return nftables.NewProxier(ctx,
		v1.IPv4Protocol,
		syncPeriod,
		time.Second,
		false, // masqueradeAll: only hairpins need it, which kube-proxy marks itself
		14,    // masqueradeBit, kube-proxy's default
		proxyutil.NewNoOpLocalDetector(),
		nodeName,
		nodeIP,
		nil, nil, nil,
		false,
	)
}
