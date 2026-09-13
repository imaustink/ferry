import Foundation
import vmnet

func subnetOf(_ ref: vmnet_network_ref) -> String {
    var s = in_addr(), m = in_addr()
    vmnet_network_get_ipv4_subnet(ref, &s, &m)
    return "\(String(cString: inet_ntoa(s)))/\(String(cString: inet_ntoa(m)))"
}

var status: vmnet_return_t = .VMNET_FAILURE
guard let cfg = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else { exit(1) }
vmnet_network_configuration_disable_dhcp(cfg)
var ga = in_addr(), ma = in_addr()
inet_pton(AF_INET, "192.168.58.1", &ga); inet_pton(AF_INET, "255.255.255.0", &ma)
_ = vmnet_network_configuration_set_ipv4_subnet(cfg, &ga, &ma)

guard let original = vmnet_network_create(cfg, &status) else {
    print("create refused with \(status)"); exit(1)
}
print("original      : \(subnetOf(original))")

// Can this reservation be handed to somebody else?
guard let blob = vmnet_network_copy_serialization(original, &status) else {
    print("serialization refused with \(status)"); exit(1)
}
print("serialized    : ok")

guard let second = vmnet_network_create_with_serialization(blob, &status) else {
    print("rehydrate refused with \(status)"); exit(1)
}
print("rehydrated    : \(subnetOf(second))")
print(subnetOf(original) == subnetOf(second)
      ? "SAME NETWORK -- two holders of one subnet"
      : "different network")

// And is it still one reservation? Asking for the subnet fresh should be refused
// while either handle lives.
if let cfg2 = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) {
    vmnet_network_configuration_disable_dhcp(cfg2)
    _ = vmnet_network_configuration_set_ipv4_subnet(cfg2, &ga, &ma)
    if vmnet_network_create(cfg2, &status) != nil {
        print("plain create  : ALSO succeeded (not exclusive)")
    } else {
        print("plain create  : refused with \(status) -- serialization is the only way in")
    }
}
