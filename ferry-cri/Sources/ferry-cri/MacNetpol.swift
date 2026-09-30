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

/// An egress allow parsed from the `output` chain, matched host-side in ferry-cri
/// (post-Service-DNAT) rather than in the guest -- see MacNetpol's header and the
/// egress note in MacServiceNAT.
struct EgressAllow: Sendable {
    var dsts: [(base: UInt32, mask: UInt32)]   // empty = any destination
    var proto: UInt8?                          // 6/17/132, nil = any
    var ports: [UInt16]                        // empty = any port
}

/// A pod's egress policy: default-deny (set only when the `output` chain ends in
/// `drop`, i.e. an egress policy selects the pod) plus the allowed flows.
struct EgressPolicy: Sendable {
    var defaultDeny: Bool
    var allows: [EgressAllow]
}

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

    /// A pod's egress policy from its `output` chain, or nil when there is no
    /// `output drop` (no egress policy -> egress stays open). Matched in ferry-cri
    /// against the post-DNAT destination (MacServiceNAT).
    static func egressPolicy(section: String) -> EgressPolicy? {
        var allows: [EgressAllow] = []
        var hasDrop = false
        for raw in section.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("add rule ip ferry-netpol output ") else { continue }
            let body = String(line.dropFirst("add rule ip ferry-netpol output ".count))
            if body == "drop" { hasDrop = true; continue }
            if body.hasPrefix("oifname") || body.hasPrefix("iifname") { continue }   // lo
            if body.contains("ct state") { continue }                                // established
            guard body.contains("accept") else { continue }
            allows.append(parseEgressAllow(body))
        }
        guard hasDrop else { return nil }
        return EgressPolicy(defaultDeny: true, allows: allows)
    }

    /// Parse `[ip daddr { a, b/n }] [tcp|udp|sctp] [dport N | dport { N, M }] accept`.
    private static func parseEgressAllow(_ body: String) -> EgressAllow {
        var a = EgressAllow(dsts: [], proto: nil, ports: [])
        let f = body.split(separator: " ").map(String.init)
        if f.contains("daddr") {
            a.dsts = braced(f, after: "daddr").compactMap(cidr)
        }
        if f.contains("tcp") { a.proto = 6 } else if f.contains("udp") { a.proto = 17 }
        else if f.contains("sctp") { a.proto = 132 }
        if let di = f.firstIndex(of: "dport") {
            let toks: [String]
            if di + 1 < f.count, f[di + 1] == "{" { toks = braced(f, after: "dport") }
            else if di + 1 < f.count { toks = [f[di + 1].trimmingCharacters(in: CharacterSet(charactersIn: ","))] }
            else { toks = [] }
            a.ports = toks.compactMap { UInt16($0) }
        }
        return a
    }

    /// "10.194.0.5" or "10.0.0.0/8" -> (base, mask), host byte order.
    private static func cidr(_ s: String) -> (base: UInt32, mask: UInt32)? {
        let parts = s.split(separator: "/")
        guard let ip = ipToUInt32(String(parts[0])) else { return nil }
        let bits = parts.count == 2 ? (Int(parts[1]) ?? 32) : 32
        let mask: UInt32 = bits <= 0 ? 0 : (bits >= 32 ? 0xffff_ffff : (0xffff_ffff << (32 - bits)))
        return (ip & mask, mask)
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
