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

// knftables' netlink backend, stood down on darwin.
//
// v1.37 is the first minor to vendor knftables v0.0.22, which added netlink.go
// with no build tag. That file talks to the kernel through
// github.com/google/nftables, whose xt package reads unix.NFPROTO_IPV4 and
// friends -- constants darwin's x/sys/unix does not declare. So the whole
// knftables package stopped compiling on darwin, and took ferry-proxyd with
// it. build-kubelet.sh narrows netlink.go to linux; this stands in for it.
//
// Nothing is lost. newNetlinkAdapter is reached only when the caller passes
// UseNetlink, an experimental opt-in the proxier never sets, and there is no
// kernel nftables on a Mac to reach either way -- ferryNFTablesInterface hands
// the proxier knftables' recording Fake, which is the whole point of building
// kube-proxy's rule generation here.
package knftables

import (
	"context"
	"fmt"
)

type netlink interface {
	List(ctx context.Context, objectType string) ([]string, error)
	ListAll(ctx context.Context) (map[string][]string, error)
}

func newNetlinkAdapter(_ Family, _ string) (netlink, error) {
	return nil, fmt.Errorf("knftables: netlink is not available on darwin")
}
