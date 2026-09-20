// How long does a vmnet subnet stay reserved after the process using it dies,
// and does asking for it repeatedly make that longer?
//
// Experiment 07 established the mechanism: the reservation lives as long as the
// vmnet_network_ref, CFRelease ends it, and Containerization's VmnetNetwork
// never releases. It measured about a minute for a subnet ferry had used, which
// is tolerable. What ferry actually hit is not a minute -- a slice stayed
// refused across a 90-second wait, a three-minute quiet wait and several
// restarts, and came back instantly only after a reboot.
//
// The suspicion is that asking renews it: ferry-cri polls every three seconds
// for ninety, and every one of those is a vmnet_network_create. If a refused
// create still touches the reservation, a retry loop is the one thing that
// guarantees it never expires, and waiting quietly is strictly better than
// trying hard.
//
// `poll <gateway>`   asks once a second until it succeeds, and reports elapsed.
// `quiet <gateway> <seconds>` waits without asking, then asks once.
//
// Run them against the same subnet on comparable runs and the difference, if
// there is one, is the answer.

import Foundation
import vmnet

func release(_ ref: vmnet_network_ref) {
    Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(ref)).release()
}

func make(_ gateway: String) -> (vmnet_network_ref?, vmnet_return_t) {
    var status: vmnet_return_t = .VMNET_FAILURE
    guard let config = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
        return (nil, status)
    }
    vmnet_network_configuration_disable_dhcp(config)
    var ga = in_addr(), ma = in_addr()
    inet_pton(AF_INET, gateway, &ga)
    inet_pton(AF_INET, "255.255.255.0", &ma)
    guard vmnet_network_configuration_set_ipv4_subnet(config, &ga, &ma) == .VMNET_SUCCESS else {
        return (nil, .VMNET_FAILURE)
    }
    let ref = vmnet_network_create(config, &status)
    return (ref, status)
}

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

let args = CommandLine.arguments.dropFirst()
let mode = args.first ?? "poll"
let gateway = args.dropFirst().first ?? "192.168.44.1"
let started = Date()

switch mode {
case "poll":
    // Ask once a second. If asking renews the reservation this never returns,
    // or returns far later than the quiet run.
    var attempts = 0
    while true {
        attempts += 1
        let (ref, status) = make(gateway)
        if let ref {
            let elapsed = Int(Date().timeIntervalSince(started))
            print("\(stamp()) got \(gateway) after \(elapsed)s and \(attempts) attempts")
            release(ref)
            exit(0)
        }
        if attempts == 1 { print("\(stamp()) \(gateway) refused (\(status)); asking every second") }
        if attempts % 30 == 0 { print("\(stamp())   still refused after \(attempts) attempts") }
        if attempts > 600 {
            print("\(stamp()) gave up after \(attempts) attempts")
            exit(1)
        }
        Thread.sleep(forTimeInterval: 1)
    }

case "quiet":
    // Wait without touching vmnet at all, then ask exactly once.
    let seconds = Double(args.dropFirst(2).first ?? "60") ?? 60
    print("\(stamp()) waiting \(Int(seconds))s without asking")
    Thread.sleep(forTimeInterval: seconds)
    let (ref, status) = make(gateway)
    if let ref {
        print("\(stamp()) got \(gateway) on the first ask after \(Int(seconds))s")
        release(ref)
        exit(0)
    }
    print("\(stamp()) still refused after \(Int(seconds))s quiet: \(status)")
    exit(1)

case "hold":
    // Hold it, so the other side of the test has something to wait for.
    let (ref, status) = make(gateway)
    guard let ref else {
        print("could not hold \(gateway): \(status)")
        exit(1)
    }
    print("\(stamp()) holding \(gateway); kill me to release")
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    source.setEventHandler {
        print("\(stamp()) releasing \(gateway) explicitly")
        release(ref)
        exit(0)
    }
    source.resume()
    dispatchMain()

default:
    print("usage: wait <poll|quiet|hold> <gateway> [seconds]")
    exit(2)
}
