---
title: "Bringing Up the RK3576 NPU on Mainline Linux"
date: 2026-06-15
tags: ["linux", "rockchip", "npu", "embedded", "rk3576"]
description: "Two weeks of chasing all-zero NPU output on the RK3576 — the wrong theories, and the offset remap that finally made it compute."
showToc: true
draft: false
---

The RK3576 has a 6 TOPS NPU and the open-source `rocket` driver targets it. I got a
full MobileNet run going — 252 hardware jobs, no hangs, no faults — and every single
output byte was zero. This is roughly how the next two weeks went. Mostly it's me
being wrong a lot.

## The setup

- Radxa ROCK 4D (RK3576, 12 GiB LPDDR5)
- linux-next 7.1.0-rc5, `rocket` built into the kernel (not a module)
- MobileNetV1 224×224 through the Mesa Teflon TFLite delegate
- CPU reference: Top-1 = 653, conf ≈ 0.887

One thing kept me sane the whole time: `rocket` already runs this exact model
*perfectly* on the RK3588. So nothing about the driver was fundamentally broken. The
bug had to be something RK3576-specific — a value, an offset, a sequence the two chips
don't share. Whenever a theory tried to blame the whole architecture, that fact
talked me down.

## "Done" doesn't mean "computed"

First run looked great. 252 jobs, ~1.9 ms each, six runs in ~475 ms, no IOMMU faults,
no DMA errors. Kernel says every job is done.

Output: all zeros. Raw non-zero = 0 / 1001. Every run.

Turns out "job done" only means the command processor drained its instruction list
without choking. It says nothing about whether the convolution engines did any actual
math. That gap is the entire post.

So I stopped trusting "done" and wired up the hardware bandwidth counters — those read
straight off the NPU, the command processor can't fake them:

```
rocket dbg perf: dt_wr=0 dt_rd=<constant> wt_rd=0
```

`dt_wr` = bytes written to DRAM. `wt_rd` = weights fetched. Both zero, all 252 jobs,
every run. And `dt_rd` went up by the *same* amount every job no matter the layer
size — which for a net whose layers vary 100× in size can only be command overhead,
not real data.

Translation: the NPU takes the command stream, says done, and never moves a tensor.
Armed, enabled, configured, dead.

## The pile of dead theories

Before the real cause showed up I had to kill a bunch of reasonable-sounding ideas.
Each one cost a rebuild and a flash:

- **Ping-pong delay** — maybe each job fires the *previous* job's params and the last
  layer never triggers. Moved PP_CLEAR to the end so each job fires its own. Still
  zero.
- **Cache coherency** — maybe the NPU writes fine and the CPU reads stale cache. Added
  a write-combining DRAM read to dodge the cache. Input read back non-zero (cache path
  works), outputs read zero both ways. Nope.
- **Fence before writeback** — maybe completion signals before the write DMA lands.
  Added a sync barrier after op_en. No change.
- **Weight-fetch gate** — spent an afternoon sure the CNA read features but never
  weights. Then realized I was *summing* the top-level and per-core counters and
  reading constant descriptor-fetch traffic as if it were real. The theory was built
  on a misread counter. Lesson: don't trust an aggregate.

Slow, but each dead end shrank the box. By the end I'd ruled out clocks, MAC gating,
IOMMU, op_en actually reaching the units (`CNA_OPEN = CORE_OPEN = DPU_OPEN = 1`), and
every register *value* I could think to poke. Units enabled, config latched, nothing
running.

## The NVDLA model is the lens

`rocket` is built on NVDLA, and NVDLA's docs are public, so I used them for the mental
model. The bit that mattered is the producer/consumer ping-pong:

- `S_POINTER` bit 0 = PRODUCER — which group the CPU writes config into
- `S_POINTER` bit 16 = CONSUMER — which group the hardware is actually executing
- write to a group whose enable is already set and the writes get **silently dropped**

Reading my own logs through that lens flipped it. Across all 252 jobs:

- **DPU_RDMA** — consumer advanced, it ran a layer
- **CNA / CORE / DPU** — consumer stuck at 0, never finished a single layer

The one thing separating the unit that ran from the three that didn't: the three dead
ones are the **CBUF-backed convolution path**, RDMA isn't. So the gate was in
*starting* an already-configured, already-enabled conv pipeline. Staring at registers
wasn't going to get me further.

## Getting a reference command stream

If I couldn't reason it out, I'd compare against something known-good. Rockchip's
`rknn-toolkit2` (the official model converter) has an aarch64 wheel, so it runs right
on my dev host. No board needed:

