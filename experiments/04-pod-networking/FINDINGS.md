# Experiment 04: Routable per-pod networking

**Question.** This is the last open design question. Every pod needs an
address that is stable, reachable from the Mac, and reachable from other pods.
Experiment 03 proved 128 VMs can each *hold* a NIC. It did not show that
anything useful was on the other end.

**Method.** A Swift probe against Apple's Containerization framework 0.45.0 on
macOS 26.6.2. Create a `VmnetNetwork`, allocate addresses from it, boot real
`LinuxPod`s running an Alpine rootfs, then probe from the host and from a second
pod.

## Result

```
==> ferry pod networking probe
    euid    501                      <- no root
    gateway 192.168.66.1  (this Mac)

==> allocating 2 pod addresses
    pod-1      192.168.66.2/24  gw 192.168.66.1
    pod-2      192.168.66.3/24  gw 192.168.66.1
    released pod-1 (192.168.66.2/24), reallocated as 192.168.66.4/24

==> booting pod at 192.168.66.5
    pod up in 0.32s
==> probing 192.168.66.5 from macOS
    reachable on attempt 1
==> second pod, pinging the first
    192.168.66.6 -> 192.168.66.5: YES

===== RESULT =====
pod -> pod     : YES
pod boot       : 0.33s
reachable      : YES
    64 bytes from 192.168.66.5: icmp_seq=0 ttl=64 time=0.343 ms
    2 packets transmitted, 2 packets received, 0.0% packet loss
==================
```

Everything the networking model needs:

| property | result |
|---|---|
| per-pod address allocation (IPAM) | `createInterface` / `releaseInterface`, with recycling |
| the Mac is the gateway | `192.168.66.1`, where the API server will advertise |
| host → pod | **0.34 ms**, 0% loss |
| pod → pod | **YES**, verified by the peer's exit status |
| privilege required | **none**, ordinary user |
| pod boot, real Alpine rootfs | **0.33 s** |

Pod boot here is a full pod: Linux 6.12.28 kernel, `vminitd`, an ext4 Alpine
rootfs unpacked from an OCI image, and a configured network interface. It took
0.33s, against 0.12s for the bare kernel in experiment 03.

## Two things to know

**`com.apple.vm.networking` is not required, and asking for it is fatal.** It is
a restricted entitlement. An ad-hoc signed binary claiming it is `SIGKILL`ed at
launch with exit 137, no output, and nothing in the log. `vmnet_network_create`
succeeds as an ordinary user with only `com.apple.security.virtualization`.

**Sign the binary at its final path.** Binaries signed inside `.build` and then
copied were killed on launch. `build.sh` copies first, then
signs.

A related trap while debugging both: Swift buffers stdout when it is not a
terminal, so a `SIGKILL` discards exactly the output that would say how far the
program got. The probe sets `setvbuf(stdout, nil, _IONBF, 0)`.

## What this settles for ferry

`RunPodSandbox` calls `createInterface(podID)` and passes the result to
`LinuxPod.Configuration.interfaces`. `RemovePodSandbox` calls
`releaseInterface`. Ferry chooses each pod's address, which is a CNI's job, and the framework
configures the guest.

It also fixes the API server's advertise address. `control-plane/up.sh`
currently advertises the LAN IP, which breaks the moment the Mac changes
networks. It should advertise the vmnet gateway, which is stable and reachable
from every pod. The certificate SANs from `pki.sh` already include
`192.168.64.1`, so the subnet needs to agree.

## Still open

- **kube-proxy.** ClusterIPs (`10.96.0.0/16`) still mean nothing on the host, and
  nothing programs Service DNAT inside the pod VMs. The options are kube-proxy
  in each pod VM (each pod has its own kernel and nftables), or a userspace
  proxy on the Mac.
- **Scale.** This ran two pods, not 128. Whether vmnet stays healthy at the VM
  ceiling is unmeasured.
- **DNS.** `LinuxPod.Configuration.dns` exists and is unused here. CoreDNS
  integration is untouched.

## Reproduce

```sh
../03-vm-ceiling/fetch-kernel.sh    # shared kernel
./build.sh
./podnet --count 2                  # full probe
./podnet --network-only             # IPAM only, no VMs
./podnet --hold 120                 # keep a pod up to poke at by hand
```
