import Foundation
import vmnet

// Which physical interfaces can vmnet bridge onto?
if let list = vmnet_copy_shared_interface_list() {
    let n = xpc_array_get_count(list)
    print("bridgeable interfaces: \(n)")
    for i in 0..<n {
        if let s = xpc_array_get_string(list, i) { print("  - \(String(cString: s))") }
    }
} else {
    print("vmnet_copy_shared_interface_list returned NULL")
}

// Can a bridged network be created at all with only com.apple.security.virtualization?
var status: vmnet_return_t = .VMNET_FAILURE
if let cfg = vmnet_network_configuration_create(.VMNET_BRIDGED_MODE, &status) {
    print("bridged config created (status \(status))")
    if let ref = vmnet_network_create(cfg, &status) {
        print("BRIDGED NETWORK CREATED (status \(status))")
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(ref)).release()
    } else {
        print("bridged network REFUSED with \(status)")
    }
} else {
    print("bridged config refused with \(status)")
}
