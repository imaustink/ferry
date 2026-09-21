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
// ferry-proxyd that moves between minors.
//
// v1.37 stopped taking the knobs positionally and takes a
// KubeProxyConfiguration instead. Every value below is the one the older call
// passed by hand, so the proxier is configured exactly as it was on v1.36 --
// only the shape of the telling changed. The fields are set explicitly rather
// than defaulted through the scheme: the scheme's defaulters live behind
// linux build tags, and reaching for them is how a darwin build ends up
// depending on the half of kube-proxy that cannot compile here.
package main

import (
	"context"
	"net"
	"time"

	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	kubeproxyconfig "k8s.io/kubernetes/pkg/proxy/apis/config"
	"k8s.io/kubernetes/pkg/proxy/nftables"
	proxyutil "k8s.io/kubernetes/pkg/proxy/util"
)

func ferryNewProxier(ctx context.Context, nodeName string, nodeIP net.IP, syncPeriod time.Duration) (*nftables.Proxier, error) {
	masqueradeBit := int32(14) // kube-proxy's default

	config := &kubeproxyconfig.KubeProxyConfiguration{
		SyncPeriod:    metav1.Duration{Duration: syncPeriod},
		MinSyncPeriod: metav1.Duration{Duration: time.Second},
		// nil means every node address, which is upstream's default and what
		// the positional call passed before this field had a home.
		NodePortAddresses: nil,
		Linux: kubeproxyconfig.KubeProxyLinuxConfiguration{
			// Only hairpins need it, which kube-proxy marks itself.
			MasqueradeAll: false,
		},
		NFTables: kubeproxyconfig.KubeProxyNFTablesConfiguration{
			MasqueradeBit: &masqueradeBit,
		},
	}

	// Traffic policies distinguish local from remote endpoints by node. Every
	// pod here is its own machine, so nothing is "local" in that sense and the
	// no-op detector is the honest answer.
	return nftables.NewProxier(ctx,
		config,
		v1.IPv4Protocol,
		proxyutil.NewNoOpLocalDetector(),
		nodeName,
		nodeIP,
		nil, // recorder: nothing here consumes Events
		nil, // healthzServer: ferry serves the ruleset, not kube-proxy's health
		false,
	)
}