1. build a one-Conv2d ONNX model (3→32, 3×3, s2 — MobileNet's first layer)
2. convert it for `rk3576` with quantization → a `.rknn`
3. walk the `.rknn` for the 64-bit command words, decode them per unit

Now I had a working RK3576 command stream for any conv I wanted, to diff against
whatever Mesa was emitting. Finally a way to ask: what's in a *working* first-conv
stream that mine doesn't have?

Later I captured the same thing live on the board too and it matched byte-for-byte
(139 entries). Good — the offline trick wasn't lying to me.

## The CNA_CLK_GATE red herring

First diff lit up a register Mesa never wrote at all: `0x1090 = 0x2a`. Mesa's header
(RK3588-era) called it `CNA_CLK_GATE`. An unset clock gate on the compute path is a
*perfect* suspect for "configured but never runs." Hardcoded it. Flashed.

Still zero.

But the way it was wrong is the actual key. I ran the same conv at 224×224 and 64×64
and diffed: `0x1090` changed, `0x2a → 0x0c`. A clock gate doesn't change with input
size. It's not a clock gate — on RK3576 it's a size-derived value (the CBUF input line
stride). Mesa had the *name* wrong, which means it had the whole *map* wrong.

That's the real shape of the bug: the RK3576 CNA register map is **shifted and
re-packed** vs RK3588. The chip inserts registers and slides the offsets down, so Mesa
was computing RK3588-flavored values and writing them into RK3576 registers that mean
something completely different.

## Two things had to be true

**A trigger.** Diffing the kernel-side submit against the reference, one thing stood
out — the interrupt mask programmed before the op_en pulse. With `INT_MASK = 0x300`,
the dead units finally moved:

```
CNA_STAT  0x1  → 0x20001   (STATUS_1 = 2 = RUNNING)
CORE/DPU  0x5  → 0x20005
DPU DST   0x0  → 0x00cb1000 (a real destination loaded)
```

(Brief detour: I first thought the trigger was a PC_DMA task-descriptor dispatch —
built the whole descriptor, units woke up, felt great. Then the live capture showed
the vendor sets that base to *zero*, same as `rocket`. It was the `INT_MASK` change
riding along that actually did it. Onto the pile. The live capture saved me from
shipping a wrong conclusion.)

**The right map.** Running still wasn't computing — units engaged then *stalled*,
`dt_wr` still zero, because they were configured through the wrong offsets. So I built
a little harness: generate a conv, change exactly one thing (width, then height, then
channels, then kernel, then stride), watch which registers move. One knob at a time
the RK3576 map fell out:

```
0x102c = (in_w-1)<<16 | (in_h-1)     # proven with a non-square 128×224 case
0x1030 lo = out_w-1,  hi = 32·k·k
0x1044 = in_w<<16 | (in_w/4)
0x1090 = in_w·4                      # the "clock gate" — it's a line stride
0x1094 = 0x1098 = in_w·in_h
```

CORE was just Mesa's CORE shifted +0x8 from `MISC_CFG` on; DPU followed the same
insert-and-shift. The whole port turned out to be a per-unit offset remap plus a few
constant fixes — not a rewrite. An offline checker predicted all 34 geometry/channel
registers across every captured shape with zero mismatch before I touched the board
again.

## It computed

Rewrote the first-conv encoder to the RK3576 map, flashed, watched job 0:

```
top[dt_rd=9408  wt_rd=96]
core[dt_wr=25088]
```

`dt_wr = 25088 = 112·112·2` — the full, correctly-sized first-layer output, written to
DRAM. Weights actually fetched. All four units engaged. After two weeks of zeros, a
convolution ran on the silicon. The whole approach — offset remap, in-stream arming,
patched DMA addresses — proven on hardware.

That was layer 0. The rest of the chain — depthwise, pointwise, the lot — was a
second act of its own, and it had more walls in it than I expected.

## Getting the whole chain to engage

For a while only the first conv wrote; every layer after it went back to zeros. Four
separate things were holding the rest of the chain down, and each one looked like the
last bug right up until it wasn't:

- **Task-chaining corruption.** Mesa chains multi-task jobs the RK3588 way — it ORs the
  next task's command address into the last two command entries, assuming those are the
  chaining slots. On RK3576 my command stream *ends in real RDMA registers*, so that
  "chaining" was scribbling an IOVA over a live DMA register and killing the write. The
  RK3576 kernel dispatches each task separately anyway (its own base address + op_en
  pulse), so the fix was: don't chain in-stream at all on RK3576. One unit's worth of
  silent corruption, gone.
- **The depthwise weight layout.** Depthwise layers hung outright. The CORE never
  opened — it sat waiting on weights it couldn't consume. RK3576 packs depthwise weights
  as spatial row-major blocks, two channels at a time with two zero-point pad bytes each
  (so a 32-channel 3×3 is 9 blocks × 64 bytes = 576 bytes, which is exactly what the CNA
  weight-size register asks for). Mesa was handing it a layout the convolution MAC
  couldn't read. That was the hang.
- **Ping-pong parity.** I burned a good while convinced the producer/consumer groups
  were desyncing per task — built a whole parity scheme in the kernel to alternate the
  pointer. Wrong: the working sequence keeps the pointer at group 0 *every* task and
  re-arms it per task. I'd been adding cleverness the hardware didn't want. Ripped it
  back out and forced group 0 to match.
- **The "windowed" mode that wasn't.** Mesa tiles the 112-wide layers into short row
  windows with a "capped" flag set. On RK3576 that capped mode just makes the DPU write
  nothing. A single full-height window (112 rows — it fits the RK3576 CBUF fine) makes
  depthwise and pointwise write. So the fix was *less* tiling, not more.

After those: conv0, depthwise, and pointwise all engage and all write varying output.
The engage wall — the entire subject of everything above — is finally behind me. Which
is a great feeling for about a day, until you look at the actual numbers.

## Running, but wrong

The NPU now computes a full chain. The output is still wrong — just wrong in a much more
interesting way than zeros. Layer 0's output comes back almost entirely `0x7f`:
saturated, pinned to the max. It's doing arithmetic, the arithmetic is just blowing past
the range.

To even see this I had to stop trusting the board's own debug registers — half of them
lie. The DPU destination registers are write-only and read back garbage; the
write-combining readback I'd relied on returns null on system RAM. The only honest
signal is a cache-invalidated DRAM dump of each task's real output address, plus a pure
numpy reference of the quantized model computed offline. With those two side by side the
saturation was obvious.

Root cause: **asymmetric weight zero-points.** MobileNet's weights are quantized with
per-tensor zero-points all over the map — 74, 95, 122, 151, 211 — almost none of them
the symmetric 128. Mesa centers weights at a fixed 128 and only corrects the *input*
zero-point in the bias. The leftover weight-zero-point term is a per-output-pixel
quantity nobody is subtracting, so the accumulator runs tens of thousands of counts hot
and clamps.

The genuinely surprising part — and the thing I'd never have guessed without comparing
against a captured working stream — is *where* the hardware expects that correction. It
is **not in the command stream and not in the weight values.** I proved that with a pair
of differential test convs (one symmetric, one all-positive zero-point): byte-identical
command streams, identically-centered weights. The weight zero-point is handled
data-side, in a per-channel coefficient table tucked into a bias buffer the
convolution's accumulator reads. Mesa allocates that buffer too small and fills in only
part of it. I've got the buffer's structure mostly decoded — per-eight-channel groups,
a per-channel offset field plus a couple of per-layer fields that encode the
requant/zero-point math — and a couple more differential captures should pin the last
field's meaning. Then it's a matter of having Mesa compute and emit the full table the
way the hardware wants it.

## For mainline

What's upstream-shaped already is a Mesa Teflon change (the RK3576 encoders, CBUF
geometry, SoC detection) plus a small kernel submit fix. All of it gated so the
**RK3588 path stays byte-for-byte identical** — the SoC is detected at runtime from the
device `compatible` string and the RK3576 encoders only kick in on RK3576. RK3588 users
notice nothing.

Everything here came the slow way: instrument, guess, flash, read the counters, let the
hardware tell you you're wrong. Most of my guesses were. The performance counters never
were — `dt_wr = 0` meant no compute no matter how clever I felt, `dt_wr = 25088` meant
it finally ran, and now a cache-invalidated DRAM dump versus an offline reference is the
witness for whether the *values* are right. With no public register docs, those honest
signals are the whole game; everything I believed in between was provisional.

So the state of it: the silicon runs every layer type and writes real, varying data —
the hard "does it compute at all" question is answered. What's left is quantization
correctness: finishing the per-channel weight-zero-point table so the numbers match the
reference, and re-deriving the first conv's quantization (it's still a hardcoded
stopgap from early bring-up). The chain runs end to end. Making every number bit-exact
is the part I'm on now.
