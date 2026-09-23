package main

import (
	"encoding/json"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	corelisters "k8s.io/client-go/listers/core/v1"
	networkinglisters "k8s.io/client-go/listers/networking/v1"
	"k8s.io/client-go/tools/cache"
)

// cluster is two nodes, each with its slice, and whatever pods and policies a
// test adds.
func newCompiler(t *testing.T, objects ...any) *compiler {
	t.Helper()
	index := func() cache.Indexer {
		return cache.NewIndexer(cache.MetaNamespaceKeyFunc,
			cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
	}
	pods, policies, namespaces, nodes := index(), index(), index(), index()
	for _, name := range []string{"default", "other"} {
		_ = namespaces.Add(&corev1.Namespace{ObjectMeta: metav1.ObjectMeta{
			Name: name, Labels: map[string]string{"kubernetes.io/metadata.name": name}}})
	}
	_ = nodes.Add(&corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "a"}, Spec: corev1.NodeSpec{PodCIDR: "10.244.0.0/24"}})
	_ = nodes.Add(&corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "b"}, Spec: corev1.NodeSpec{PodCIDR: "10.244.1.0/24"}})
	for _, object := range objects {
		switch o := object.(type) {
		case *corev1.Pod:
			_ = pods.Add(o)
		case *networkingv1.NetworkPolicy:
			_ = policies.Add(o)
		}
	}
	return &compiler{
		clusterCIDR: "10.244.0.0/16",
		pods:        corelisters.NewPodLister(pods),
		policies:    networkinglisters.NewNetworkPolicyLister(policies),
		namespaces:  corelisters.NewNamespaceLister(namespaces),
		nodes:       corelisters.NewNodeLister(nodes),
	}
}

func pod(name, namespace, node, ip string, labels map[string]string, ports ...corev1.ContainerPort) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace, Labels: labels},
		Spec: corev1.PodSpec{NodeName: node, Containers: []corev1.Container{
			{Name: "c", Ports: ports}}},
		Status: corev1.PodStatus{PodIP: ip},
	}
}

