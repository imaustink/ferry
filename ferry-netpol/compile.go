package main

import (
	"encoding/json"
	"fmt"
	"net"
	"sort"
	"strconv"
	"strings"

	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/util/intstr"
	corelisters "k8s.io/client-go/listers/core/v1"
	networkinglisters "k8s.io/client-go/listers/networking/v1"
)

type compiler struct {
	clusterCIDR string
	policies    networkinglisters.NetworkPolicyLister
	pods        corelisters.PodLister
	namespaces  corelisters.NamespaceLister
	nodes       corelisters.NodeLister
}

// peers is who a rule lets in (or out to), resolved from selectors.
type peers struct {
	all       bool      // no peers named: everyone
	addresses []string  // pod addresses, and ipBlocks with no exceptions
	blocks    []ipBlock // ipBlocks with exceptions, which need a rule each
}

type ipBlock struct {
	CIDR   string   `json:"cidr"`
	Except []string `json:"except,omitempty"`
}

// portRange is one entry of a rule's ports. Port 0 is every port of the
// protocol; EndPort 0 is a single port.
type portRange struct {
	Protocol string `json:"protocol"`
	Port     int32  `json:"port,omitempty"`
	EndPort  int32  `json:"endPort,omitempty"`
}

// rule is one ingress or egress rule with its selectors and named ports turned
// into addresses and numbers. anyPort is an empty ports list; an empty ranges
// list with anyPort false is a rule whose named ports resolved to nothing, and
// it matches nothing.
type rule struct {
	peers   peers
	ranges  []portRange
	anyPort bool
}

// edgePod is what the host edge needs to police one pod: the ingress rules
// that apply to it, and how its hostPorts map onto container ports, since a
// policy names the port the container listens on and the edge dials the pod at
// the host port.
//
// A pod appears in the edge document only if some policy isolates it for
// ingress. Rules is then the whole allow-list, and an empty one denies
// everything.
type edgePod struct {
	Rules     []edgeRule       `json:"rules"`
	HostPorts map[string]int32 `json:"hostPorts,omitempty"` // "tcp/8080" -> 80
}

type edgeRule struct {
	All   bool        `json:"all,omitempty"`
	From  []ipBlock   `json:"from,omitempty"`
	Ports []portRange `json:"ports,omitempty"` // empty: every port
}

type edgeDocument struct {
	Pods map[string]edgePod `json:"pods"`
}

// slicePrefixes maps each node to the prefix length of the slice it hands out.
func (c *compiler) slicePrefixes() map[string]int {
	out := map[string]int{}
	nodes, err := c.nodes.List(labels.Everything())
	if err != nil {
		return out
	}
	for _, node := range nodes {
		if _, network, err := net.ParseCIDR(node.Spec.PodCIDR); err == nil && network.IP.To4() != nil {
			out[node.Name], _ = network.Mask.Size()
		}
	}
	return out
}

// render produces one section per pod, which ferry-cri splits up and applies to
// the pod it belongs to. Pods no policy mentions get a section too -- an empty
// one -- because removing the last policy has to open the traffic back up.
//
// It also produces the edge document ferry-proxy polices connections from
// outside the cluster with. Both come from the same resolved rules, so the pod
// and the edge cannot disagree about what a policy means.
//
// This is the whole cluster's, which is what this Mac's own nodes are served.
// Another Mac is served its own nodes' part of the same compilation.
func (c *compiler) render() (string, []byte) {
	r, err := c.compile()
	if err != nil {
		return "", nil
	}
	return r.rules(nil), r.edge(nil)
}

// compiled is one pod's part of a compilation.
type compiled struct {
	node    string
	address string
	nft     string
	edge    *edgePod // nil: nothing isolates it for ingress
}

// rendered is a compilation, in address order, split by pod so that it can be
// served a node at a time.
type rendered []compiled

// rules is the pod rules for the nodes keep accepts, or for every node.
func (r rendered) rules(keep func(node string) bool) string {
	var out strings.Builder
	for _, p := range r {
		if keep == nil || keep(p.node) {
			fmt.Fprintf(&out, "## %s\n%s\n", p.address, p.nft)
		}
	}
	return out.String()
}

