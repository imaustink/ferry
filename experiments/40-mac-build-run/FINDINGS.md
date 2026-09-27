# RUN, for a darwin image

`ferry-mkimage` rejects `RUN` with "a Linux builder cannot execute Darwin
binaries" -- true of the Go binary that writes an OCI layout, false of a real
macOS VM. This asks what it takes to run `RUN` there instead, and builds it far
enough to package a real image whose layer contains a file no `COPY` produced.

**Short version.** It works. A macOS VM, cloned from experiment 39's golden
bundle and driven entirely over the existing `ferry-macagent` vsock exec
protocol -- no guest changes at all -- ran three `RUN` steps in order, one of
them executing what an earlier one had just built, and the result packaged
into the same OCI layout `ferry-mkimage` writes today. **The one part of the
original design that does not work is the shared directory**: a writable (or
even read-only) virtiofs share denies the guest access, "Operation not
permitted", to anything tagged `com.apple.provenance` -- which, on the host
this was built on, was everything, non-removably. The fix ended up better
than the plan it replaced: files move as bytes through the same exec channel
`RUN` already uses, not through a filesystem both sides can see.

Run on the M4 Max / macOS 26.6.2 host in [experiment 39's
README](../39-macos-pods/FINDINGS.md), against its already-built golden bundle.

## What was built

| | |
|---|---|
| `macvm.swift` | experiment 39's host tool, plus one new subcommand: `build`, which clones a golden bundle, boots it, and runs one exec request per line of stdin |
| `agent.swift`, `dev.ferry.macagent.plist`, `entitlements.plist` | unchanged copies of experiment 39's -- the guest agent needed no changes |
| `mkimage-run/` | a Go driver: `ferry-mkimage`'s exact Dockerfile subset plus `RUN`, spawning `macvm build` as a coprocess and packaging the result with an unmodified copy of `ferry-mkimage`'s `oci.go` |
| `demo/` | a Dockerfile with a `COPY`, three interleaved `RUN`s, and an `ENTRYPOINT` |
| `build.sh`, `run-demo.sh` | build both tools; run the demo against experiment 39's golden bundle |

## The protocol: relay agent.swift's own frames, not JSON

`macvm build <golden>` clones the golden bundle, boots it, and then, per line
of stdin, decodes a `{"argv":[...],"env":{...},"cwd":"..."}` request and sends
it to `ferry-macagent` exactly as `macvm pod`'s existing `run()` does. The
difference is what happens to the response: instead of printing frames to the
console, `build` mode relays them byte-for-byte -- the same `[type u8][length
u32 BE][payload]` framing agent.swift already emits, type 1 stdout, 2 stderr,
3 exit, 4 error -- onto fd 3, which the parent process reads as its
unambiguous, ordered result stream. No second, JSON-encoded status channel was
needed once this was factored out: the exit frame *is* the status, arriving
strictly after every byte of that command's output because agent.swift itself
only sends it once `waitpid` and both stdout/stderr pumps have finished.

On stdin EOF, `build` shuts the guest down (`shutdown -h now`, the same as
`macvm pod`), deletes its cloned bundle, and exits.

This is a small, mechanical addition -- about 80 lines -- entirely in the host
tool. `agent.swift`, the thing actually running as root in the guest before
Setup Assistant, is byte-for-byte what experiment 39 already shipped.

## The dead end: a writable virtiofs share