func policy(name string, spec networkingv1.NetworkPolicySpec) *networkingv1.NetworkPolicy {
	return &networkingv1.NetworkPolicy{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"}, Spec: spec}
}

var web = map[string]string{"app": "web"}

func selectWeb() metav1.LabelSelector { return metav1.LabelSelector{MatchLabels: web} }

func tcp(port int32) networkingv1.NetworkPolicyPort {
	p := intstr.FromInt32(port)
	return networkingv1.NetworkPolicyPort{Port: &p}
}

// section returns the nft script for one pod address.
func section(t *testing.T, c *compiler, ip string) string {
	t.Helper()
	rules, _ := c.render()
	_, after, ok := strings.Cut(rules, "## "+ip+"\n")
	if !ok {
		t.Fatalf("no section for %s in:\n%s", ip, rules)
	}
	body, _, _ := strings.Cut(after, "## ")
	return body
}

func edgeOf(t *testing.T, c *compiler) edgeDocument {
	t.Helper()
	_, document := c.render()
	var out edgeDocument
	if err := json.Unmarshal(document, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func mustContain(t *testing.T, text string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(text, w) {
			t.Errorf("missing %q in:\n%s", w, text)
		}
	}
}

func mustNotContain(t *testing.T, text string, unwanted ...string) {
	t.Helper()
	for _, u := range unwanted {
		if strings.Contains(text, u) {
			t.Errorf("unexpected %q in:\n%s", u, text)
		}
	}
}

func TestUnselectedPodIsOpen(t *testing.T) {
	c := newCompiler(t, pod("web", "default", "a", "10.244.0.5", web))
	got := section(t, c, "10.244.0.5")
	if strings.TrimSpace(got) != "add table ip ferry-netpol\ndelete table ip ferry-netpol" {
		t.Errorf("an unselected pod should only clear its table, got:\n%s", got)
	}
	if len(edgeOf(t, c).Pods) != 0 {
		t.Error("an unselected pod should not be policed at the edge")
	}
}

// Deny-all used to accept anything from outside the cluster CIDR and anything
// from any node's address. Now only the pod itself, return traffic and its own
// node get through.
func TestDenyAllExemptsOnlyTheLocalNode(t *testing.T) {
	c := newCompiler(t,
		pod("web", "default", "b", "10.244.1.5", web),
		policy("deny", networkingv1.NetworkPolicySpec{
			PodSelector: metav1.LabelSelector{}, PolicyTypes: []networkingv1.PolicyType{"Ingress"}}))
	got := section(t, c, "10.244.1.5")
	mustContain(t, got,
		`input iifname "lo" accept`,
		"input ct state established,related accept",
		"input ip saddr { 10.244.1.1 } accept",
		"add rule ip ferry-netpol input drop")
	mustNotContain(t, got, "10.244.0.1", "!= 10.244.0.0/16")

	edge := edgeOf(t, c)
	p, ok := edge.Pods["10.244.1.5"]
	if !ok || len(p.Rules) != 0 {
		t.Errorf("deny-all should be an empty allow-list at the edge, got %+v", edge)
	}
}

// The gateway follows the pod's address, not the node's podCIDR: a node
// re-added under an old name keeps a podCIDR its runtime no longer uses.
func TestGatewayFollowsThePodAddress(t *testing.T) {
	c := newCompiler(t,
		pod("stale", "default", "b", "10.244.2.7", web), // b's podCIDR says 10.244.1.0/24
		pod("unscheduled", "default", "", "10.244.3.9", web),
		policy("deny", networkingv1.NetworkPolicySpec{PodSelector: metav1.LabelSelector{}}))
	mustContain(t, section(t, c, "10.244.2.7"), "input ip saddr { 10.244.2.1 } accept")
	mustContain(t, section(t, c, "10.244.3.9"), "input ip saddr { 10.244.3.1 } accept")
}

func TestIPBlockExcept(t *testing.T) {
	c := newCompiler(t,
		pod("web", "default", "a", "10.244.0.5", web),
		policy("lan", networkingv1.NetworkPolicySpec{
			PodSelector: selectWeb(),
			Ingress: []networkingv1.NetworkPolicyIngressRule{{
				From: []networkingv1.NetworkPolicyPeer{
					{IPBlock: &networkingv1.IPBlock{CIDR: "192.168.1.7/24", Except: []string{"192.168.1.29/32"}}},
					{IPBlock: &networkingv1.IPBlock{CIDR: "172.16.0.0/12"}},
					{IPBlock: &networkingv1.IPBlock{CIDR: "fd00::/8"}},
				},
				Ports: []networkingv1.NetworkPolicyPort{tcp(80)},
			}},
		}))
	got := section(t, c, "10.244.0.5")
	mustContain(t, got,
		"input ip saddr { 172.16.0.0/12 } tcp dport 80 accept",
		"input ip saddr 192.168.1.0/24 ip saddr != { 192.168.1.29/32 } tcp dport 80 accept")
	mustNotContain(t, got, "fd00", "192.168.1.7")

	rules := edgeOf(t, c).Pods["10.244.0.5"].Rules
	if len(rules) != 1 || len(rules[0].From) != 3 {
		t.Fatalf("edge rules: %+v", rules)
	}
	var sawExcept, sawV6 bool
	for _, block := range rules[0].From {
		sawExcept = sawExcept || (block.CIDR == "192.168.1.0/24" && len(block.Except) == 1)
		sawV6 = sawV6 || block.CIDR == "fd00::/8"
	}
	if !sawExcept || !sawV6 {
		t.Errorf("edge should keep the exception and the IPv6 block: %+v", rules[0].From)
	}
}

func TestNamedPortsResolveAgainstThePod(t *testing.T) {
	http := intstr.FromString("http")
	missing := intstr.FromString("nope")
	c := newCompiler(t,
		pod("web", "default", "a", "10.244.0.5", web, corev1.ContainerPort{Name: "http", ContainerPort: 8080}),
		policy("named", networkingv1.NetworkPolicySpec{
			PodSelector: selectWeb(),
			Ingress: []networkingv1.NetworkPolicyIngressRule{
				{Ports: []networkingv1.NetworkPolicyPort{{Port: &http}}},
				{Ports: []networkingv1.NetworkPolicyPort{{Port: &missing}}},
			},
		}))
	got := section(t, c, "10.244.0.5")
	mustContain(t, got, "input tcp dport 8080 accept")
	mustNotContain(t, got, "http", "nope", "dport 80 ")
	rules := edgeOf(t, c).Pods["10.244.0.5"].Rules
	if len(rules) != 1 || !rules[0].All || rules[0].Ports[0].Port != 8080 {
		t.Errorf("a port name that resolves to nothing should allow nothing: %+v", rules)
	}
}

func TestEndPortAndProtocols(t *testing.T) {
	udp, sctp := corev1.ProtocolUDP, corev1.ProtocolSCTP
	low, end := intstr.FromInt32(1000), int32(2000)
	c := newCompiler(t,
		pod("web", "default", "a", "10.244.0.5", web),
		policy("range", networkingv1.NetworkPolicySpec{
			PodSelector: selectWeb(),
			Ingress: []networkingv1.NetworkPolicyIngressRule{{Ports: []networkingv1.NetworkPolicyPort{
				{Port: &low, EndPort: &end},
				{Protocol: &udp},
				{Protocol: &sctp, Port: &low},
			}}},
		}))
	mustContain(t, section(t, c, "10.244.0.5"),
		"input tcp dport 1000-2000 accept",
		"input meta l4proto udp accept",
		"input sctp dport 1000 accept")
}

func TestPodSelectorPeersAndHostPorts(t *testing.T) {
	c := newCompiler(t,
		pod("web", "default", "a", "10.244.0.5", web,
			corev1.ContainerPort{ContainerPort: 80, HostPort: 8080}),
		pod("client", "default", "b", "10.244.1.9", map[string]string{"role": "client"}),
		pod("stranger", "other", "b", "10.244.1.10", map[string]string{"role": "client"}),
		policy("clients", networkingv1.NetworkPolicySpec{
			PodSelector: selectWeb(),
			Ingress: []networkingv1.NetworkPolicyIngressRule{{
				From: []networkingv1.NetworkPolicyPeer{{PodSelector: &metav1.LabelSelector{
					MatchLabels: map[string]string{"role": "client"}}}},
			}},
		}))
	got := section(t, c, "10.244.0.5")
	mustContain(t, got, "input ip saddr { 10.244.1.9 } accept")
	mustNotContain(t, got, "10.244.1.10")

	p := edgeOf(t, c).Pods["10.244.0.5"]
	if len(p.Rules) != 1 || len(p.Rules[0].From) != 1 || p.Rules[0].From[0].CIDR != "10.244.1.9/32" {
		t.Errorf("edge rule: %+v", p.Rules)
	}
	if p.HostPorts["tcp/8080"] != 80 {
		t.Errorf("hostPort mapping: %+v", p.HostPorts)
	}
}

// A rule naming peers that do not exist allows nothing, at the pod and at the
// edge -- not everything.
func TestPeersThatMatchNothing(t *testing.T) {
	c := newCompiler(t,
		pod("web", "default", "a", "10.244.0.5", web),
		policy("nobody", networkingv1.NetworkPolicySpec{
			PodSelector: selectWeb(),
			Ingress: []networkingv1.NetworkPolicyIngressRule{{
				From: []networkingv1.NetworkPolicyPeer{{PodSelector: &metav1.LabelSelector{
					MatchLabels: map[string]string{"role": "ghost"}}}},
			}},
		}))
	got := section(t, c, "10.244.0.5")
	lines := strings.Count(got, " accept\n")
	if lines != 3 { // loopback, established, the node
		t.Errorf("want only the guards, got:\n%s", got)
	}
	if rules := edgeOf(t, c).Pods["10.244.0.5"].Rules; len(rules) != 0 {
		t.Errorf("edge rules: %+v", rules)
	}
}

func TestEgressNamedPortIsThePeersPort(t *testing.T) {
	dns := intstr.FromString("dns")
	udp := corev1.ProtocolUDP
	c := newCompiler(t,
		pod("web", "default", "a", "10.244.0.5", web),
		pod("coredns", "other", "b", "10.244.1.2", map[string]string{"k8s-app": "kube-dns"},
			corev1.ContainerPort{Name: "dns", ContainerPort: 5353, Protocol: udp}),
		policy("dns-only", networkingv1.NetworkPolicySpec{
			PodSelector: selectWeb(),
			PolicyTypes: []networkingv1.PolicyType{"Egress"},
			Egress: []networkingv1.NetworkPolicyEgressRule{{
				To: []networkingv1.NetworkPolicyPeer{{
					NamespaceSelector: &metav1.LabelSelector{},
					PodSelector:       &metav1.LabelSelector{MatchLabels: map[string]string{"k8s-app": "kube-dns"}},
				}},
				Ports: []networkingv1.NetworkPolicyPort{{Protocol: &udp, Port: &dns}},
			}},
		}))
	got := section(t, c, "10.244.0.5")
	mustContain(t, got,
		`output oifname "lo" accept`,
		"output ip daddr { 10.244.1.2 } udp dport 5353 accept",
		"add rule ip ferry-netpol output drop")
	mustNotContain(t, got, "chain ip ferry-netpol input")
	if len(edgeOf(t, c).Pods) != 0 {
		t.Error("an egress-only policy should not be policed at the edge")
	}
}

func TestRenderIsDeterministic(t *testing.T) {
	objects := []any{
		pod("web", "default", "a", "10.244.0.5", web, corev1.ContainerPort{ContainerPort: 80, HostPort: 80}),
		pod("web2", "default", "b", "10.244.1.5", web, corev1.ContainerPort{ContainerPort: 81, HostPort: 81}),
		policy("deny", networkingv1.NetworkPolicySpec{PodSelector: metav1.LabelSelector{}}),
	}
	r1, e1 := newCompiler(t, objects...).render()
	for i := 0; i < 20; i++ {
		r2, e2 := newCompiler(t, objects...).render()
		if r1 != r2 || string(e1) != string(e2) {
			t.Fatal("render must not depend on map order, or every pass republishes")
		}
	}
}
