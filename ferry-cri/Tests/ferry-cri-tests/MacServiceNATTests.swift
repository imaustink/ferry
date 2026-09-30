// The kube-proxy nftables ruleset parser and the DNAT checksum arithmetic, both
// pure and testable without a guest.

import Foundation
import Testing
@testable import ferry_cri

@Suite struct MacServiceNATTests {
    @Test func parsesASingleEndpointService() {
        // The shape a one-backend Service takes: the service chain dnats directly.
        let ruleset = """
        add table ip kube-proxy
        add chain ip kube-proxy service-2QRHZV4L-default/kubernetes/tcp/https
        add rule ip kube-proxy service-2QRHZV4L-default/kubernetes/tcp/https meta l4proto tcp dnat to 192.168.1.29:50443
        add rule ip kube-proxy services ip daddr . meta l4proto . th dport vmap @service-ips
        add element ip kube-proxy service-ips { 10.96.0.1 . tcp . 443 : goto service-2QRHZV4L-default/kubernetes/tcp/https }
        """
        let table = parseKubeProxyRuleset(ruleset)
        let key = ServiceKey(ip: ipToUInt32("10.96.0.1")!, proto: 6, port: 443)
        #expect(table[key]?.endpoints == [Endpoint(ip: ipToUInt32("192.168.1.29")!, port: 50443)])
        #expect(table[key]?.affinityTimeout == nil)
    }