The original plan mirrored a bind mount: give the guest a **writable**
virtiofs share (`VZSharedDirectory(..., readOnly: false)`, one line different
from experiment 39's read-only `ferry-config`/`ferry-logs` shares), `COPY`
into it from the host, `mount_virtiofs` it in the guest, run `RUN` with that
directory as `cwd`, and let whatever it left behind be picked up from the host
side directly -- no transfer step, because it was already the same directory.

`mount_virtiofs` reported success. `ls` on the mounted directory did not:

```
$ ./build/macvm pod .cache/golden /tmp/diag-pod --share /tmp/ro-share -- /bin/sh -c '
mount_virtiofs ferry /private/var/ferry/share
ls -la /private/var/ferry/share'
mount_status=0
ls: /private/var/ferry/share: Operation not permitted
```

as **root**, on a directory `stat` reported `drwxr-xr-x`. The tell was `ls
-lade`, which reads the directory's own attributes without opening it: `@`,
meaning extended attributes. On the host side:

```
$ xattr -l /tmp/ro-share/f.txt
com.apple.provenance:
```

present on a file created moments earlier by an ordinary shell redirect, and
**not removable** -- `xattr -d com.apple.provenance` reports success and
changes nothing, on every file this environment's tools create, including
files already checked into this repository before this session touched them.
`/etc/hosts` has no such attribute; nothing this session created lacks one.
AppleVirtIOFS in this macOS refuses the guest read access to anything
carrying it, regardless of POSIX permissions and regardless of whether the
share is read-only or read-write.

Whether that is specific to this sandboxed environment or a general property
of macOS 26's virtiofs (a provenance-aware host protecting a guest from
supply-chain-tainted shared files would be a reasonable thing for Apple to
ship) was not resolved -- there was no second, differently-provisioned Mac to
compare against. Either way, a design that depends on host files being
directly readable through a shared mount is not one `ferry-mkimage` can rely
on: **the build context is exactly the kind of externally-sourced content this
protection would reasonably exist for.**

## The fix: files as bytes over the exec channel, not the filesystem

`macvm build` and `agent.swift` never gained a file-transfer primitive.
Instead, `COPY` and the final extraction both ride `RUN`:

- **`COPY`** stages its sources into a throwaway host directory using
  `ferry-mkimage`'s own `applyCopy` (same file-vs-directory-contents rules,
  same destination naming), tars that directory, base64-encodes it, and sends
  one `RUN`-shaped request: `/bin/sh -c "mkdir -p $ROOT && printf '%s'
  '<base64>' | base64 -d | tar -x -C $ROOT"`. The bytes never touch a
  filesystem the guest and host both see; the guest writes them to its own
  disk, where they carry no host provenance at all.
- **`RUN`** executes directly, cwd set under a fixed guest directory
  (`/private/var/ferry/build`) that every step shares. It is **not**
  chrooted: the guest's real `/usr/bin/clang`, `/bin/sh`, Homebrew, whatever
  the golden image carries, must stay visible, the same "the node provides the
  OS" reasoning that makes a darwin pod `FROM scratch` in the first place. One
  consequence: `RUN`'s own paths are relative to its `cwd`/`WORKDIR`, not to
  the eventual image root the way a chrooted build's would be. The demo's
  Dockerfile writes `RUN sed ... > hello`, not `RUN ... > /hello`.
- **Extraction**, once, after the last step: `tar -C $ROOT -c . | base64`,
  captured off the same stdout-frame path every `RUN`'s output already takes,
  decoded, and untarred into the host directory `ferry-mkimage`'s
  `writeLayout` packages exactly as it does today.

Base64 over an exec argument is not how this should ship -- it inflates
payloads a third and the whole request is one line of JSON, so it does not
stream and is bounded by how much a shell/`posix_spawn` argv can hold. It was
the right amount of engineering for a proof: **a single, small, genuinely
useful protocol change** -- giving `agent.swift`'s spawned process a real
stdin, fed by more bytes on the same connection instead of `/dev/null` -- would
replace both the base64 encoding and the argv-size ceiling with an ordinary
`tar -x`/`tar -c` piped over the wire. That change is scoped and low-risk
precisely because everything else here (the frame format, the request shape,
the ordering guarantees) already works and would not need to change with it.

## Proof: a later RUN running an earlier RUN's output

`demo/Dockerfile`:

```dockerfile
FROM scratch
COPY hello.sh.tmpl src/hello.sh.tmpl
ENV NAME=RUN
RUN sed "s/@NAME@/$NAME/" src/hello.sh.tmpl > hello
RUN chmod +x hello
RUN ./hello
ENTRYPOINT ["/hello"]
```

```
$ ./run-demo.sh
   0.00s  cloned golden bundle in 2.1 ms
   0.22s  build: VM started in 0.20s
   8.95s  build: agent answering
hello, RUN -- built by RUN inside a macOS VM
  15.30s  build: guest stopped
example.com/hello-darwin:1: darwin/arm64, layer sha256:4679a4085799 (236 bytes), manifest sha256:54b435728df1

==> OCI layout written to a temp dir and discarded; layer contents:
-rwxr-xr-x  0 root   wheel      62 Dec 31  1969 hello
drwxr-xr-x  0 root   wheel       0 Dec 31  1969 src/
-rw-r--r--  0 root   wheel      65 Dec 31  1969 src/hello.sh.tmpl
```

