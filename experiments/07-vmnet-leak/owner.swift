import Foundation
import vmnet
// Creates the network, writes the serialization to a file, and holds it open.
var status: vmnet_return_t = .VMNET_FAILURE
guard let cfg = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else { exit(1) }
vmnet_network_configuration_disable_dhcp(cfg)
var ga = in_addr(), ma = in_addr()
inet_pton(AF_INET, CommandLine.arguments[1], &ga); inet_pton(AF_INET, "255.255.255.0", &ma)
_ = vmnet_network_configuration_set_ipv4_subnet(cfg, &ga, &ma)
guard let net = vmnet_network_create(cfg, &status) else { print("owner: refused \(status)"); exit(1) }
guard let blob = vmnet_network_copy_serialization(net, &status),
      let inner = xpc_dictionary_get_value(blob, "networkSerialization") else { exit(1) }
var len = 0
len = xpc_data_get_length(inner)
let bytes = xpc_data_get_bytes_ptr(inner)!
try! Data(bytes: bytes, count: len).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("owner: network up, \(len) bytes written, holding")
setvbuf(stdout, nil, _IONBF, 0)
dispatchMain()
