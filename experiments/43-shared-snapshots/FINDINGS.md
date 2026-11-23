# One store of image snapshots per Mac

**Question.** ferry-cri turns each image into an ext4 disk before a pod VM
can boot from it. Until #96 it wrote `image-<digest>.ext4` in place and took
"the file exists" to mean "it is finished", and every node on a Mac
(`ferry node add`) unpacked its own copy. #96 moved unpacking to
Containerization's `SnapshotManager` (temp file, flush, rename; keyed by the
layers' chain ID). That left two questions:

1. Can the nodes on one Mac share a snapshot store, without one node's sweep
   deleting a snapshot another node is booting from?
2. What happens to a disk an older ferry-cri left half-written?

**Answer.** Both are handled, and `run.sh` checks each claim below (16 checks,
all passing, about a minute on a warm cluster).

## The design

- Every ferry-cri on a Mac unpacks into one store, `$FERRY_RUN/snapshots`
  (`--snapshots`, which `ferry` passes to node 0, added nodes and a joined Mac).
- Each node hard-links the snapshots it uses into its own `cri/images/`.
  The link count is the refcount: 1 means no node holds the snapshot.
- Removing an image, or a tag rebuilt to a new image, drops that node's link,
  and the shared snapshot is deleted when its count reaches 1. A startup
  sweep deletes only this node's own unused links and snapshots no node links
  to, so one node never removes another's snapshot.
- Racing nodes only cost time: a link that is already there is used, a
  snapshot deleted between unpack and link is unpacked again, and a link that
  can't cross devices falls back to a clone.
- An old `image-*.ext4` is adopted into the store only if its ext4 superblock
  reads back (`EXT4Reader`). The formatter writes the superblock last, so a
  disk that was never finished has none; it is deleted and unpacked again.

## What run.sh shows

| step | result |
|---|---|
| ferry-cri `SIGKILL`ed while unpacking a large image | only `.<key>.<uuid>.tmp` is left, no snapshot under that key; after `ferry restart` the image runs |
| two builds that differ only in `ENV` | each runs with its own environment; they share one snapshot |
| `ferry node add second`, then python and alpine on `second` | both ran in 3-4 s, no new snapshot, and `second`'s disks are the same inodes as the shared snapshots |
| a tag rebuilt (v1, then v2) | v1's snapshot is deleted as soon as v2 replaces it |
| an old, whole `image-*.ext4` | adopted in place: the snapshot has the same inode |
| an old disk of 50 MiB of zeros (never finished) | logged as "was never finished", unpacked again, and its pod runs |

Before the store was shared, each node had a store under its own state
directory, so an added node unpacked every image again. That baseline is not
measured here.

## Reproducing

```
experiments/43-shared-snapshots/run.sh
```

It runs against this checkout's ferry profile, which has to be up. It adds a
node called `second` and removes it on exit, and restarts ferry twice (once
after the kill, and `down`/`up` around the planted old disks). `BIG_IMAGE`
must be an image this Mac has not unpacked, or the crash step is skipped. The
default is `python:3.9-bookworm`; pick another on a second run.

A run that left a pod on an added node that is gone hangs a later
`kubectl delete --wait` on that pod; the script force-deletes the pods on
`second` before removing it for that reason.
