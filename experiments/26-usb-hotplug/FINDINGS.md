# A disk can be attached to a running machine, over USB

A machine's devices are fixed when it boots, so a PersistentVolume that
arrives later has had nowhere to go but a directory in a virtiofs share. The
Mac user serves virtiofs, so `chown` on it fails with EPERM. That is the whole
reason mode 2 volumes cannot be chowned, and the reason mode 1 gives a
ReadWriteOnce claim to one pod VM at a time.

Virtualization.framework cannot hot-add a virtio device. Since macOS 15 it can
attach a USB mass-storage device to a live xHCI controller, with
`VZUSBController.attach(device:completionHandler:)`. This experiment asks
whether that is good enough to put a volume's ext4 image under a running
machine's kernel.

**It is.** Attach is immediate, the guest finds the disk in about a second,
`chown` works and persists, a surprise removal is survived, and the only cost
is synced small writes at about a fifth of virtio's rate.

## What was changed to ask

- `usb-storage.config` (now `kernel/usb-storage.config`, part of every kernel
  build, see experiment 33), appended to Apple's kernel configuration by
  `CONFIG_FRAGMENT=... OUT=... kernel/build-kernel.sh`. Apple's configuration
  has neither USB nor SCSI disks (`# CONFIG_USB_SUPPORT is not set`,
  `# CONFIG_SCSI is not set`). Nine symbols add xHCI, usb-storage, UAS and `sd`.
- `ferry-node`, behind `FERRY_NODE_USB=1`. Machines boot with a
  `VZXHCIControllerConfiguration`, and `serve` makes each machine's attached USB
  disks match the image paths listed in `<machines-dir>/<name>.usb`.

Run on one machine, `worker-u`, from a privileged pod entering the host's
namespaces. The disk is a copy of a volume image ferry-cri had already
formatted and a pod had written to.

## Attach, mount, chown, detach

```
ferry-node: usb: attached .../vol-a.ext4 in 0ms
guest:      usb-storage 2-1:1.0: USB Mass Storage device detected      [7.874]
            scsi 0:0:0:0: Direct-Access  Apple  Virtual Disk
            sd 0:0:0:0: [sda] Attached SCSI disk                         [8.918]
```

The framework's attach returns at once. The guest takes about a second, most of
it usb-storage's SCSI scan delay. The filesystem mounted with the earlier pod's
subPaths intact (`app`, `cache`, `seed`, all `0777`), and as root in the
machine:

```
echo from-machine > /mnt/usb/written && chown 1234:5678 /mnt/usb/written
-rw-r--r-- 1 1234 5678 13 ... /mnt/usb/written
```

After unmounting, detaching (`USB disconnect, device number 2` in the guest) and
attaching again, the file and its ownership were both there. The data lives in the image
on the Mac, so the same disk can go to another machine.

## Telling disks apart

USB gives nothing to match on. Every disk is `Apple  Virtual Disk`, there is no
VPD serial, and the device's UUID from the framework appears nowhere in the
guest. The name is not stable either. A disk attached again after an unclean
removal came back as `sdb`, with the old `sda` still held by its dead mount.

The **ext4 superblock's UUID** is stable, and ferry chooses it, because
ferry-cri formats every image. Read on the Mac at byte 1024+0x68 and in the
guest from the device at the same offset, two attached disks matched exactly:

```
on the Mac: vol-a d92c1910-18c5-42da-a1f3-35d237f7ba33  vol-b 21e76d0e-...
in guest:   sda fs-uuid=d92c191018c542daa1f335d237f7ba33 usb-port=usb2/2-1
            sdb fs-uuid=21e76d0e71de457884e2cf6062eeb50e usb-port=usb2/2-2
```

## What it costs

2000 writes of 4 KiB with `oflag=dsync`, each one a commit:

| | throughput | per write |
| --- | --- | --- |
| USB mass storage, ext4 | 9.8 MB/s | 0.42 ms |
| the machine's own virtio disk | 50.8 MB/s | 0.08 ms |
| the virtiofs volumes share | 36.9 MB/s | 0.11 ms |

That is about 2,400 synced writes a second against virtio's 12,400, a fifth of
the machine's own disk and plenty for a development database. Large sequential
writes were not measured meaningfully, because the image was 384 MiB and host
caching returned the rest. They are not what usually limits a volume.

## Pulled while being written

A disk mounted and being appended to was detached underneath the guest:

```
EXT4-fs error (device sda): ext4_journal_check_start: Detected aborted journal
EXT4-fs (sda): Remounting filesystem read-only
```

The guest did not panic or hang. Attached again (as `sdb`) and mounted, it
recovered:

```
EXT4-fs (sdb): recovery complete
```

All 400 lines written before an explicit `sync` were there. The unsynced tail
was not, which is what a journal promises and all it promises. So a machine
that dies holding a disk leaves it recoverable, and the next machine's mount
replays the journal. The images must stay journalled, which ferry-cri already
requires.

## What this makes possible

- **ReadWriteOnce as Kubernetes defines it, in mode 2.** A claim's image is
  attached to the machine its pod lands on, mounted once, and bind-mounted into
  every pod there. That gives one node, many pods, and working `chown`. The
  image is on the Mac, so a replacement machine can take it once the old one
  lets go.
- The natural shape is a CSI driver. Its node plugin, in the machine, asks
  ferry-node to attach the image, finds the device by filesystem UUID, and
  mounts it at the staging path. One machine at a time per image, with the
  same claim-and-lock ferry-cri uses for pod VMs.
- **Possibly mode 1's late-device limit**, which is why a crash in a
  multi-container pod rebuilds the whole pod. The device half is solved here.
  The other half, Containerization refusing to start a stopped container
  again, is not.


## What was not tested

- The kernel was booted in machines and mode 1 pod VMs alike without trouble,
  but its effect on boot time was not measured. The drivers only probe when a
  controller exists, and only machines get one.
- Many disks on one controller, and how many one xHCI controller will take.
- Detach while a machine is under heavy I/O from several pods.