That output line came from the guest actually running `./hello` mid-build --
the file the *second* `RUN` produced, made executable by the *third*, whose
`$NAME` substitution came from an `ENV` set before any of them. The packaged
layer's `hello` is `-rwxr-xr-x`: the `chmod` survived the trip back. None of
this is reachable by `COPY` alone.

A failing `RUN` was also exercised (the golden bundle used here has no Xcode
Command Line Tools installed -- a fresh macOS install with no GUI session to
accept their license, a gap in *this* golden image, not in the mechanism):

```
demo/Dockerfile: RUN /bin/sh -c clang -O2 -o bin/hello src/hello.c: exit 1
```

correctly aborting before any packaging, with the failing command and its
exit code in the error, the same as `ferry-mkimage`'s existing `COPY` errors
read today.

## What it costs

Three runs of the full demo (clone, boot, `COPY`, three `RUN`s, extract,
package, shut down):

| | |
|---|---|
| clone (APFS clonefile) | ~1-2 ms |
| boot to `ferry-macagent` answering | 8.2-9.0 s |
| the build itself (3 `RUN`s + COPY + extract) | well under 1 s |
| shutdown | ~5.5-6.5 s |
| **total** | **~14.6-15.3 s** |

Boot and shutdown are experiment 39's numbers, not new ones -- this pays them
once per build, the way `ferry-builder` (buildkit) pays a boot once and stays
up between builds. A `RUN`-capable darwin build should do the same: keep the
builder VM warm across `ferry image build` invocations rather than
clone-boot-shutdown every time, exactly the pattern `ferry_builder_up`/
`ferry image build --stop` already established for buildkit.

## What would have to change to ship this

1. **`ferry-mkimage/dockerfile.go`**: replace the separate `copies
   []copyOp`/`entrypoint`/`env`/... fields with `mkimage-run/dockerfile.go`'s
   ordered `steps []step` (`copy`, `run`, `env`, `workdir`), and accept `RUN`.
   This experiment's version is close to a drop-in; `ENTRYPOINT`/`CMD`/`LABEL`
   don't interleave with anything and can stay as they are today.
2. **A `ferry-mac-builder` machine**, parallel to `ferry-builder`: booted from
   `FERRY_MAC_IMAGE`'s golden bundle (not the baked node image -- a builder
   needs no kubelet), kept warm across builds, torn down by `ferry image build
   --stop`. Needs network egress, since a real `RUN` (`brew install`, `curl`)
   will want it, unlike today's pod-network-scoped Linux builder.
3. **`macvm build`'s `run()` relay**, promoted out of this experiment folder
   into wherever ferry's Swift host tooling lives, becomes the thing
   `ferry-mkimage` spawns as a coprocess -- `mkimage-run/builder.go` is close
   to what that integration looks like.
4. **Real stdin on the agent's spawned process** (agent.swift currently opens
   fd 0 on `/dev/null` unconditionally): the one genuine protocol change,
   replacing this experiment's base64-in-argv `COPY`/extract with a streamed
   `tar -x`/`tar -c`, removing both the size ceiling and the encoding
   overhead.
5. **A decision on caching**: this proof tears down and reclones per build, so
   every build starts from a clean golden image. A warm, reused builder (item
   2) needs an explicit answer for what "clean" means between builds -- reset
   the guest's build directory each time, or let it carry state the way a warm
   buildkit pod's layer cache does.
6. **Docs and the rejection message**: `docs/RUNTIMES.md`'s "no RUN" section,
   `ferry image build --help`, and `ferry-mkimage/main_test.go`'s
   `"RUN should be rejected"` all currently assert this as permanent and would
   need to flip together.

Item 4 is the only piece here that is genuinely new engineering; everything
else is wiring already-proven pieces (the vsock protocol, the frame relay, the
ordered parser, the unmodified `oci.go`) into where `ferry-mkimage` and `ferry`
already do the equivalent thing for Linux.
