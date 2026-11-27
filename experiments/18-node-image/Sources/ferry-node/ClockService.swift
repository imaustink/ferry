// The Mac's clock, offered to a machine over vsock.
//
// A machine's guest keeps time with the virtual counter, and that counter does
// not advance while the Mac sleeps. So a node VM that is up across a sleep
// wakes as far behind the Mac as the Mac was asleep, and nothing in the guest
// ever notices: measured on a cluster, every pod on one machine stayed 826s
// behind for more than a day, while a machine booted after the sleep was right.
// Everything that compares a timestamp made on the Mac with one made in a pod
// broke -- signed webhooks refused as stale, a JWT accepted after it expired.
//
// Pod VMs do not have this problem because Containerization pushes the host's
// time to vminitd every 30 seconds (its TimeSyncer). A machine has no vminitd,
// so it asks instead: the guest's init connects to this port every few seconds
// and is handed one line, the Mac's time of day, which it sets when its own
// clock has wandered. vsock rather than the network, so the Mac listens on
// nothing another host could reach.

import Foundation
import Virtualization

/// The vsock port a machine's init asks for the time on. Also in init.sh.
let clockServicePort: UInt32 = 7100

/// One reading of the Mac's clock as the guest reads it: seconds and
/// microseconds since the epoch, in the `@<seconds>.<fraction>` form GNU date
/// takes after `-s @`.
func clockReading(_ tv: timeval) -> String {
    "\(tv.tv_sec).\(String(format: "%06d", Int(tv.tv_usec)))\n"
}

/// Answers each connection with the Mac's time and closes it.
final class ClockService: NSObject, VZVirtioSocketListenerDelegate {
    let listener = VZVirtioSocketListener()

    override init() {
        super.init()
        listener.delegate = self
    }

    /// Listens on the machine's socket device. Called on the VM's queue, after
    /// it has started. A machine configured without a socket device -- none is,
    /// but an older configuration could be -- simply gets no clock service.
    func attach(to vm: VZVirtualMachine) {
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else { return }
        device.setSocketListener(listener, forPort: clockServicePort)
    }

    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        var tv = timeval()
        gettimeofday(&tv, nil)
        let line = Array(clockReading(tv).utf8)
        _ = line.withUnsafeBytes { write(connection.fileDescriptor, $0.baseAddress, $0.count) }
        connection.close()
        return true
    }
}