    @Test func parsesMultipleEndpointsThroughEndpointChains() {
        // A multi-backend Service: the service chain jumps to per-endpoint chains
        // that each dnat.
        let ruleset = """
        add chain ip kube-proxy service-ABCD-default/web/tcp/http
        add chain ip kube-proxy endpoint-1111-default/web/tcp/http
        add chain ip kube-proxy endpoint-2222-default/web/tcp/http
        add rule ip kube-proxy service-ABCD-default/web/tcp/http numgen random mod 2 vmap { 0 : goto endpoint-1111-default/web/tcp/http , 1 : goto endpoint-2222-default/web/tcp/http }
        add rule ip kube-proxy service-ABCD-default/web/tcp/http meta l4proto tcp jump endpoint-1111-default/web/tcp/http
        add rule ip kube-proxy service-ABCD-default/web/tcp/http meta l4proto tcp jump endpoint-2222-default/web/tcp/http
        add rule ip kube-proxy endpoint-1111-default/web/tcp/http meta l4proto tcp dnat to 10.244.0.5:8080
        add rule ip kube-proxy endpoint-2222-default/web/tcp/http meta l4proto tcp dnat to 10.244.0.6:8080
        add element ip kube-proxy service-ips { 10.96.14.2 . tcp . 80 : goto service-ABCD-default/web/tcp/http }
        """
        let table = parseKubeProxyRuleset(ruleset)
        let key = ServiceKey(ip: ipToUInt32("10.96.14.2")!, proto: 6, port: 80)
        let eps = Set(table[key]?.endpoints ?? [])
        #expect(eps == [Endpoint(ip: ipToUInt32("10.244.0.5")!, port: 8080),
                        Endpoint(ip: ipToUInt32("10.244.0.6")!, port: 8080)])
    }

    @Test func parsesSessionAffinityAndItsTimeout() {
        // A ClientIP-affinity service: the service chain matches @affinity-* and
        // the set carries the timeout.
        let ruleset = """
        add chain ip kube-proxy service-VEZ-default/svc-affinity/tcp/
        add chain ip kube-proxy endpoint-R23-default/svc-affinity/tcp/__10.194.0.4/8080
        add set ip kube-proxy affinity-R23-default/svc-affinity/tcp/__10.194.0.4/8080 { type ipv4_addr ; flags dynamic,timeout ; timeout 10800s ; }
        add rule ip kube-proxy endpoint-R23-default/svc-affinity/tcp/__10.194.0.4/8080 update @affinity-R23-default/svc-affinity/tcp/__10.194.0.4/8080 { ip saddr }
        add rule ip kube-proxy endpoint-R23-default/svc-affinity/tcp/__10.194.0.4/8080 meta l4proto tcp dnat to 10.194.0.4:8080
        add rule ip kube-proxy service-VEZ-default/svc-affinity/tcp/ ip saddr @affinity-R23-default/svc-affinity/tcp/__10.194.0.4/8080 goto endpoint-R23-default/svc-affinity/tcp/__10.194.0.4/8080
        add rule ip kube-proxy service-VEZ-default/svc-affinity/tcp/ numgen random mod 1 vmap { 0 : goto endpoint-R23-default/svc-affinity/tcp/__10.194.0.4/8080 }
        add element ip kube-proxy service-ips { 10.96.15.238 . tcp . 80 : goto service-VEZ-default/svc-affinity/tcp/ }
        """
        let key = ServiceKey(ip: ipToUInt32("10.96.15.238")!, proto: 6, port: 80)
        let svc = parseKubeProxyRuleset(ruleset)[key]
        #expect(svc?.endpoints == [Endpoint(ip: ipToUInt32("10.194.0.4")!, port: 8080)])
        #expect(svc?.affinityTimeout == 10800)
    }

    @Test func parsesSctpService() {
        let ruleset = """
        add chain ip kube-proxy service-SC-default/sctp-svc/sctp/
        add rule ip kube-proxy service-SC-default/sctp-svc/sctp/ meta l4proto sctp dnat to 10.194.0.9:38412
        add element ip kube-proxy service-ips { 10.96.7.7 . sctp . 38412 : goto service-SC-default/sctp-svc/sctp/ }
        """
        let key = ServiceKey(ip: ipToUInt32("10.96.7.7")!, proto: 132, port: 38412)
        #expect(parseKubeProxyRuleset(ruleset)[key]?.endpoints == [Endpoint(ip: ipToUInt32("10.194.0.9")!, port: 38412)])
    }

    @Test func aServiceWithNoEndpointsIsAbsent() {
        let ruleset = """
        add rule ip kube-proxy service-endpoints-check ip daddr . meta l4proto . th dport vmap @no-endpoint-services
        add element ip kube-proxy no-endpoint-services { 10.96.9.9 . tcp . 80 : goto reject-chain }
        """
        #expect(parseKubeProxyRuleset(ruleset).isEmpty)
    }

    @Test func dnatRewriteKeepsTheTcpChecksumValid() {
        // Build a minimal IPv4/TCP frame to a ClusterIP, DNAT it, and check both
        // checksums verify. The NAT floods to the endpoint after rewriting.
        let gwMAC: [UInt8] = [0x02, 0x66, 0x72, 0x79, 0x00, 0x01]
        let nat = MacServiceNAT(podIP: ipToUInt32("10.194.255.2")!,
                                gatewayIP: ipToUInt32("10.194.255.1")!, gatewayMAC: gwMAC)
        nat.update([ServiceKey(ip: ipToUInt32("10.96.0.10")!, proto: 6, port: 80):
                        Service(endpoints: [Endpoint(ip: ipToUInt32("10.194.0.7")!, port: 8080)],
                                affinityTimeout: nil)])
        var frame = tcpSyn(dstMAC: gwMAC, srcIP: "10.194.255.2", dstIP: "10.96.0.10",
                           srcPort: 51000, dstPort: 80)
        guard case .forward(let out) = nat.egress(frame) else {
            Issue.record("expected the ClusterIP frame to be DNATed"); return
        }
        #expect(ipChecksumOK(out))
        #expect(tcpChecksumOK(out))
        // Destination is now the endpoint.
        #expect(readU32(out, 30) == ipToUInt32("10.194.0.7")!)
        #expect(readU16(out, 34 + 2) == 8080)
        _ = frame
    }

    // MARK: - frame helpers

    private func tcpSyn(dstMAC: [UInt8], srcIP: String, dstIP: String,
                        srcPort: UInt16, dstPort: UInt16) -> Data {
        var f = Data(count: 54)                       // 14 eth + 20 ip + 20 tcp
        for i in 0..<6 { f[i] = dstMAC[i]; f[6 + i] = UInt8(0xaa) }
        f[12] = 0x08; f[13] = 0x00
        f[14] = 0x45                                  // ver 4, ihl 5
        writeU16(&f, 16, 40)                          // total length
        f[22] = 64                                    // ttl
        f[23] = 6                                     // tcp
        writeU32(&f, 26, ipToUInt32(srcIP)!)
        writeU32(&f, 30, ipToUInt32(dstIP)!)
        writeU16(&f, 24, ipChecksum(f, 14, 20))
        writeU16(&f, 34, srcPort)
        writeU16(&f, 36, dstPort)
        f[46] = 0x50; f[47] = 0x02                    // data offset 5, SYN
        writeU16(&f, 34 + 16, tcpChecksum(f))
        return f
    }

    private func ipChecksum(_ d: Data, _ off: Int, _ len: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = off
        while i < off + len { if i == off + 10 { i += 2; continue }  // skip checksum field
            sum += UInt32(readU16(d, i)); i += 2 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }
    private func tcpChecksum(_ d: Data) -> UInt16 {
        var sum: UInt32 = 0
        // pseudo-header: src+dst IP, proto, tcp length
        sum += UInt32(readU16(d, 26)) + UInt32(readU16(d, 28))
        sum += UInt32(readU16(d, 30)) + UInt32(readU16(d, 32))
        sum += UInt32(6) + UInt32(20)
        var i = 34
        while i < 54 { if i == 34 + 16 { i += 2; continue }
            sum += UInt32(readU16(d, i)); i += 2 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }
    private func ipChecksumOK(_ d: Data) -> Bool {
        var sum: UInt32 = 0
        var i = 14
        while i < 34 { sum += UInt32(readU16(d, i)); i += 2 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(sum & 0xffff) == 0xffff
    }
    private func tcpChecksumOK(_ d: Data) -> Bool {
        var sum: UInt32 = 0
        sum += UInt32(readU16(d, 26)) + UInt32(readU16(d, 28))
        sum += UInt32(readU16(d, 30)) + UInt32(readU16(d, 32))
        sum += UInt32(6) + UInt32(20)
        var i = 34
        while i < 54 { sum += UInt32(readU16(d, i)); i += 2 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(sum & 0xffff) == 0xffff
    }

    private func readU16(_ d: Data, _ o: Int) -> UInt16 { (UInt16(d[d.startIndex+o]) << 8) | UInt16(d[d.startIndex+o+1]) }
    private func readU32(_ d: Data, _ o: Int) -> UInt32 {
        (UInt32(d[d.startIndex+o]) << 24) | (UInt32(d[d.startIndex+o+1]) << 16)
            | (UInt32(d[d.startIndex+o+2]) << 8) | UInt32(d[d.startIndex+o+3])
    }
    private func writeU16(_ d: inout Data, _ o: Int, _ v: UInt16) { d[d.startIndex+o] = UInt8(v>>8); d[d.startIndex+o+1] = UInt8(v & 0xff) }
    private func writeU32(_ d: inout Data, _ o: Int, _ v: UInt32) {
        d[d.startIndex+o] = UInt8(v>>24); d[d.startIndex+o+1] = UInt8((v>>16) & 0xff)
        d[d.startIndex+o+2] = UInt8((v>>8) & 0xff); d[d.startIndex+o+3] = UInt8(v & 0xff)
    }
}
