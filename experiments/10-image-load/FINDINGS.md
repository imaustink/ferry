# Running an image you just built

Everything else in ferry comes from a registry, which is fine for busybox and
useless for the thing you are working on. `minikube image load` and `kind load
docker-image` exist for exactly this, and ferry had no answer at all -- a locally
built image could not be run.

## It was already there

Apple's Containerization framework has `ImageStore.load(from:)`, which takes an
OCI layout directory. Nothing needed inventing; it needed reaching.

The load has to happen inside `ferry-cri`, because that process owns the image
store, so it arrives as one more operation on the socket `ferry-cri` already
listens on. The CLI turns whatever it was given into a layout first: a directory
is used as-is, an archive is unpacked, and a name is exported from Docker or
Podman.

An image keeps the name it carries, so a manifest that says `ferry-demo:built-here`
still says that.

## Verified

```
$ ferry image load /tmp/ferry-demo-image
  loading into the image store
  ✓ loaded docker.io/library/ferry-demo:built-here

$ kubectl get pod demo
POD    IMAGE                                     IP
demo   docker.io/library/ferry-demo:built-here   10.244.0.8

  reached it: built-on-this-mac from demo
```

The pod sets `imagePullPolicy: Never`, so nothing could have quietly fetched it
from anywhere. Both an OCI layout directory and an archive of one work.

## The test builds an image rather than borrowing one

`build-image.sh` makes a real OCI image with no Docker involved: a Go binary
built for linux/arm64 with CGO off is a whole image's worth of content in one
file, so the image is one layer holding one executable that serves HTTP.

That matters for what is being tested. Pulling an image and saving it back would
exercise the plumbing while missing the point, which is running something that
exists nowhere else. It also means the test needs nothing installed -- Docker
Desktop was wedged on this machine at the time, which is how the script came to
exist.

## Known limits

- **One node.** An image is loaded into the node it was run against; another Mac
  in the cluster does not have it. `minikube` has the same property per profile.
  Loading on each node works, and a pod must be scheduled where its image is.
- **Docker's default `save` format is not an OCI layout.** ferry says so rather
  than failing obscurely, and suggests `podman save --format oci-archive` or a
  Docker with the containerd image store.
- The image is unpacked to a root filesystem at load time rather than at first
  use, so a pod does not sit waiting on it.
