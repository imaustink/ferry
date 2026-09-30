// NetworkPolicy (ingress) for macOS pods, enforced with pf.
//
// A Linux ferry pod loads ferry-netpol's nftables rules into its own kernel; a
// macOS pod has no Linux kernel, so ferry-cri translates the pod's *ingress*
// section to pf and loads it in the guest over the root agent. A macOS pod is a
// whole VM, so its section's `input` chain becomes the guest's pf ruleset.
//
// Ingress only, for now. Egress NetworkPolicy would have to be enforced after
// the host-side Service DNAT (MacServiceNAT rewrites a ClusterIP to an endpoint
// only once the frame has left the guest), so guest-side pf would see ClusterIPs
// rather than the endpoint addresses the policy is written against -- that needs
// enforcement in ferry-cri, a separate step. Egress stays open here.
//
// The ferry-netpol section for a pod (from ferry-netpol/compile.go), e.g.:
//   ## 10.194.255.2
//   add chain ip ferry-netpol input { type filter hook input priority 0 ; policy accept ; }
//   add rule ip ferry-netpol input iifname "lo" accept
//   add rule ip ferry-netpol input ct state established,related accept
//   add rule ip ferry-netpol input ip saddr { 10.194.0.7 } tcp dport 8080 accept
//   add rule ip ferry-netpol input ip saddr { 10.194.0.1 } accept
//   add rule ip ferry-netpol input drop
// A final `input drop` means an ingress policy selects the pod (default-deny);
// without it, ingress is unrestricted and pf stays off.

import Foundation

enum MacNetpol {
    /// An ingress allow, translated from one `ip saddr {..} [proto dport ..] accept`.
    private struct Allow {
        var sources: [String]      // IPs or CIDRs
        var proto: String?         // "tcp" / "udp", nil = any
        var ports: [String]        // empty = any port
    }

    /// Build the guest pf ruleset for a pod's ingress section, or nil when the
    /// section has no `input drop` (no ingress policy -> pf stays off). Only
    /// cluster traffic (from `clusterCIDR`, on the pod's cluster NIC) is policed;
    /// the NAT NIC (internet) and replies to the pod's own connections (pf state)
    /// are untouched.
    static func ingressRuleset(section: String, podIP: String, clusterCIDR: String) -> String? {
        var allows: [Allow] = []
        var hasDrop = false
        for raw in section.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("add rule ip ferry-netpol input ") else { continue }
            let body = String(line.dropFirst("add rule ip ferry-netpol input ".count))
            if body == "drop" { hasDrop = true; continue }
            if body.hasPrefix("iifname") || body.hasPrefix("oifname") { continue }     // lo: set skip on lo0
            if body.contains("ct state") { continue }                                  // established: pf state
            guard body.hasPrefix("ip saddr") else { continue }
            allows.append(parseAllow(body))
        }
        guard hasDrop else { return nil }

        var pf = ["set skip on lo0",
                  "set block-policy drop",
                  // The pod's own outbound and its replies (egress is open here).
                  "pass out quick all keep state"]
        for a in allows {
            let from = a.sources.isEmpty ? "any" : "{ \(a.sources.joined(separator: ", ")) }"
            let proto = a.proto.map { "proto \($0) " } ?? ""
            let ports = a.ports.isEmpty ? "" : " port { \(a.ports.joined(separator: ", ")) }"
            pf.append("pass in quick inet \(proto)from \(from) to \(podIP)\(ports) keep state")
        }
        // Default-deny for cluster traffic to this pod; replies to the pod's own
        // connections are already allowed by state above.
        pf.append("block drop in quick inet from \(clusterCIDR) to \(podIP)")
        return pf.joined(separator: "\n") + "\n"
    }

    /// Parse `ip saddr { a, b } [tcp|udp] [dport N | dport { N, M }] accept`.
    private static func parseAllow(_ body: String) -> Allow {
        var a = Allow(sources: [], proto: nil, ports: [])
        let f = body.split(separator: " ").map(String.init)
        a.sources = braced(f, after: "saddr")
        if f.contains("tcp") { a.proto = "tcp" } else if f.contains("udp") { a.proto = "udp" }
        else if f.contains("sctp") { a.proto = "sctp" }
        if let di = f.firstIndex(of: "dport") {
            if di + 1 < f.count, f[di + 1] == "{" {
                a.ports = braced(f, after: "dport")
            } else if di + 1 < f.count {
                a.ports = [f[di + 1].trimmingCharacters(in: CharacterSet(charactersIn: ","))]
            }
        }
        return a
    }

    /// The comma-separated tokens inside `{ ... }` following a keyword.
    private static func braced(_ f: [String], after keyword: String) -> [String] {
        guard let ki = f.firstIndex(of: keyword), ki + 1 < f.count, f[ki + 1] == "{" else { return [] }
        var out: [String] = []
        var i = ki + 2
        while i < f.count, f[i] != "}" {
            let tok = f[i].trimmingCharacters(in: CharacterSet(charactersIn: ","))
            if !tok.isEmpty, tok != "," { out.append(tok) }
            i += 1
        }
        return out
    }
}
