# 12 — what actually contends on this Mac

**Two Metal matmuls share one GPU and gain nothing from running at once. A matmul
and an on-device generation do not contend at all: they are different silicon.**

```
device: Apple M4 Max
matmul 4096x4096 x120 per run, generation ~400 words

two matmuls
  one alone     12768 GFLOP/s
  two at once   6505 + 6424 = 12930 GFLOP/s (101% of one)
  -> the same GPU, split. Serialising these loses nothing.

a matmul and a generation
  generation alone  9.60s (2759 chars, 3.48ms/char)
  together          matmul 12652 GFLOP/s (-0.9%), generation 3.06ms/char (-12.0%)
  -> different silicon. Serialising these costs the whole overlap.
```

## Why this was asked

`ferry-gpud` handed out one device token: one pod's work at a time, whatever
kind. That is the safe assumption, and safe assumptions cost throughput when
they are wrong — so which is it?

The question is not rhetorical for the second case. Apple's on-device model does
not run on the GPU's shaders; the Neural Engine is separate silicon. A token
that covers both would be a token too coarse, and every generation would block
every matmul for no reason at all.

## Findings

**Two matmuls split one GPU.** 6505 + 6424 against 12768 alone — the total does
not move. Running them concurrently buys one percent and costs both of them
half their speed each, which also makes every GFLOP/s number the daemon reports
meaningless. Serialising Metal work against Metal work is correct.

**A matmul and a generation ignore each other.** The matmul lost 0.9%, which is
inside run-to-run variance; the generation was, if anything, quicker per
character. Whatever the model is using, it is not the shaders the matmul wants.

**Per character, not per second.** Generation length varies between runs — the
same prompt gave 2759 and 3077 characters on different attempts — so wall time
alone would have suggested the concurrent run was 7% slower when it was not.
Dividing by characters produced is what makes the two runs comparable.

## What ferry does with this

Lanes. One scheduler per unit of silicon rather than one for the machine:

- **compute** — Metal work, serialised, because the first measurement says
  concurrency there is worthless.
- **model** — the on-device model, independent, because the second says
  concurrency here is free.

Within a lane, everything as before: round-robin across pods, priority, time
slices, deadlines, cancellation. Across lanes, nothing — a pod generating text
and a pod multiplying matrices never wait for each other.

Measured through `ferry-gpud` afterwards, a small matmul's wait:

```
nothing else running                         0.096s 0.083s 0.083s
a generation running (other lane)            0.104s 0.086s 0.087s   <- no wait
another matmul running (same lane)           0.098s 0.580s 0.579s   <- the slice
```

Before lanes, that middle row cost 0.26–0.77s with the generation yielding, and
3.37s without. It is now indistinguishable from an idle machine, and the
generation is no longer interrupted at all — it reports zero yields, because
nothing needs it to step aside.

## What this does not show

- **Only two kinds of work.** Metal compute and the system model. A third thing
  — a Core ML model, a video encode, Metal with a different memory profile —
  would need its own measurement before assuming which lane it belongs in.
- **One size of matmul.** 4096x4096 saturates this GPU. A workload too small to
  fill it might well share, in which case serialising the compute lane costs
  something. Not measured.
- **Nothing about memory.** Both ran comfortably; two large allocations
  competing for unified memory is a separate question.
- **This machine.** An M4 Max. The split between GPU and Neural Engine is an
  architectural property, so the shape should hold across Apple silicon, but the
  numbers are this one's.

## Running it

```sh
./build.sh
./contention
```

Takes about a minute. No entitlement and no cluster: it talks to Metal and the
on-device model directly, which is the point — it measures the machine, not
ferry.
