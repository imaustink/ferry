import Foundation
import Testing
@testable import ferry_cri

@Suite struct MacNetpolTests {
    @Test func noDropMeansNoIngressPolicySoPfStaysOff() {
        // An empty / policy-free section has no `input drop`.
        let section = """
        add table ip ferry-netpol
        delete table ip ferry-netpol
        """
        #expect(MacNetpol.ingressRuleset(section: section, podIP: "10.194.255.2",
                                         clusterCIDR: "10.194.0.0/16") == nil)
    }

    @Test func translatesIngressAllowsAndDefaultDeny() {
        let section = """
        add chain ip ferry-netpol input { type filter hook input priority 0 ; policy accept ; }
        add rule ip ferry-netpol input iifname "lo" accept
        add rule ip ferry-netpol input ct state established,related accept
        add rule ip ferry-netpol input ip saddr { 10.194.0.7 } tcp dport 8080 accept
        add rule ip ferry-netpol input ip saddr { 10.194.0.1 } accept
        add rule ip ferry-netpol input drop
        """
        let pf = MacNetpol.ingressRuleset(section: section, podIP: "10.194.255.2",
                                          clusterCIDR: "10.194.0.0/16")
        let rules = pf ?? ""
        #expect(rules.contains("set skip on lo0"))
        #expect(rules.contains("pass out quick all keep state"))
        // the port-scoped allow
        #expect(rules.contains("pass in quick inet proto tcp from { 10.194.0.7 } to 10.194.255.2 port { 8080 } keep state"))
        // the portless allow (the node guard)
        #expect(rules.contains("pass in quick inet from { 10.194.0.1 } to 10.194.255.2 keep state"))
        // default-deny for cluster traffic to the pod
        #expect(rules.contains("block drop in quick inet from 10.194.0.0/16 to 10.194.255.2"))
    }

    @Test func parsesEgressPolicy() {
        let section = """
        add chain ip ferry-netpol output { type filter hook output priority 0 ; policy accept ; }
        add rule ip ferry-netpol output oifname "lo" accept
        add rule ip ferry-netpol output ct state established,related accept
        add rule ip ferry-netpol output ip daddr { 10.194.0.5 } tcp dport 5432 accept
        add rule ip ferry-netpol output udp dport 53 accept
        add rule ip ferry-netpol output drop
        """
        let pol = MacNetpol.egressPolicy(section: section)
        #expect(pol?.defaultDeny == true)
        #expect(pol?.allows.count == 2)
        // the db allow: dst 10.194.0.5/32, tcp, 5432
        let db = pol?.allows.first { $0.proto == 6 }
        #expect(db?.dsts.first?.base == ipToUInt32("10.194.0.5"))
        #expect(db?.dsts.first?.mask == 0xffff_ffff)
        #expect(db?.ports == [5432])
        // the DNS allow: any dst, udp, 53
        let dns = pol?.allows.first { $0.proto == 17 }
        #expect(dns?.dsts.isEmpty == true)
        #expect(dns?.ports == [53])
    }

    @Test func noOutputDropMeansEgressOpen() {
        let section = """
        add rule ip ferry-netpol input ip saddr { 10.194.0.1 } accept
        add rule ip ferry-netpol input drop
        """
        #expect(MacNetpol.egressPolicy(section: section) == nil)   // ingress-only policy
    }

    @Test func parsesAPortSet() {
        let section = """
        add rule ip ferry-netpol input ip saddr { 10.0.0.0/8 } tcp dport { 80, 443 } accept
        add rule ip ferry-netpol input drop
        """
        let rules = MacNetpol.ingressRuleset(section: section, podIP: "10.194.255.3",
                                             clusterCIDR: "10.194.0.0/16") ?? ""
        #expect(rules.contains("from { 10.0.0.0/8 } to 10.194.255.3 port { 80, 443 }"))
    }
}