// edge is the edge document for the nodes keep accepts, or for every node.
func (r rendered) edge(keep func(node string) bool) []byte {
	document := edgeDocument{Pods: map[string]edgePod{}}
	for _, p := range r {
		if p.edge != nil && (keep == nil || keep(p.node)) {
			document.Pods[p.address] = *p.edge
		}
	}
	out, _ := json.Marshal(document) // map keys are sorted, so equal input is equal output
	return out
}

// compile fails rather than returning less: an empty compilation is a cluster
// with no policies, and publishing one opens every pod.
func (c *compiler) compile() (rendered, error) {
	pods, err := c.pods.List(labels.Everything())
	if err != nil {
		return nil, err
	}
	policies, err := c.policies.List(labels.Everything())
	if err != nil {
		return nil, err
	}
	prefixes := c.slicePrefixes()

	var out rendered
	sort.Slice(pods, func(i, j int) bool { return pods[i].Status.PodIP < pods[j].Status.PodIP })
	for _, pod := range pods {
		if pod.Status.PodIP == "" || pod.Spec.HostNetwork {
			continue
		}
		ingress, egress, isolated := c.rulesFor(pod, policies)
		p := compiled{node: pod.Spec.NodeName, address: pod.Status.PodIP,
			nft: c.nftFor(pod, prefixes, ingress, egress, isolated)}
		if isolated.ingress {
			e := edgeFor(pod, ingress)
			p.edge = &e
		}
		out = append(out, p)
	}
	return out, nil
}

type isolation struct{ ingress, egress bool }

// rulesFor is the whole of NetworkPolicy for one pod.
//
// The shape is the API's own: a pod that no policy selects is unrestricted, and
// a pod that any policy selects for a direction is default-deny in that
// direction with the union of every matching rule allowed back in.
func (c *compiler) rulesFor(pod *corev1.Pod, all []*networkingv1.NetworkPolicy) (ingress, egress []rule, isolated isolation) {
	for _, policy := range all {
		if policy.Namespace != pod.Namespace || !c.selects(policy, pod) {
			continue
		}
		for _, direction := range policyDirections(policy) {
			switch direction {
			case networkingv1.PolicyTypeIngress:
				isolated.ingress = true
				for _, r := range policy.Spec.Ingress {
					ranges, anyPort := resolvePorts(r.Ports, func(name, protocol string) []int32 {
						return namedPorts([]*corev1.Pod{pod}, name, protocol)
					})
					ingress = append(ingress, rule{c.peerAddresses(policy.Namespace, r.From), ranges, anyPort})
				}
			case networkingv1.PolicyTypeEgress:
				isolated.egress = true
				for _, r := range policy.Spec.Egress {
					// An egress rule's named port is the *peer's* port, so it
					// means whatever number the peers it names give that name.
					ranges, anyPort := resolvePorts(r.Ports, func(name, protocol string) []int32 {
						return namedPorts(c.peerPods(policy.Namespace, r.To), name, protocol)
					})
					egress = append(egress, rule{c.peerAddresses(policy.Namespace, r.To), ranges, anyPort})
				}
			}
		}
	}
	return ingress, egress, isolated
}

func (c *compiler) nftFor(pod *corev1.Pod, prefixes map[string]int,
	ingress, egress []rule, isolated isolation) string {

	var b strings.Builder
	// Replace wholesale, so a policy that goes away takes its rules with it.
	b.WriteString("add table ip ferry-netpol\n")
	b.WriteString("delete table ip ferry-netpol\n")
	if !isolated.ingress && !isolated.egress {
		return b.String() // nothing selects this pod: no filtering at all
	}
	b.WriteString("add table ip ferry-netpol\n")

	if isolated.ingress {
		b.WriteString(`add chain ip ferry-netpol input { type filter hook input priority 0 ; policy accept ; }` + "\n")
		writeIngressGuards(&b, localGateway(pod, prefixes))
		for _, r := range ingress {
			writeAllow(&b, "input", "saddr", r)
		}
		b.WriteString(`add rule ip ferry-netpol input drop` + "\n")
	}

	if isolated.egress {
		b.WriteString(`add chain ip ferry-netpol output { type filter hook output priority 0 ; policy accept ; }` + "\n")
		writeEgressGuards(&b)
		for _, r := range egress {
			writeAllow(&b, "output", "daddr", r)
		}
		b.WriteString(`add rule ip ferry-netpol output drop` + "\n")
	}
	return b.String()
}

