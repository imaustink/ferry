// Does a vmnet network held by one process survive another process that
// rehydrated it and then died uncleanly?
//
//   owner  SUBNET_GW FILE   create the network, write its serialization to FILE,
//                           hold it; release it cleanly (CFRelease) on SIGTERM
//   join   FILE             rehydrate it from FILE, as a client of the owner
//                           would, and hold it
//   create SUBNET_GW        ask for the subnet fresh, once, and release it
//
// Ask `create` once per subnet and per question: a refused create renews the
// reservation it was refused by (experiment 22), so asking twice spoils the
// answer to the second ask.

import Foundation
import vmnet

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments

func configuration(_ gateway: String) -> vmnet_network_configuration_ref {
    var status: vmnet_return_t = .VMNET_FAILURE
    guard let cfg = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
        print("config refused \(status)"); exit(1)
    }
    vmnet_network_configuration_disable_dhcp(cfg)
    var ga = in_addr(), ma = in_addr()
    inet_pton(AF_INET, gateway, &ga); inet_pton(AF_INET, "255.255.255.0", &ma)
    _ = vmnet_network_configuration_set_ipv4_subnet(cfg, &ga, &ma)
    return cfg
}

func release(_ ref: vmnet_network_ref) {
    Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(ref)).release()
}

switch args.count > 1 ? args[1] : "" {
case "owner":
    var status: vmnet_return_t = .VMNET_FAILURE
    guard let net = vmnet_network_create(configuration(args[2]), &status) else {
        print("owner: refused \(status)"); exit(1)
    }
    guard let blob = vmnet_network_copy_serialization(net, &status),
          let inner = xpc_dictionary_get_value(blob, "networkSerialization") else { exit(1) }
    try! Data(bytes: xpc_data_get_bytes_ptr(inner)!, count: xpc_data_get_length(inner))
        .write(to: URL(fileURLWithPath: args[3]))
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { release(net); print("owner: released"); exit(0) }
    term.resume()
    print("owner: holding \(args[2])")
    dispatchMain()

case "join":
    let data = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
    let dict = xpc_dictionary_create(nil, nil, 0)
    data.withUnsafeBytes { xpc_dictionary_set_data(dict, "networkSerialization", $0.baseAddress!, $0.count) }
    var status: vmnet_return_t = .VMNET_FAILURE
    guard let net = vmnet_network_create_with_serialization(dict, &status) else {
        print("join: refused \(status)"); exit(1)
    }
    print("join: holding")
    dispatchMain()

case "create":
    var status: vmnet_return_t = .VMNET_FAILURE
    if let net = vmnet_network_create(configuration(args[2]), &status) {
        print("create \(args[2]): GOT IT")
        release(net)
    } else {
        print("create \(args[2]): refused \(status)")
    }

default:
    print("usage: owner GW FILE | join FILE | create GW"); exit(2)
}
