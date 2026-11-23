import Foundation
import Virtualization
let ifaces = VZBridgedNetworkInterface.networkInterfaces
print("VZ bridgeable interfaces: \(ifaces.count)")
for i in ifaces { print("  - \(i.identifier) \(i.localizedDisplayName ?? "")") }
if let first = ifaces.first {
    let a = VZBridgedNetworkDeviceAttachment(interface: first)
    let dev = VZVirtioNetworkDeviceConfiguration(); dev.attachment = a
    let cfg = VZVirtualMachineConfiguration()
    cfg.networkDevices = [dev]
    // A bootloader is required for validate() to reach the network check.
    print("attachment constructed: \(a)")
}
