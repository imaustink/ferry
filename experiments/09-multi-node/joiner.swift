import Foundation
import vmnet
// Reads those bytes in a *different process* and rehydrates the same network.
func subnetOf(_ r: vmnet_network_ref) -> String {
    var s = in_addr(), m = in_addr(); vmnet_network_get_ipv4_subnet(r, &s, &m)
    return String(cString: inet_ntoa(s))
}
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let dict = xpc_dictionary_create(nil, nil, 0)
data.withUnsafeBytes { raw in
    xpc_dictionary_set_data(dict, "networkSerialization", raw.baseAddress!, raw.count)
}
var status: vmnet_return_t = .VMNET_FAILURE
if let net = vmnet_network_create_with_serialization(dict, &status) {
    print("joiner: rehydrated \(subnetOf(net)) in a separate process")
} else {
    print("joiner: refused with \(status)")
}