// localGateway is the address of the node the pod runs on, which is exempt
// from ingress policy.
//
// A node sits on the pod network at the first address of the slice it hands
// its pods, and a pod's address is in that slice: a pod at 10.244.1.7 on a /24
// is probed from 10.244.1.1. That address is inside the cluster CIDR, so it
// cannot be told apart from pod traffic by prefix alone.
//
// It is worked out from the pod's own address rather than from the node's
// podCIDR, because the two can disagree: a node re-added under an old name
// keeps the Node object, and the podCIDR on it, while its runtime takes a
// different slice. Measured: podCIDR 10.244.1.0/24, pods on 10.244.2.x, and
// every probe dropped under deny-all. The node supplies only the slice's size.
func localGateway(pod *corev1.Pod, prefixes map[string]int) []string {
	ip := net.ParseIP(pod.Status.PodIP).To4()
	if ip == nil {
		return nil
	}
	size, ok := prefixes[pod.Spec.NodeName]
	if !ok || size > 30 {
		size = 24
	}
	gateway := ip.Mask(net.CIDRMask(size, 32))
	gateway[3]++
	return []string{gateway.String()}
}

// writeIngressGuards exempts three things from an ingress policy.
//
// The pod talking to itself, over loopback or its own address, which a policy
// cannot restrict: containers in a pod share one network stack, and a sidecar
// is not a peer. Return traffic, because a policy describes who may start a conversation, not
// who may answer. And the pod's own node -- the kubelet's health probes, the
// API server reaching a webhook or an aggregated API, a developer's curl from
// the Mac. Dropping those does not isolate the pod, it takes it down, because a
// failed probe restarts the container. Cilium and Calico make the same
// exception for the local host.
//
// What the exemption must not cover is traffic that merely *passes through*
// the node. ferry-proxy dials pods from the node's address on behalf of every
// NodePort, LoadBalancer and hostPort client, and a pod cannot tell those from
// a probe. So the edge enforces the same rules against the client's real
// address before it dials (ferry-proxy/policy.go), from the edge document
// rendered alongside this. Only the pod's *own* node is exempt here; another
// node's address is a peer like any other, which is what the API says.
//
// It used to be written as "anything that did not arrive on eth1", on the
// reasoning that eth1 is the cluster switch and eth0 is the Mac. That is true of
// where the Mac's traffic comes from and false of where pod traffic does: two
// pods on the *same* node reach each other over eth0, on the kernel datapath,
// because each node's slice is a route the guest resolves directly. So the guard
// exempted every same-node conversation. It then became "anything outside the
// cluster CIDR, or any node's address", which let every client of the edge in
// and made an ipBlock for an outside network mean nothing.
func writeIngressGuards(b *strings.Builder, gateways []string) {
	b.WriteString("add rule ip ferry-netpol input iifname \"lo\" accept\n")
	b.WriteString("add rule ip ferry-netpol input ct state established,related accept\n")
	if len(gateways) > 0 {
		fmt.Fprintf(b, "add rule ip ferry-netpol input ip saddr { %s } accept\n",
			strings.Join(gateways, ", "))
	}
}

// writeEgressGuards exempts return traffic and the pod talking to itself.
//
// Loopback used to be missing here, so a deny-all egress policy cut a pod off
// from its own localhost, and a sidecar from the container beside it.
//
// An egress policy in Kubernetes restricts everything the pod initiates,
// including traffic to the internet, so there is no interface exemption here.
// A deny-all egress policy really does deny everything -- which also means a pod
// under one cannot reach cluster DNS unless the policy says so. That surprises
// people, and it is what the API asks for.
func writeEgressGuards(b *strings.Builder) {
	b.WriteString("add rule ip ferry-netpol output oifname \"lo\" accept\n")
	b.WriteString("add rule ip ferry-netpol output ct state established,related accept\n")
}

