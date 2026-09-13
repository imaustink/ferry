// Does a vmnet network reservation come back when it is released?
//
// ferry burns one subnet per run and carries fifteen fallbacks for exactly that
// reason; after enough restarts every one is refused with VMNET_FAILURE. The
// header says the reservation lives as long as the vmnet_network_ref and that
// CFRelease ends it, but Containerization's VmnetNetwork holds that reference in
// a struct and never releases it. This asks the framework directly.

import Foundation
import vmnet

// vmnet_network_ref imports as an OpaquePointer, so Swift does not manage it and
// CFRelease is unavailable. Unmanaged does the same thing explicitly.
func release(_ ref: vmnet_network_ref) {
    Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(ref)).release()
}

func make(_ gateway: String, _ mask: String) -> (vmnet_network_ref?, vmnet_return_t) {
    var status: vmnet_return_t = .VMNET_FAILURE
    guard let config = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
        return (nil, status)
    }
    defer { /* configuration is released with the network below */ }
    vmnet_network_configuration_disable_dhcp(config)
    var ga = in_addr(), ma = in_addr()
    inet_pton(AF_INET, gateway, &ga)
    inet_pton(AF_INET, mask, &ma)
    guard vmnet_network_configuration_set_ipv4_subnet(config, &ga, &ma) == .VMNET_SUCCESS else {
        return (nil, .VMNET_FAILURE)
    }
    let ref = vmnet_network_create(config, &status)
    return (ref, status)
}

let mask = "255.255.255.0"
let mode = CommandLine.arguments.dropFirst().first ?? "cycle"

switch mode {
case "cycle":
    // The same subnet, created and released, ten times. If the reservation is
    // freed by CFRelease this never fails; if it leaks, the second attempt does.
    let gateway = "192.168.44.1"
    for attempt in 1...10 {
        let (ref, status) = make(gateway, mask)
        guard let ref else {
            print("attempt \(attempt): FAILED with \(status)")
            exit(1)
        }
        release(ref)
        print("attempt \(attempt): created and released \(gateway)")
    }
    print("\nRESULT: the same subnet can be reclaimed after CFRelease")

case "hold":
    // Distinct subnets, never released, to find the ceiling.
    var held: [vmnet_network_ref] = []
    for third in 20...60 {
        let gateway = "192.168.\(third).1"
        let (ref, status) = make(gateway, mask)
        guard let ref else {
            print("held \(held.count) networks, then \(gateway) FAILED with \(status)")
            for r in held { release(r) }
            print("released them all")
            exit(0)
        }
        held.append(ref)
    }
    print("held all \(held.count) without hitting a limit")
    for r in held { release(r) }

case "leak":
    // One subnet, created and deliberately not released, then the process exits.
    // Run twice: if the second run fails, the reservation outlived the process.
    let gateway = "192.168.45.1"
    let (ref, status) = make(gateway, mask)
    print(ref == nil ? "FAILED with \(status)" : "created \(gateway), exiting without CFRelease")

default:
    print("usage: probe [cycle|hold|leak]")
}
