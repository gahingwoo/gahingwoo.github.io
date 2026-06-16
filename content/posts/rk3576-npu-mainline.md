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
part of it.

A handful more differential captures later — the trick is convs with constant
per-channel weights, so the per-layer fields stay clean while the per-channel ones go
flat — and the buffer fully gave up its structure. It's groups of eight output
channels, 64 bytes each, laid out as eight 32-bit fields, then eight 16-bit, then eight
more 16-bit. The 16-bit one is just `(128 − weight_zero_point)`, the exact correction
that was missing. The 32-bit field is that times the per-channel weight sum, pre-scaled.
The last field folds in the input zero-point. The hardware computes a per-output-pixel
input sum on its own and combines all of it: `result = Σ(in−128)(w−128) +
(128−wt_zp)·input_sum + bias`. I worked the algebra through against the offline
reference and it lands exactly. So I rewrote Mesa to emit the whole table.

And the output flipped — from saturated *high* (`0x7f`) to saturated *low*, pinned at
the layer's zero-offset. Which is, weirdly, great news: same clamp, opposite end. It
means the correction term is real and active and now slightly *too strong* rather than
absent — the difference between "you forgot a term" and "you have the term, off by a
constant." That constant looks like a factor of 128 in how the corrected accumulator is
scaled before requantization: the shift that converts back to 8-bit needs to account
for it. I had it pegged as the last mile.

## The conv wasn't even convolving

It wasn't, and what set me straight was a one-line change to my debug dump: print the
number of *distinct* values in each output, not just the first few bytes.

Conv0's output had **two distinct values.** Two. The entire 112×112×32 feature map was
`0x7f` and `0x80` — plus or minus one constant magnitude, sign flipping per pixel. That
is not a quantization-scaling problem. A real convolution produces a spread of
magnitudes; ±one constant means the MAC array was never spatially convolving the image
at all. Everything I'd been doing to the requant math was downstream of a conv that
wasn't happening. The clamp had flipped ends because the bias work *was* real — but it
was correcting a result that was garbage to begin with.

So I did the thing I should have done sooner: a full register-by-register diff of my
conv0 command stream against the captured vendor one, runtime addresses aside. One line
differed.

```
CNA 0x1064 (feature data offset)   vendor = 0   mine = 0x777
```

`0x777` is 1911. It was offsetting the feature fetch by 1911 bytes, so the MAC array
convolved the wrong data — the same wrong data everywhere, hence ±one constant. A
transcription typo in the hardcoded first-conv block; the normal-path encoder already
had it right at 0. Set it to 0, flash, and conv0's distinct-value count jumped from
**2 to 154** — a real, full-range feature map.

(That same diff also retired a "fix" I'd been proud of: computing the first conv's
requant from the model scales. The captured stream showed the original hardcoded values
were correct all along — the saturation I'd blamed on requant was *always* FC_CON1. I
reverted my own clever change. The detective work doesn't just find bugs; it finds the
ones you introduced chasing the wrong theory.)

## The vendor tiles; I didn't

Conv0 bloomed, and the chain promptly broke one layer later: the first depthwise came
out with five distinct values and everything after it went to zero. Same shape — good
input, good weights, degenerate output — so, same move: capture the vendor running the
*actual* chain and diff.

The vendor splits every 112-wide layer into **two row-windows** — about 90 rows, then
the remaining 22 — and runs each as its own task. I was running the whole layer as one
112-row window, on the theory that it fit the on-chip CBUF. It doesn't. The window
overran the buffer, the MAC read stale data, and the layer came out degenerate. The fix
was *more* tiling, not a register value: a greedy row-window split matching the vendor's,
plus correcting a batch of windowed-mode register values I'd had wrong. The encoder now
matches the captured vendor stream byte-for-byte on every windowed register, both
windows. Done and pushed.

## The real shape of it: one submit, not many

Then conv0 started flickering. Same command stream, same input image, and run to run it
gave me either the good 154-distinct map or the degenerate two values. That
non-determinism sent me down a long, instructive hole. I tried resetting the NPU between
runs — which wedged the IOMMU, because the reset line I had also resets the tightly
coupled IOMMU and the next job can't attach. I tried disabling autosuspend, soft
re-initing the ping-pong state, a warmup-retry that re-runs the first task. Each one
broke something else or fixed exactly half the problem — the geometry would latch, but
the compute core still wouldn't turn on.

That clue — geometry present, core won't engage — is what finally cracked it. I captured
how the vendor *dispatches* the graph. Not the register contents this time; the dispatch
itself. And the difference was the whole game:

```
vendor : one submit, task_number = 8   (the entire graph, pipelined)
mine   : one submit per task, task_number = 1
```

The vendor hands the command processor the **whole network at once** and lets it stream
through all eight tasks as one flowing ping-pong pipeline. The first conv is task 0 of a
pipeline that's already moving — it warms and engages naturally. I was submitting one
isolated task per job, so my first conv was always task 0 on a *cold* pipeline, and a
cold first task on this hardware never lights its compute core. The flicker, the
`CORE_OPEN = 0`, all of it: not a value anywhere, but the *shape* of how work reaches the
chip.

The bitter part: earlier in this project I'd made a deliberate call to *not* chain
tasks — "let the kernel dispatch them one at a time, simpler." The vendor capture says
that was exactly the wrong turn. The hardware wants the pipeline. So the current work is
reworking dispatch to submit the whole graph as a single pipelined job — which has
already collapsed one inference from 500-odd jobs to a single submit, with the last
detail (making every task in that pipeline land on the right ping-pong group) being what
I'm on now.

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

So the state of it: every layer type computes, the quantization math is right where I
can see it, and the big register typo and the missing tiling are fixed and matched
byte-for-byte against the hardware's own reference stream. The remaining wall is
structural, not numerical — dispatching the graph the way the NPU actually wants it, as
one pipeline rather than a stream of cold single-task jobs. That single reframe folded a
pile of problems I'd been treating separately — the flickering first conv, the cores
that wouldn't engage, even an old decision I'd been sure was right — into one shape: feed
the chip the whole network at once. Getting that pipeline to land every task on the
right ping-pong group is the part I'm on now. It's the closest the board has been to a
real classification.