func writeAllow(b *strings.Builder, chain, match string, r rule) {
	var matches []string
	switch {
	case r.peers.all:
		matches = []string{""}
	default:
		if v4 := ipv4Only(r.peers.addresses); len(v4) > 0 {
			matches = append(matches, fmt.Sprintf("ip %s { %s } ", match, strings.Join(v4, ", ")))
		}
		for _, block := range r.peers.blocks {
			if !isIPv4(block.CIDR) {
				continue // cannot match anything in an ip table
			}
			m := fmt.Sprintf("ip %s %s ", match, block.CIDR)
			if except := ipv4Only(block.Except); len(except) > 0 {
				m += fmt.Sprintf("ip %s != { %s } ", match, strings.Join(except, ", "))
			}
			matches = append(matches, m)
		}
	}
	if len(matches) == 0 {
		return // the rule names peers and none exist, so it allows nothing
	}

	var ports []string
	if r.anyPort {
		ports = []string{""}
	}
	for _, p := range r.ranges {
		switch {
		case p.Port == 0:
			ports = append(ports, fmt.Sprintf("meta l4proto %s ", p.Protocol))
		case p.EndPort > p.Port:
			ports = append(ports, fmt.Sprintf("%s dport %d-%d ", p.Protocol, p.Port, p.EndPort))
		default:
			ports = append(ports, fmt.Sprintf("%s dport %d ", p.Protocol, p.Port))
		}
	}
	for _, m := range matches {
		for _, p := range ports {
			fmt.Fprintf(b, "add rule ip ferry-netpol %s %s%saccept\n", chain, m, p)
		}
	}
}

// edgeFor turns a pod's ingress rules into what ferry-proxy checks. Addresses
// become single-host blocks so the edge has one shape to match.
func edgeFor(pod *corev1.Pod, ingress []rule) edgePod {
	out := edgePod{Rules: []edgeRule{}}
	for _, r := range ingress {
		if !r.anyPort && len(r.ranges) == 0 {
			continue
		}
		e := edgeRule{All: r.peers.all, Ports: r.ranges}
		if !r.peers.all {
			for _, address := range r.peers.addresses {
				e.From = append(e.From, ipBlock{CIDR: hostPrefix(address)})
			}
			e.From = append(e.From, r.peers.blocks...)
			if len(e.From) == 0 {
				continue
			}
		}
		out.Rules = append(out.Rules, e)
	}
	for _, container := range append(append([]corev1.Container{}, pod.Spec.InitContainers...), pod.Spec.Containers...) {
		for _, port := range container.Ports {
			if port.HostPort == 0 {
				continue
			}
			if out.HostPorts == nil {
				out.HostPorts = map[string]int32{}
			}
			out.HostPorts[protocolOf(port.Protocol)+"/"+strconv.Itoa(int(port.HostPort))] = port.ContainerPort
		}
	}
	return out
}

// resolvePorts turns a rule's ports into numbers. A named port becomes every
// number it currently names, and one that names nothing is dropped, which is
// the API's meaning: it matches no traffic. Before this, a name went to nft as
// written, and nft read it from /etc/services -- so "http" meant 80 whatever
// the container called port 8080.
func resolvePorts(ports []networkingv1.NetworkPolicyPort, named func(name, protocol string) []int32) ([]portRange, bool) {
	if len(ports) == 0 {
		return nil, true
	}
	var out []portRange
	for _, port := range ports {
		protocol := "tcp"
		if port.Protocol != nil {
			protocol = protocolOf(*port.Protocol)
		}
		switch {
		case port.Port == nil:
			out = append(out, portRange{Protocol: protocol})
		case port.Port.Type == intstr.String:
			for _, number := range named(port.Port.StrVal, protocol) {
				out = append(out, portRange{Protocol: protocol, Port: number})
			}
		default:
			r := portRange{Protocol: protocol, Port: port.Port.IntVal}
			if port.EndPort != nil && *port.EndPort > r.Port {
				r.EndPort = *port.EndPort
			}
			out = append(out, r)
		}
	}
	return out, false
}

