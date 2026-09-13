package main

import (
	"fmt"
	"sort"
	"strings"

	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	corelisters "k8s.io/client-go/listers/core/v1"
	networkinglisters "k8s.io/client-go/listers/networking/v1"
)

type compiler struct {
	clusterCIDR string
	policies    networkinglisters.NetworkPolicyLister
	pods        corelisters.PodLister
	namespaces  corelisters.NamespaceLister
}

// render produces one section per pod, which ferry-cri splits up and applies to
// the pod it belongs to. Pods no policy mentions get a section too -- an empty
// one -- because removing the last policy has to open the traffic back up.
func (c *compiler) render() string {
	pods, err := c.pods.List(labels.Everything())
	if err != nil {
		return ""
	}
	policies, err := c.policies.List(labels.Everything())
	if err != nil {
		return ""
	}

	var out strings.Builder
	sort.Slice(pods, func(i, j int) bool { return pods[i].Status.PodIP < pods[j].Status.PodIP })
	for _, pod := range pods {
		if pod.Status.PodIP == "" || pod.Spec.HostNetwork {
			continue
		}
		fmt.Fprintf(&out, "## %s\n%s\n", pod.Status.PodIP, c.rulesFor(pod, policies))
	}
	return out.String()
}

// rulesFor is the whole of NetworkPolicy for one pod.
//
// The shape is the API's own: a pod that no policy selects is unrestricted, and
// a pod that any policy selects for a direction is default-deny in that
// direction with the union of every matching rule allowed back in.
func (c *compiler) rulesFor(pod *corev1.Pod, all []*networkingv1.NetworkPolicy) string {
	var ingress, egress []*networkingv1.NetworkPolicy
	for _, policy := range all {
		if policy.Namespace != pod.Namespace || !c.selects(policy, pod) {
			continue
		}
		for _, direction := range policyDirections(policy) {
			switch direction {
			case networkingv1.PolicyTypeIngress:
				ingress = append(ingress, policy)
			case networkingv1.PolicyTypeEgress:
				egress = append(egress, policy)
			}
		}
	}

	var b strings.Builder
	// Replace wholesale, so a policy that goes away takes its rules with it.
	b.WriteString("add table ip ferry-netpol\n")
	b.WriteString("delete table ip ferry-netpol\n")
	if len(ingress) == 0 && len(egress) == 0 {
		return b.String() // nothing selects this pod: no filtering at all
	}
	b.WriteString("add table ip ferry-netpol\n")

	if len(ingress) > 0 {
		b.WriteString(`add chain ip ferry-netpol input { type filter hook input priority 0 ; policy accept ; }` + "\n")
		c.writeIngressGuards(&b)
		for _, policy := range ingress {
			for _, rule := range policy.Spec.Ingress {
				peers := c.peerAddresses(policy.Namespace, rule.From)
				c.writeAllow(&b, "input", "saddr", peers, rule.Ports, len(rule.From) == 0)
			}
		}
		// Everything on the cluster network that was not allowed above.
		b.WriteString(`add rule ip ferry-netpol input drop` + "\n")
	}

	if len(egress) > 0 {
		b.WriteString(`add chain ip ferry-netpol output { type filter hook output priority 0 ; policy accept ; }` + "\n")
		c.writeEgressGuards(&b)
		for _, policy := range egress {
			for _, rule := range policy.Spec.Egress {
				peers := c.peerAddresses(policy.Namespace, egressPeers(rule.To))
				c.writeAllow(&b, "output", "daddr", peers, rule.Ports, len(rule.To) == 0)
			}
		}
		b.WriteString(`add rule ip ferry-netpol output drop` + "\n")
	}

	return b.String()
}

// writeIngressGuards exempts two things from an ingress policy.
//
// Return traffic, because a policy describes who may start a conversation, not
// who may answer. And anything arriving on eth0 rather than the cluster network:
// that is the Mac itself -- the kubelet's health probes, and connections
// forwarded in from a node port. Dropping those does not isolate the pod, it
// takes it down, because a failed probe restarts the container.
//
// This is a deliberate difference from the API, which does not exempt the node.
// It is the same bargain most CNI plugins strike, and it is written down in
// docs/NETWORK-POLICY.md rather than left to be discovered.
func (c *compiler) writeIngressGuards(b *strings.Builder) {
	b.WriteString("add rule ip ferry-netpol input ct state established,related accept\n")
	b.WriteString("add rule ip ferry-netpol input iifname != \"eth1\" accept\n")
}

// writeEgressGuards exempts only return traffic.
//
// An egress policy in Kubernetes restricts everything the pod initiates,
// including traffic to the internet, so there is no interface exemption here.
// A deny-all egress policy really does deny everything -- which also means a pod
// under one cannot reach cluster DNS unless the policy says so. That surprises
// people, and it is what the API asks for.
func (c *compiler) writeEgressGuards(b *strings.Builder) {
	b.WriteString("add rule ip ferry-netpol output ct state established,related accept\n")
}

func (c *compiler) writeAllow(b *strings.Builder, chain, match string,
	peers []string, ports []networkingv1.NetworkPolicyPort, allPeers bool) {

	var addresses string
	switch {
	case allPeers:
		addresses = "" // every peer on the cluster network
	case len(peers) == 0:
		return // the rule names peers and none exist, so it allows nothing
	default:
		addresses = fmt.Sprintf("ip %s { %s } ", match, strings.Join(peers, ", "))
	}

	if len(ports) == 0 {
		fmt.Fprintf(b, "add rule ip ferry-netpol %s %saccept\n", chain, addresses)
		return
	}
	for _, port := range ports {
		proto := "tcp"
		if port.Protocol != nil {
			proto = strings.ToLower(string(*port.Protocol))
		}
		if port.Port == nil {
			fmt.Fprintf(b, "add rule ip ferry-netpol %s %smeta l4proto %s accept\n", chain, addresses, proto)
			continue
		}
		fmt.Fprintf(b, "add rule ip ferry-netpol %s %s%s dport %s accept\n",
			chain, addresses, proto, port.Port.String())
	}
}

// peerAddresses turns selectors into the addresses they currently mean.
//
// Resolving to addresses rather than shipping selectors into the pod is what
// makes this possible at all: a pod's kernel knows nothing about labels, and
// nftables is perfectly happy with a set of addresses.
func (c *compiler) peerAddresses(policyNamespace string, peers []networkingv1.NetworkPolicyPeer) []string {
	var out []string
	seen := map[string]bool{}
	for _, peer := range peers {
		if peer.IPBlock != nil {
			if !seen[peer.IPBlock.CIDR] {
				seen[peer.IPBlock.CIDR] = true
				out = append(out, peer.IPBlock.CIDR)
			}
			continue
		}
		namespaces := []string{policyNamespace}
		if peer.NamespaceSelector != nil {
			namespaces = c.matchingNamespaces(peer.NamespaceSelector)
		}
		selector := labels.Everything()
		if peer.PodSelector != nil {
			if s, err := metav1.LabelSelectorAsSelector(peer.PodSelector); err == nil {
				selector = s
			}
		}
		for _, namespace := range namespaces {
			pods, err := c.pods.Pods(namespace).List(selector)
			if err != nil {
				continue
			}
			for _, pod := range pods {
				if pod.Status.PodIP == "" || seen[pod.Status.PodIP] {
					continue
				}
				seen[pod.Status.PodIP] = true
				out = append(out, pod.Status.PodIP)
			}
		}
	}
	sort.Strings(out)
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

func egressPeers(to []networkingv1.NetworkPolicyPeer) []networkingv1.NetworkPolicyPeer { return to }
