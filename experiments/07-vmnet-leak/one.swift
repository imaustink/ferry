import Foundation
import vmnet
let gw = CommandLine.arguments.dropFirst().first ?? "192.168.66.1"
var status: vmnet_return_t = .VMNET_FAILURE
guard let cfg = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
    print("config failed \(status)"); exit(1)
}
vmnet_network_configuration_disable_dhcp(cfg)
var ga = in_addr(), ma = in_addr()
inet_pton(AF_INET, gw, &ga); inet_pton(AF_INET, "255.255.255.0", &ma)
_ = vmnet_network_configuration_set_ipv4_subnet(cfg, &ga, &ma)
if let ref = vmnet_network_create(cfg, &status) {
    print("\(gw): CREATED (status \(status))")
    Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(ref)).release()
} else {
    print("\(gw): REFUSED with \(status)")
}