func namedPorts(pods []*corev1.Pod, name, protocol string) []int32 {
	seen := map[int32]bool{}
	var out []int32
	for _, pod := range pods {
		for _, container := range append(append([]corev1.Container{}, pod.Spec.InitContainers...), pod.Spec.Containers...) {
			for _, port := range container.Ports {
				if port.Name == name && protocolOf(port.Protocol) == protocol && !seen[port.ContainerPort] {
					seen[port.ContainerPort] = true
					out = append(out, port.ContainerPort)
				}
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func protocolOf(p corev1.Protocol) string {
	if p == "" {
		return "tcp"
	}
	return strings.ToLower(string(p))
}

// peerAddresses turns selectors into the addresses they currently mean.
//
// Resolving to addresses rather than shipping selectors into the pod is what
// makes this possible at all: a pod's kernel knows nothing about labels, and
// nftables is perfectly happy with a set of addresses.
func (c *compiler) peerAddresses(policyNamespace string, list []networkingv1.NetworkPolicyPeer) peers {
	if len(list) == 0 {
		return peers{all: true}
	}
	var out peers
	seen := map[string]bool{}
	for _, peer := range list {
		if peer.IPBlock != nil {
			cidr := canonical(peer.IPBlock.CIDR)
			if cidr == "" {
				continue
			}
			var except []string
			for _, e := range peer.IPBlock.Except {
				if e = canonical(e); e != "" {
					except = append(except, e)
				}
			}
			if len(except) > 0 {
				out.blocks = append(out.blocks, ipBlock{CIDR: cidr, Except: except})
			} else if !seen[cidr] {
				seen[cidr] = true
				out.addresses = append(out.addresses, cidr)
			}
			continue
		}
		for _, pod := range c.selectedPods(policyNamespace, peer) {
			if pod.Status.PodIP == "" || seen[pod.Status.PodIP] {
				continue
			}
			seen[pod.Status.PodIP] = true
			out.addresses = append(out.addresses, pod.Status.PodIP)
		}
	}
	sort.Strings(out.addresses)
	return out
}

// peerPods is every pod a list of peers selects; an empty list is every pod.
func (c *compiler) peerPods(policyNamespace string, list []networkingv1.NetworkPolicyPeer) []*corev1.Pod {
	if len(list) == 0 {
		pods, _ := c.pods.List(labels.Everything())
		return pods
	}
	var out []*corev1.Pod
	for _, peer := range list {
		if peer.IPBlock == nil {
			out = append(out, c.selectedPods(policyNamespace, peer)...)
		}
	}
	return out
}

func (c *compiler) selectedPods(policyNamespace string, peer networkingv1.NetworkPolicyPeer) []*corev1.Pod {
	namespaces := []string{policyNamespace}
	if peer.NamespaceSelector != nil {
		namespaces = c.matchingNamespaces(peer.NamespaceSelector)
	}
	selector := labels.Everything()
	if peer.PodSelector != nil {
		s, err := metav1.LabelSelectorAsSelector(peer.PodSelector)
		if err != nil {
			return nil
		}
		selector = s
	}
	var out []*corev1.Pod
	for _, namespace := range namespaces {
		pods, err := c.pods.Pods(namespace).List(selector)
		if err == nil {
			out = append(out, pods...)
		}
	}
	return out
}

// canonical is a CIDR with its host bits cleared, or "" if it is not one.
func canonical(cidr string) string {
	_, network, err := net.ParseCIDR(cidr)
	if err != nil {
		return ""
	}
	return network.String()
}

func hostPrefix(address string) string {
	if strings.Contains(address, "/") {
		return address
	}
	if ip := net.ParseIP(address); ip != nil && ip.To4() == nil {
		return address + "/128"
	}
	return address + "/32"
}

func isIPv4(address string) bool {
	host, _, _ := strings.Cut(address, "/")
	ip := net.ParseIP(host)
	return ip != nil && ip.To4() != nil
}

func ipv4Only(addresses []string) []string {
	var out []string
	for _, a := range addresses {
		if isIPv4(a) {
			out = append(out, a)
		}
	}
	return out
}

func (c *compiler) matchingNamespaces(selector *metav1.LabelSelector) []string {
	parsed, err := metav1.LabelSelectorAsSelector(selector)
	if err != nil {
		return nil
	}
	namespaces, err := c.namespaces.List(parsed)
	if err != nil {
		return nil
	}
	var out []string
	for _, namespace := range namespaces {
		out = append(out, namespace.Name)
	}
	return out
}

func (c *compiler) selects(policy *networkingv1.NetworkPolicy, pod *corev1.Pod) bool {
	selector, err := metav1.LabelSelectorAsSelector(&policy.Spec.PodSelector)
	if err != nil {
		return false
	}
	return selector.Matches(labels.Set(pod.Labels))
}

// policyDirections is the API's rule about an omitted policyTypes: it means
// Ingress, plus Egress if the policy actually has egress rules.
func policyDirections(policy *networkingv1.NetworkPolicy) []networkingv1.PolicyType {
	if len(policy.Spec.PolicyTypes) > 0 {
		return policy.Spec.PolicyTypes
	}
	out := []networkingv1.PolicyType{networkingv1.PolicyTypeIngress}
	if len(policy.Spec.Egress) > 0 {
		out = append(out, networkingv1.PolicyTypeEgress)
	}
	return out
}
