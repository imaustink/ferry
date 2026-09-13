import Foundation
import vmnet
var status: vmnet_return_t = .VMNET_FAILURE
guard let cfg = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else { exit(1) }
vmnet_network_configuration_disable_dhcp(cfg)
var ga = in_addr(), ma = in_addr()
inet_pton(AF_INET, "192.168.59.1", &ga); inet_pton(AF_INET, "255.255.255.0", &ma)
_ = vmnet_network_configuration_set_ipv4_subnet(cfg, &ga, &ma)
guard let net = vmnet_network_create(cfg, &status) else { print("refused \(status)"); exit(1) }
guard let blob = vmnet_network_copy_serialization(net, &status) else { exit(1) }
let t = xpc_get_type(blob)
print("xpc type    : \(String(cString: xpc_type_get_name(t)))")
print("is data     : \(t == XPC_TYPE_DATA)")
print("is dict     : \(t == XPC_TYPE_DICTIONARY)")
print("description : \(String(cString: xpc_copy_description(blob)).prefix(400))")
