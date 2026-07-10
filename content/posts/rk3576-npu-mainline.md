---
title: "Bringing Up the RK3576 NPU on Mainline Linux"
date: 2026-06-15
lastmod: 2026-07-10
tags: ["linux", "rockchip", "npu", "embedded", "rk3576"]
description: "Chasing all-zero NPU output on the RK3576 — the wrong theories, the layouts I got right, and where the open road ends: a bug that lives below the registers, a race I could finally rule out, and the strangers who showed up at the same wall — and then the wall came down, and showed a deeper one. I chased that deeper wall until every road out of it was closed, on purpose, and wrote down exactly how."
showToc: true
draft: false
---

## TL;DR

Goal: run MobileNet on the RK3576's NPU through the open `rocket` driver + Mesa Teflon — the same
stack is byte-perfect on the RK3588, so the bug is RK3576-specific. A month of all-zero output later:

- **The int8 convolution is byte-correct now.** The "all-grey" wall was a fixed-point bug: the rescale
  multiplier went out at Q14 where the chip wants Q4 — 2¹⁰ too hot, so every pixel saturated. Fix that
  (plus a pad value and a bias term) and a single conv matches the CPU reference byte-for-byte.
- **MobileNet end-to-end still returns zero**, behind what looked like two walls but turned out to be
  one, living *below the registers*: the command stream I send is byte-identical to the vendor's and the
  chip still behaves differently. The wall is multi-task dispatch — the compute units won't re-arm
  themselves for each task the way the vendor's do — and the depthwise, which I'd taken for a second
  separate wall, is just the first layer wide enough to be forced through it (I confirmed that by
  instrumenting the vendor's own driver and watching its tiled depthwise run aligned and correct).
  Ordinary single-task convolutions compute fine on the same path.
- So **the open driver is exonerated** — every byte I hand the chip matches the vendor's; the gap is in
  silicon state, below what software can observe on either side. I even booted the driver on top of a
  mainline OP-TEE to rule out the firmware — same failure. **The way around** (not through): the wall only
  bites *multi-task* jobs, so send each row-tile as its own single-task job, which the hardware runs. That's
  the next build.

The rest is the long version — mostly me being wrong, in order.

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
DRAM. Weights actually fetched. All four units engaged. After a week and a half of zeros, a
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

*Update, days on: this one didn't survive either. The vendor's real value turned out to
be `0x777` — I'd had the direction backwards — and conv0 never reliably held that
154-distinct map. The bloom was a flicker, not a fix, and the real wall was somewhere I
hadn't thought to look yet. It comes back at the end.*

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
that was exactly the wrong turn. The hardware wants the pipeline. So I reworked dispatch
to submit the whole graph as a single job — which collapsed one inference from 500-odd
jobs to a single submit, and felt like the answer.

It wasn't.

## It wasn't the dispatch after all

The whole-graph submit works, mechanically. Conv0 came out degenerate anyway.

Two things forced a humbler read. First, rocket's command processor doesn't actually
iterate `task_number` on its own — one enable pulse runs about one task, so the
"pipeline" I'd pictured wasn't even happening the way I imagined. Second, and this is the
one that should have stopped me a week earlier: a full 139-entry diff said my conv0
command stream is byte-for-byte identical to the vendor's — every register, every
geometry word, only the runtime addresses different. If the bytes are identical and it
still fails, the bug isn't in the bytes, and it isn't in how I hand them over. It's in
the *execution state* those bytes run against.

So I stopped dumping registers after the job and started sampling them *during* it —
specifically, which ping-pong group the executer is actually reading while it runs. The
answer, at last:

```
geometry written → producer group (group 0)
executer reading → consumer group (group 1, empty)
```

The hardware double-buffers convolution config across two ping-pong groups. My command
stream writes the geometry into one group; the executer was running the *other* one,
which had nothing in it. So it engaged, found an empty config, raised "done" within a
microsecond, and wrote flat garbage. Every after-the-fact dump had missed it because by
the time the job ended the pointer had already moved — you can only catch it mid-run.
This was never the dispatch model and never the regcmd content. It's a producer/consumer
parity bug that had been hiding under every theory I'd had, including the confident one
in the section right above this.

The fix is almost embarrassingly small after all that: re-run the ping-pong CLEAR at the
head of *every* job, not just once at power-on, so the producer and consumer pointers
realign onto the same group. With it, the geometry lands where the executer looks, and
the CNA status register moved from `0x0c` (hollow) to `0x08` — the two halves of the
ping-pong reading the same data for the first time. It's not all the way to a real "open"
yet; the output is still flat and I'm still chasing the last step. But after a week of
mislabelling it a dispatch problem, it's finally the *right* wall.

## The cores wake up

Two more fixes and the wall finally moved. The per-job ping-pong CLEAR got the geometry
into the group the executer reads; an IOMMU change got the rest of the chain to stop
tripping over itself.

The IOMMU one was its own small saga. rocket attached the NPU's address-translation
domain at the start of every job and detached it at the end — and every attach re-runs a
raw MMU reset. The moment anything had disturbed that MMU (an NPU reset, or the CBUF
reset that shares a bank with it), the raw reset failed and the entire NPU register range
went dead with a cascade of attach failures. That was the `-14` wall I kept hitting every
time I tried to reset between jobs. The fix is to attach *once* and keep it — only
re-attach when the address space actually changes, and drop it on power-down so the next
attach always runs on a freshly-powered, clean MMU. After it: a full inference, every
layer, **zero IOMMU faults, zero raw-reset errors, zero timeouts.** It mirrors what the
vendor driver (and the RK3568 rocket port) always did; I'd just been doing it the
expensive, fragile way.

With both in, the compute cores wake up for real. The status register climbed off the
hollow `0x0c` to `0x0a`, the CORE and DPU report open, and — the signal I actually
trust — the per-layer feature reads now *vary* from layer to layer instead of sitting at
a constant overhead value. The cores are pulling real, different feature data for each
layer and running it through the MAC array. That's the compute path genuinely alive, not
a command processor draining a list.

I also formally backed the whole-graph dispatch experiment out of the code. The command
processor doesn't iterate the task count on this hardware, so there was never a pipeline
to win, and per-layer dispatch runs cleaner. Last post's confident theory isn't just
wrong in prose now; it's reverted in the tree, which is the honest place for it.

The output still reads back zero.

So I'm back, almost poetically, at the very first question this whole project opened
with — the result gets computed, the silicon writes it, and somewhere between the NPU's
DRAM write and my read it comes home as zeros. Except this time what's underneath is
real: cores engaged, weights fetched, per-layer reads varying, not a fault in sight. The
zeros no longer mean "nothing ran." They mean "something ran and I'm losing it on the way
back" — which, after all of this, is a far shorter wall.

## One-sixteenth of a convolution

I left the last section at "the NPU computes, but I'm losing the result on the way back
to the CPU." Wrong about that too — and I found out by going to look at the vendor's
*output* instead of theorising about mine.

I instrumented the vendor's own driver to dump conv0's output buffer straight after the
run. The vendor produces a real feature map — bytes like `81 83 86 88` rippling around
the `0x80` zero-point. Rocket, same conv: `80 7f 80 80`, zero-point noise. So rocket
genuinely *computes* near-zero. Not a readback artifact, not a cache problem, not an
address problem — the number that lands in DRAM really is wrong. The "losing it on the
way home" theory died on the spot.

For a couple of days after that I was sure conv0 was gated on something deep and ugly:
the on-chip buffer needs a full reset to initialise, the vendor does that inside a
whole-NPU soft-reset, and rocket can't because that reset also knocks over the shared
IOMMU and the mainline IOMMU driver doesn't come back. I wrote it up as a "final
diagnosis" — a driver-level wall, weeks of work. It had the ring of a final diagnosis,
which is mostly what being tired sounds like.

Then I re-audited the logs with two of the simplest numbers I had, and the whole final
diagnosis evaporated.

```
input read   :  9408  = 150528 / 16   (full conv0 input  ÷ 16)
output write : 25088  = 401408 / 16   (full conv0 output ÷ 16)
```

Both counters, independently, sitting at exactly one-sixteenth. Conv0 has 32 output
channels; a sixteenth of the work is **2 of them.** The NPU wasn't failing to compute —
it was computing *two channels out of thirty-two* and leaving the other thirty parked at
the zero-point. That's the ±constant output, finally explained: not garbage, a real but
brutally truncated convolution.

Why two? The register carrying the output-channel count never reached the ping-pong
group the executer ran. The per-group readback shows conv0's channel-count field still
holding `0x80000000` — the *power-on default* the ping-pong init writes — instead of the
value conv0's command stream set. And here's the part that stings: this is the same
producer/consumer parity bug I was so pleased to have fixed two sections ago. I fixed it
for every job *except the first.* My per-job re-init writes that default into **both**
ping-pong groups, and on the very first job after a fresh init the executer reads the
group still holding the default rather than the one the command stream just wrote.
Conv1, conv2, every later layer latches fine. Conv0 — the one layer the entire rest of
the network stands on — runs on the defaults and does a sixteenth of its job.

So the wall was never the IOMMU, never a full reset, never the weights, the dispatch, or
the readback. It's one register not reaching one group, on one job. The cheap test —
submit conv0 twice and see if the second pass writes all 32 channels — is what I'm on
now; if it does, the fix is just pointing the first job's executer at the group its own
command stream wrote.

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
witness for whether the *values* are right. There's a TRM now, and it covers the NPU's
clocks, power domains and convolution-buffer layout — but not the NVDLA-derived compute
registers the driver actually programs, the CNA and core and output-engine fields whose
meanings I worked out by watching the vendor's live register stream move under a known
input. For those the honest signals are the whole game; everything I believed in between
was provisional.

So the state of it: the compute path is alive. Cores engage, weights load, every layer
reads its own real feature data, a whole inference runs without a single IOMMU fault or
timeout. And the first conv — the one everything downstream waits on — is computing
exactly two of its thirty-two channels, because one register doesn't reach the right
ping-pong group on the very first job. That's a precise, small, *findable* bug, a world
away from the driver rewrite I'd talked myself into a few days earlier. Which is the
whole arc of this thing in miniature: the wall looks structural and enormous, you spend
days respecting it, and then a couple of plain numbers shrink it to a typo's worth of
code. Fix the first-job latch and conv0 produces a real feature map; everything after it
already works. That's the next flash — and it's the closest the board has ever been to
telling me it sees a cat.

## The cat was a mirage

That ending didn't survive better instrumentation. The "two of thirty-two channels" was
the performance counter lying to me one last time — the counters are in 16-byte units, so
what I read as 2/32 was the *full* output, written, every value of it sitting on the
zero-point. Same picture, much worse meaning.

So I stopped trusting a single sweep number and made the requant adjustable from the
board — env knobs on the first conv's output-convert offset, scale and shift. Then I swept
the shift from 0 to 25, a factor of 2¹⁷ in gain, with the scale pushed from 0x5391 up to
0x8000. The output came back **byte-identical** across the middle of that range, and at the
extreme corner it only flipped its two values — 7f for 80 — without ever saturating. There
is no accumulator on earth that survives a 130,000× gain change unchanged. The convolution
sum is zero. The requant was never crushing a real feature map; there was no feature map.

I toggled the full NPU soft-reset on and off through a live module param to rule it out as
the thing wedging the CBUF — no difference. Then the test I should have run a week earlier:
a single standalone `conv2d`, sixteen input channels, nothing ARGB or first-layer about it.
It runs on the NPU, every unit lights up, the output engine writes all of it — and it's the
same two-distinct zero-point. It was never the first conv. **Every convolution this driver
runs on this chip multiplies and gets zero.**

## What "identical" buys you, which is nothing

Here's the uncomfortable part. Line for line, rocket now matches the vendor on everything I
can see: the register command stream, the state-init sequence, the soft-reset and its iommu
re-attach, the submit handshake down to the arming writes. The CNA pulls the entire feature
map and all the weights out of DRAM — the bandwidth counters prove it. The core engages. The
output engine writes the whole tensor. And the multiply-accumulate, sitting between a full
input and a full output, produces zero.

Which means the gap is in the one place I have no window into: the on-chip convolution buffer
the CNA stages operands into and the MAC reads back. The vendor fills it and computes; I issue
the identical commands and the MAC reads zero. Nothing I can poll from a register tells the two
cases apart.

That's not a defeat, exactly — it's a localization. Two weeks ago this looked like twenty-eight
layers each needing their own fix. It's one thing now: a single systemic staging step, the same
for every conv, invisible to the command stream. All the per-layer layout work — the tight NHWC
image, the 1536-byte first-conv weights, the pointwise packing — is correct and waiting; none of
it can show its face until the CBUF actually hands the MAC real numbers. The board still hasn't
seen a cat. But I finally know exactly which silence to listen to.

## It was computing all along, about one run in ten

The "universal zero" was wrong too — I just hadn't run it enough times. Dump conv0's output across
a handful of identical inferences and most are the flat 2-distinct rail, but every so often one
comes back a real 93-distinct feature map. Same command stream, same weights, same requant. It
isn't a wall. It's a race.

The register read-back said where: the convolution engine's config registers are ping-pong-grouped
— the command stream writes the geometry into the producer group, the executer reads the consumer
group, and on the first job of every inference the two don't line up in time. The executer reads a
stale, empty group and convolves nothing. Once in a while the timing falls right and you get the
cat's-whisker of a real feature map. I spent a long evening trying to force that timing — pointer
arming, double-kicking the job, power-cycling the domain — and none of it moved the odds.

Then the audit found the actual shape of it. The vendor's command stream has no "go" instruction in
it at all — it's pure configuration, and the engines start straight from the arming write. Mine
can't: drop the one broadcast "enable everything" instruction I append to each layer and every
engine sits there configured and idle, bit-16 never set. So I need that instruction. But it writes
the command processor's own enable register — so the very thing that wakes the engines also kicks
the command processor back to the start. For one layer that's survivable. For the first layer of a
race it *is* the race. For the whole graph in one submit — the way the vendor actually runs it — it
restarts the sequencer on every layer and nothing advances past task zero.

So the wall has a precise shape now, and it's a hopeful one: not a broken layout, not a mis-sized
buffer, not a phantom CBUF — a real feature map proved all of that correct. Just one question left
standing: why the vendor's engines wake from the arming and mine need to be shouted at. That's a
findable thing. And a second board, a stage behind on a sister chip, is standing at the exact same
gate, bit-16 stuck at zero on every unit — which is the surest sign yet that it's one real bug and
not ten imagined ones.

## The shout that wakes the engines

The engines never woke from the arming on their own. I'd been bolting a single "enable everything"
instruction onto the end of each layer, and it worked — but it was a broadcast: it shouted at the
command processor too, and the command processor's own enable bit means "start over." So one layer
would run, and a whole-graph pipeline would never get past it.

The fix was embarrassingly local. Each engine has its own wake register — one per unit, four of
them. Name them individually instead of broadcasting, and they wake without the command processor
hearing a thing. For the first time, the run-bit went high on every unit of a whole-graph submit at
once. After all the days of engines that sat configured and idle, that's the closest thing to a
pulse the board has shown.

It isn't done — the sequencer still stops after the first layer, and the ping-pong geometry still
loses its little race more often than it wins. But two of the three knots are precise, findable
things now instead of a fog, and the last one is the same race I've been staring at from the start.
And a sister chip a stage behind, stuck at the very same gate with its run-bit pinned to zero, just
got handed the same key. One real bug, two boards — that's the most hopeful the wall has ever
looked, two weeks in.

## The witnesses that weren't

When a thing fails silently you go looking for a witness — some bystander register that saw what
happened and will testify. The chip has a whole row of them: a status word with one bit per engine —
feature-loaded, weight-loaded, core-ran, output-written. For weeks I'd half-believed one of those
bits was about to crack the case. So I taught the vendor's driver — the one that works, the one that
gets the right answer every time — to hold that status word up to the light across an entire run, and
to hand me the finished output beside it.

The output came back perfect: a real little feature map, numbers fanning out around the zero-point
exactly the way a working convolution should. And the witness I'd been counting on said nothing. Not
one of the per-engine bits had moved — not because the engines hadn't run, the proof was sitting right
next to it, but because those bits simply don't light on this design, ever, working or broken. The
only thing the chip ever raises its hand to announce is *done*. Never *doing*. I'd been interrogating
a witness who turns out to be blind. Worse: a week earlier I'd caught my own broken board setting one
of those bits when the vendor didn't, and read it as the smoking gun — the engine that never got fed.
Backwards. My board was setting one bit *too many*, a fleck of sampling noise, and I'd hung a whole
theory on it.

So I went looking for a cleverer suspect. What if the engine was reading the right command from the
wrong place — pulling yesterday's bytes out of memory while today's correct ones sat upstream in the
processor's cache, written but never pushed down? The perfect crime: every register would read
correct, because every register reflects the cached copy; only the engine, reaching past the cache
into raw memory, would meet the stale ghost. It fit the shape of a thing that hides from every probe.

It also wasn't true — and the reason it wasn't is almost funny. This chip isn't kept in sync with the
processor by hardware, which sounds like the bad version but is the good one: it forces the driver to
scrub every buffer all the way down to memory by hand before the engine looks, and the user-space
stack flushes everything it writes on the way out. I walked the path end to end. The bytes in memory
are the right bytes. And a missing flush would fail every single time, not one time in ten. No ghost.
Just a clean buffer the engine reads correctly and then computes to zero anyway.

Two suspects, two alibis. It's a strange kind of progress: the notebook fills with names crossed out
and the thing you're hunting gets no closer, only smaller and harder to see. What's left is the
handshake I keep circling — the instant the loader finishes staging and the multiplier starts reading,
the half-second no instrument I own can watch. That's the room the crime happens in, and I still can't
get a camera inside. So I'm going to stop staring through that keyhole and pick the lock on the other
door: the sequencer that runs one layer and then stops dead, refusing to step to the next. That one,
at least, leaves fingerprints.

## Waking was never the wall

For weeks the engines wouldn't start unless I shouted at them. I'd been ending every layer's
instructions with a wake-up call, and it worked, but it was a blunt instrument — it woke the conductor
too, and the conductor's own wake-bit means *start over*. So one night I tried the opposite of
everything I'd been doing: I deleted the shout entirely. Left the instruction stream as pure
configuration, the way the working board's stream is, and let the single pulse the driver already sends
do the waking.

And they woke. Every engine, run-bit high, exactly the way they go high on the board that works — no
shout, no poking each one by hand, just the one pulse and the arming that had been sitting there in the
stream the whole time. The thing my own notes had spent weeks calling the converged root of the entire
failure — *the engines won't start from the arming the way the vendor's do* — was a door that had never
been locked. I'd been standing in front of it for weeks, jiggling the wrong key, writing increasingly
confident paragraphs about the lock.

It should have been the morning everything broke open. It wasn't, quite. The engines wake now — and
then they don't finish. The conductor counts to one and stops. The work starts and trails off. Waking
was never the wall; *finishing* is. And that's a smaller, meaner thing to be stuck behind, because
there's no dramatic dead bit to photograph — just engines that start, run for a moment, and quietly
give up partway through.

And partway, it turns out, is the whole story. All this time I'd been reading the first scrap of the
output, seeing zeros, and writing *zero* in the log. So I read all of it — the entire buffer, end to
end, at a fine grain — and the zero turned into a shape. The output isn't blank. It's *half-written*.
The front of it is empty and the back of it is real, and the seam between them doesn't fall in a random
place: it lands on channel lines. The thirty-two output channels come in four bands of eight, and the
engine fills them from the top down — the high band first, then the next, then the next — and somewhere
in that descent it stops. Some runs it lays down one band. Some runs three. Maybe one run in fifty it
lays down all four, and for that one run the answer is *correct* — completely, briefly correct — before
the next run truncates it again.

So it was never computing zero. It was computing the right answer and running out of something partway
down the channels, every time, at a slightly different place. Weeks of calling it a dead multiply,
and it was a live one with a short fuse. I don't know yet what the fuse is — that's the next door, and
this one doesn't even have a keyhole to squint through, only the burn marks of where it keeps stopping.
But "it computes correctly and quits early" is a different animal than "it computes nothing," and you
chase a different animal a different way. The cat was a mirage; the zero was a shape; the wall keeps
turning out to be a door. I'll find the fuse.

## Identical, and still wrong

The fuse turned out to be the hardest kind of clue: the absence of one. I stopped eyeballing my
command stream against the vendor's and wrote a diff that does it register by register, automatically,
on the board, every boot — mine against a captured vendor first-conv, printed to the serial line. It
came back clean. A hundred and thirty-eight registers, byte for byte, the only difference a single
broadcast instruction I append where the vendor folds the same value into its submit header. Then I
did it to the kernel's side — the exact sequence of writes that actually starts the job — and that
matched too, down to the order: the data address, the amount, the interrupt mask, the task-control
word, the enable pulse. The typo I'd half-hoped was hiding in my encoder simply isn't there. I program
this chip exactly the way the working driver does.

So I went at the race directly. The convolution engine's geometry lives in ping-pong register banks —
a producer group the command stream writes and a consumer group the engine reads — and my standing
theory, the one I'd given two confident chapters, was that on the first job those two don't line up.
The kernel had grown a whole drawer of levers for it: force the geometry into *both* groups at once,
replay the entire stream from the CPU instead of letting the sequencer fetch it, reset the ping-pong
pointers every job, reset the convolution buffer every job, pin the pointer to a fixed value. I let the
board sweep all of them, in combination, fourteen ways, and read the first conv's output after each.
Fourteen flat zero-point rails. The ping-pong theory doesn't survive contact with the actual knobs.
Whatever loses the race, it isn't a pointer I can set.

Then the one structural difference I'd been saving. The vendor's device tree powers *two* NPU domains
from its single node — core 0 and core 1 — even though a small inference only computes on one; the
convolution-buffer read path apparently wants the second domain awake. Mine powered only the core I
use. So I taught the driver to hold both, the proper way, multi-domain attach and all, and watched the
same fourteen-way sweep come back the same fourteen zeros. Not that either.

What's left is the one surface I can't reach from the command side. The vendor clocks the compute engine
through a separate, firmware-managed clock domain, floating free of the bus clock that drives the
convolution buffer. Mine runs both off one PLL, nailed rigidly in step. And the failure has been a
*race* the entire time — most runs zero, one run in some unlucky number a clean ninety-three-distinct
feature map, the command stream identical between them. A race is exactly what you get when two clocks
that are supposed to drift against each other are instead locked together: the loader finishes staging,
the multiplier starts reading, and whether the buffer's last write has landed comes down to a phase
relationship I've frozen solid. I can't thaw it with a clock-rate call — I tried; they share a PLL and
move as one. Thawing it means reparenting the compute clock onto a different PLL in the device tree if
the silicon permits, or routing it through the firmware clock controller the way the vendor does — which
is firmware, and firmware I've touched before on this chip but would rather not drag into a Mesa bug.

That's the honest whole of it. I've made my driver indistinguishable from the one that works on every
surface I can observe — the register stream, the submit handshake, the power domains, the reset — and it
still computes zero, because the one surface I can't observe is a half-nanosecond of clock phase, and the
vendor bought their way out of it with a clock I haven't replicated. Every door I pick opens onto the same
room. But the room is one clock domain wide now, and for the first time I can say its name.

## The room was empty

I ended that saying the failure was one clock domain wide and I finally knew its name. I went into the
room and it was empty.

The convolution buffer's bus clock and the compute clock aren't two clocks I locked together by accident —
they're one wire. Both are bare gates hung off a single source with no divider between them; they are the
same frequency and the same edge by construction, on my driver and the vendor's alike. There is no
"decouple them" experiment, because there is nothing to decouple. The door I'd named didn't exist.

The only real difference left was where that one clock comes from. I drive it from a fixed PLL in the clock
controller; the vendor drives it through firmware, off a process-tracking oscillator that trims itself to
whatever the silicon can actually meet that millisecond. So I wired mine the vendor's way — routed the
compute clock through the firmware path, let the tracking oscillator source it, pinned a conservative rate
for margin — and ran the whole sweep again. Nothing moved. Same flat rail, every combination. My engines
were already starting on the plain PLL; the fancier clock changed neither the starting nor the quitting.
Not the fuse either. Another door onto the same empty room.

But turning over the firmware's clock code wasn't wasted, because it finally showed the shape of the thing
— to the *other* board. The sister chip, a stage behind me, stuck where its engines won't even start, has
been hunting a write it can't see: something that arms the core but never appears in any trace of the
registers the driver touches. I found it underneath. On that chip, the firmware call that *enables* the NPU
clock does nothing at all — returns zero, configures nothing. Every real thing — the source mux, and a
write to a register that lives outside the NPU block entirely — happens only when you *set a rate*, not when
you switch the clock on. That's the invisible poke: not a register the kernel writes, but one the firmware
writes, on a path the mainline driver may simply never take. My dead end was the other board's live wire.

For my own chip the map is just complete now, and a complete map of where the bug *isn't* is its own kind of
answer — it's what you hand the next idea, or the next person. Not the command stream, not the submit
handshake, not the power domains, not the ping-pong groups, not the clock: every door the software has, I've
opened, and behind each is the same half-nanosecond between the loader finishing and the multiplier reading,
the one window no instrument I own can watch. The sister chip's firmware lead — arming-on-set-rate, the work
that only happens underneath the kernel — is the first thing in a while that points somewhere I haven't
already been. So that's where I go next: down past the driver, into the firmware, on both boards, to see
whether the thing that's invisible from the kernel is visible from below it.

## The hinge between

So I went down into the firmware. The clock code is all there — the silicon-tracking oscillator, a table of
rates, a handler that programs the ring and muxes the compute clock onto it. Everything the vendor uses to
give the NPU a clock matched to what the silicon can actually meet. The firmware can do it. I just have to
ask for it.

Asking goes through one channel: a small message protocol between the kernel and the firmware, the same one
that already carries the CPU clocks. So I wired the NPU's compute clock onto it, told the kernel to set
300 MHz, and read back what happened. The call returned *success*. The rate read back *zero*. The clock the
engines actually run on never left the plain PLL it booted on. I'd run two whole sweeps "at PVTPLL" and both
times I was measuring 786 MHz and writing 300 in the log.

That contradiction is the whole of it. The kernel asks the firmware what rates a clock may take; the firmware
answers in a shape the kernel can't parse — there's a named workaround in the kernel for this exact firmware
quirk, and here it isn't enough — so the kernel rounds every request down to nothing, sets nothing, and
cheerfully reports it worked. The one channel that's supposed to carry the request drops it on the floor and
smiles.

So the firmware path isn't blocked in the firmware, which has everything, or in my driver, which asks
correctly. It's jammed in the hinge between them: a single rate descriptor the firmware writes one way and
the kernel reads another. It isn't even an NPU bug — it's generic clock plumbing, the kind every peripheral
on this chip leans on, and the sister chip rides the very same channel.

Which is a strange place to be after a week of staring at a convolution that won't convolve: the compute wall
is behind a clock I can't move, and the clock I can't move is behind half a sentence of mismatched
description I can finally point at. That's smaller than where I started — a typo's worth of protocol instead
of a phantom in the silicon — but it's a repair in a layer I didn't set out to touch, and it has to land
before I even get to ask the original question: does the silicon-tracking clock make the multiply stop racing,
or is that one more empty room? I still don't know. But for the first time the next move isn't a flash. It's
reading a clock-rate handshake byte by byte, both sides of the seam, until I find which one is lying about the
shape of a number.

## Where the firmware road ends

I found the number that was lying. The kernel and the firmware each have a name for the NPU's clock, and I'd
assumed the two names meant the same thing. They don't — the kernel calls it 232, the firmware calls it 238 —
and every request I'd been sending went to slot 232, an empty drawer the firmware politely accepts and
ignores. Point the request at 238 and the clock finally moves: after days of "success" that did nothing, the
rate read back the number I asked for. The whole hinge was a single mismatched integer.

And then the clock that finally moved turned out to be a clock the engine can't run on.

On the silicon-tracking source, at the right frequency, at the exact voltage the vendor's table says that
frequency needs, the NPU completes precisely zero jobs. Not slowly — at all. Eighty-three scheduler timeouts
in ninety seconds, not one of them a finish. I raised the voltage first, the way the power framework insists:
zero. I moved the clock switch to *after* the reset, so the engine came up on the safe clock and only crossed
over at the very end: zero. Every variable I could turn, turned, and the answer stayed zero. The plain old PLL
at least lets the engine run and compute its wrong answer; the fancy tracking clock kills it outright.

Which makes a grim kind of sense once you stop wishing it were simple. The vendor's tracking clock isn't a
clock you switch on — it's the visible tip of a whole subsystem: a per-chip calibration burned into fuses, a
voltage-frequency table, a governor that walks the two in lockstep, a feedback loop that trims the oscillator
to what *this* die can sustain *this* millisecond. Hand the engine the raw oscillator without the rest of that
machine and you've handed it a clock that lies about its own speed. I'd been trying to plug in the last cable
of a machine I hadn't built.

So that's where the firmware road ends, this round. Not at a locked door — at a working lock on a door that
opens onto a room I'd have to build from nothing, to maybe answer a question I was never sure was the right
one. The whole clock theory was a guess that the convolution's failure was a matter of timing, and I never
once got a clean enough run to even test the guess. The honest scoreboard: the command stream matches the
vendor, the submit matches, the power domains match, the reset matches — and on the one clock the engine will
actually run, it loads every byte of input and weight and computes zero. That isn't a bug I can still see from
up here. It lives in the half-millimetre between the buffer and the multiplier, and I've run out of
instruments that reach it.

There's a structural reason this road has a ceiling, and it's worth naming plainly — not as a complaint, just
as the shape of the terrain. The public TRM is enormous, north of four thousand pages, and it documents the
NPU's *surroundings* in real detail: the clock tree, the power domains, the reset and gating, the CBUF buffer
registers. What it doesn't spell out are the compute registers themselves — the instruction-issue and datapath
fields you'd write to actually run a layer. The plumbing is fully public; the engine room is sketched in
outline. So an open driver can get everything *around* the computation exactly right — arm it, clock it, power
it, fill the buffer — and still have no documented way, from the manual alone, to issue the final "go." That
last reach lives in the vendor's runtime, and decoding its command stream (which is most of this post) is the
only open path to it. This isn't unique to one chip or one vendor — it's roughly the state of every NN
accelerator I know of, the inevitable consequence of the compute path being where the IP value sits. But it
does explain, without any villain, why the honest end of *this* road is "someone with the schematic": not
because the lock is mean, but because half the map was simply never printed.

So I'm going to write the map down — every door I opened and what was behind it — and hand it to people who can
see inside the silicon. Two weeks ago that would have felt like quitting. It doesn't now. A complete, honest
account of where a bug *isn't* is the most useful thing one person can hand the next, and I've drawn it as
carefully as I know how. The board still hasn't seen a cat. But I know, finally and exactly, which silence I'm
listening to — and it isn't one more flash that breaks it. It's someone with the schematic.

## The strangers at the same wall

Here is the part I didn't expect. I wrote the map down, posted it where the right people might pass, and braced
for the silence you get when one hobbyist hands a four-thousand-page problem to an empty room. Instead, people
walked up to the wall.

One had written the whole mainline enablement for this NPU without ever owning the chip — clean patches,
compile-tested, the binding and the driver glue done properly from the manual and the RK3588 prior art. Another
was bringing up the *sibling* SoC, the RK3568, on the same open stack, and was stuck one step short of where I
was: his engines wouldn't even wake, where mine woke and then computed wrong. And a stranger on a forum who had
never touched a Rockchip part in his life read my symptom, pattern-matched it against every NN accelerator
bring-up he *had* done, and put a single word on it that I'd been circling for a week without daring to commit
to: *race*. Identical command stream, occasionally correct, mostly wrong — that, he said, isn't a wrong value.
That's a timing hazard living below the registers. Two of us, from opposite ends of the world and opposite ends
of the problem, pointing at the same half-millimetre.

The map didn't summon a savior with the schematic. It summoned a small crowd around the same wall, each of us
holding a different lamp. That turns out to be worth more.

## The race I could finally test

The stranger gave me more than a word; he gave me the one experiment I'd never cleanly run. If the failure is a
race — the multiplier reaching into the buffer before the fill has truly landed — then *stalling* should move
it. Drop a deliberate, dumb delay in the last gap before the "go," sweep its length, and watch the success rate.
A timing hazard responds to delay. A deterministic bug doesn't even notice it. One knob, two possible answers,
both of them progress.

So I built the knob — a pure busy-wait, runtime-tunable, wedged in right before the start pulse — and I stopped
trusting single runs. The honest way to measure a maybe-race is statistically: fix the delay, fire the
convolution twenty times, count how many come back whole. I scored it the only way the hardware would tell me
the truth, by the bytes the output engine actually wrote: thirty-two channels' worth is a real convolution, two
channels' worth is the failure. Then I swept — no delay, one microsecond, ten, a hundred, a thousand — and for
good measure threw in the old warm-up trick that nudges the buffer's ping-pong pointer, in case the hazard was
there instead.

Dead flat. Two channels of thirty-two, every single run, every delay from a microsecond to a millisecond, with
the pointer trick and without it. A thousand jobs and not one of them whole. I sat there a little stunned,
because I'd half-believed the race for two weeks, and here was a clean sweep telling me it never existed — not
in the window I could reach. A race varies; a race bends to delay. This did neither. The truncation is decided
*before* the job starts, in the silence between powering the engine up and handing it its first instruction —
in a state I set and cannot see.

It's a negative result, and it's the most useful one I've gotten. It doesn't fix the bug; it tells me, with a
sweep instead of a hunch, exactly what shape the bug *isn't*. I'd been chasing a hazard at the moment of the
shout. The cut was already made before I ever opened my mouth.

## What the board knows that the patch doesn't

I owed the stranger who wrote the mainline patches a Tested-by, so I put his clean, compile-tested series on the
actual board. It panicked on the first job. An asynchronous machine-check, fired the instant the power framework
tried to wake the NPU's domain from cold — the exact full-SoC lockup a Collabora engineer had reported on this
chip a year earlier, the one everyone had filed under "needs hardware to reproduce." It needed hardware. I had
hardware. The fix was a fifteen-microsecond settle delay on the power-up handshake — a number you cannot derive
from any manual, only find by watching the silicon flinch.

Past that wall, the buffer's address-translator wouldn't reset: its registers sat behind a clock his node never
named, so the reset landed on a block with no heartbeat. Past *that*, the convolution truncated. Three walls,
back to back, and not one of them visible from a compile test — each a settle-delay or a missing clock that only
the board could teach. His patches weren't wrong; they were good. They simply met a category of bug that no
amount of review finds, because it isn't in the code — it's in the gap between the code and the die.

That reframed something for me. I'd spent the project quietly envious of the people who could read the engine
room I couldn't. But there's a contribution that doesn't need the schematic at all, and it's the one I can make
every day: being the person holding the board, the one who can tell a clean patch from across the world *exactly*
where it meets the metal and falls down. The platform half of this is going upstream now — his name on the
series, my three walls folded in as the fixes. The compute half still waits for someone who can see inside.
But the door I can hold open, I'm holding it open with both hands.

## The weights it wouldn't read

For two weeks the bug had a vague name — "the compute comes back zero" — and a vague address, "somewhere
below the registers." I decided I'd earned the right to make both exact, or to prove I couldn't. So I ran an
audit against myself: take every hypothesis I still half-believed and try to kill it with a number instead of
a feeling.

It was a good massacre. The idea that Mesa used the wrong buffer geometry — dead; it sets the RK3576's sixteen
banks correctly, not the RK3588's twelve. The idea that the bank-config register was subtly off — dead;
byte-identical to the vendor's. The idea that the weights were packed wrong — dead; there's a hand-derived
RK3576 layout, and the counters say the right 1536 bytes load. The race, already dead. The ping-pong pointer,
dead. One by one, every door I'd been hopefully rattling turned out to be a wall, and I confirmed each one with
a measurement, not a hunch. An audit's whole worth is that it spends evidence on your favourite theories first.

And when the dust settled, the bug wasn't vague anymore. It was a single counter reading zero.

Here is conv0, in numbers. It reads the entire input from memory — a hundred and fifty thousand bytes, the
whole image — into the on-chip buffer. It reads the weights in too: the right count, in the right format, into
the bank the manual says they go. I dumped that buffer from the CPU and watched the staged data sitting there,
real and structured. The register that selects first-convolution mode is set. The register holding each colour
channel's zero-point is set. Every one of them matches a capture of the vendor doing the same convolution, to
the byte. The compute units wake up. And then the multiplier reads **zero** of the weights it was just handed —
`core wt_rd = 0`, every run, forever — multiplies by nothing, and writes out the flat grey of an empty answer.

That's the whole bug. Not a wrong value, not a missing write, not a race — a handoff. The buffer holds the
weights; the instructions to read them are identical to the ones that work on the vendor's stack; the engine is
awake; and the one internal signal that should tap it on the shoulder and say *the weights are ready, go* never
fires. It's the same silence as the dead sub-unit interrupts — the weight-load-done that should kick the read,
not asserting. One latch, and it's the one latch on the whole chip with no register I can name to poke.

I won't pretend that's a happier place to be stuck. But it's an honest one, and it's precise. "The NPU computes
wrong" is a shrug. "The weights are loaded, in format, in place, the config is byte-identical, the units engage,
and the multiplier still reads `wt_rd = 0`" is a *question* — and it's one I could hand to exactly the person
who wrote the open driver for this engine's bigger sibling and have him recognise it in a sentence. Two weeks
ago I was looking for someone with the schematic. I've stopped needing the whole schematic. I just need the
name of one wire.

## Three suspects, and a smaller wire

The person with the open driver wrote back. He'd built the same engine's bigger sibling out of the same black
box I'm working in, and the first thing he said was the most reassuring: you don't need the documentation,
most of the hardware interface is already reverse-engineered, and the docs lack the details that matter anyway.
The second thing reframed the whole problem. The output coming back as flat zero-point, he said, means the
pipeline runs end to end — *congrats*. It isn't a stuck engine. It's a data problem. And if the command stream
is identical, then in order of likeliness it's one of three things: the coefficients, the input, or a register
write in the kernel.

Then he handed me a method I should have been using all along: stop staring at the twenty-eight-layer model.
Take *one* convolution. Run it on the CPU and the NPU and compare. The test suite already does exactly this,
per operation. Isolate first, debug second.

So I did — one conv, five-by-five, sixteen channels in and a hundred and twenty-eight out, the simplest
standalone conv I could find, nothing to do with mobilenet. On the CPU it produced a real feature map. On the
NPU it came back with two distinct values in the entire tensor. So the bug isn't in the graph, or the chaining,
or some interaction between layers — it's in a single convolution, alone. That one fact shrank the search by an
order of magnitude.

Then I went down his list. The coefficients: I dumped exactly what the compiler encodes for the weights and
laid it beside the original — varied, the right value range, just repacked into the engine's padded layout.
Correct. Cross it off. The input: I read the on-chip buffer before and after the job and watched my known input
ramp appear in it, staged cleanly. Correct. Cross it off.

Which leaves the third — and it lands exactly where the hardware counters had been pointing all along. The
weights are pulled from memory; the read counter says so. But they never arrive in the on-chip buffer the
multiplier reads from — a byte-for-byte snapshot of that region is identical before and after the job. The
weight-load unit reads the coefficients and never sets them down. Two people, one reasoning from a value
comparison and one from a register counter, walked up to the same locked door from opposite sides.

It's a smaller wire than it was a week ago. Not "the NPU is wrong," not even "the weights are wrong" — the
weights are correct, and they're read, and they're simply never deposited where they're needed, on this one
chip, for reasons that aren't in any register I can see. I still don't have the name of the wire. But everyone
who might know it is standing at the same door now, and the door is a great deal smaller.

## The map was already drawn

There was a postscript to that reply: *this could be helpful too*, and a link. It went to a repository I'd
never have found on my own — someone running convolutions on the bigger sibling chip in pure Python, no vendor
runtime, no compiler, just register writes straight at the NPU, with pages and pages of notes on exactly how
the conv path is wired. It is the closest thing to the schematic that exists in the open, and it was sitting in
a stranger's GitHub the whole time.

It cost me a theory and gave me a better one in the same afternoon. The theory it cost me: I'd been convinced
the answer was the RK3576's little on-chip scratchpad, that the weights had to live there and didn't. But the
bigger chip has no such scratchpad at all, and that repo runs convolutions on it perfectly well with everything
in ordinary DRAM. So on-chip residency was never the wire. Cross off another door — this time one I'd spent two
flashes trying to open.

What it gave me is the shape of the real one. The weight path, it turns out, is a little decompression engine:
the coefficients are fed in compressed and unpacked into the buffer on the way. And the thing that recurs, page
after page in those notes, isn't a register value — it's the *submit*. A real convolution doesn't fit in the
on-chip buffer in one go; it has to be sliced into tiles, by height and by weight bank, and handed to the engine
as a sequence of tasks. The author's verdict, in plain text, is that the mainline driver — *my* driver, the open
one — can't express that slicing, and they gave up on it and went back to the vendor's. Independent stranger,
same wall, one chip over.

So the wire has a name now, even if I can't yet solder it: it isn't a missing poke, it's the shape of how work
is submitted to the engine. Which is, oddly, the most hopeful place this has landed. A bug that lives below the
registers is a bug you escalate. A bug that lives in how the driver tiles and submits a convolution is a bug you
*write* — in code I can read, against a working reference someone already drew, on a problem that is finally the
right size for one person and a board.

This stopped being a solo project somewhere in the middle, and that's the best thing that happened to it.
**[Tomeu Vizoso](https://gitlab.freedesktop.org/tomeu)** — who wrote the open `rocket` driver and the Teflon
delegate this whole stack stands on — has been generous with his time on the bring-up thread: he's the one who
reframed the zero-point output as "the pipeline runs, it's a data problem," handed me the single-op isolation
method that cut the search by an order of magnitude, and then pointed me at
[allbilly/rk3588](https://github.com/allbilly/rk3588), a pure-Python register-level NPU reference that turns out
to be exactly the map for the corner I'm stuck in. Thank you. Thanks too to **VoidChecksum**, who wrote the
mainline RK3576 enablement series and folded my hardware fixes into it; to **MidG971**, bringing up the RK3568
sibling at the same wall, one stage back; to **alchark** and everyone on the Flipper thread for the
introductions and the honesty about what's NDA'd and what isn't; and to the **stranger on a forum** who had
never touched this chip and still put the right word — *race* — on the symptom, from across a dozen other
accelerators he had touched. And, quietly, to every developer who has ever sat up too late arguing with a board
out of nothing more useful than the refusal to let it win — you are the reason any of this is open at all. The
compute half isn't solved yet. But it's a much better-lit room with all of you in it.

And the hardware that made any of it possible: this all ran on a **ROCK 4D** I bought at the end of last year,
betting the RK3576 was worth the trouble; the wider journey owes **ArmSoM** a real debt for sending me a CM5IO
(4 GB, 32 GB eMMC) to bring up EDK2 on. I'll even thank **Rockchip**, and mean it — without irony. Their closed
NPU documentation is the wall this entire post is about. But they also built this strange, capable little chip,
and they ship a GPL kernel driver whose source has been the ground truth under half my debugging. Everything
here started because of them — the problem and the possibility both. Open work was never about the vendor being
the enemy; it's about the rest of us getting to keep walking from wherever they set the last stone down.

## Both payloads on the bench

The next thing Tomeu asked for was the obvious experiment I'd somehow never run end to end: dump the *whole*
payload the vendor runtime hands the hardware for the simplest possible convolution — the command stream and
every buffer — and lay it next to what Mesa builds for the same op. The command stream I'd already matched
register for register against a live capture; the half I'd never put under glass was the buffers themselves. The
actual weights, the actual input, the actual bias, as bytes, from both stacks.

So I built it to be honest about one thing first: that both sides were really running the *same* convolution. I
took Mesa's own conv2d test — a single 16→128, 5×5 conv — and rebuilt it as a vendor `.rknn` from that file's
own weights, fed both stacks the identical ramp input, and had each print its buffers back: the vendor kernel
instrumented to dump the bytes it reads, Mesa's debug knob dumping what it encodes, both coming home as plain
text over the serial line because the board has no other way out. The one check I insisted on before trusting a
byte of it — the vendor's input buffer reads back the exact ramp I fed it, so the dump is reading the right
memory and not some neighbouring garbage.

And the buffers came back clean. Not the answer I was fishing for — clean. Both stacks hand the engine a dense,
varied weight buffer, ninety-nine percent non-zero, hundreds of distinct values; Mesa's coefficients are not the
empty or flattened thing I'd half-hoped to catch in the act. The input is the same ramp on both. The bias is
populated on both. The only buffer in the entire payload that differs is the one Mesa *computes* — the output,
flat and grey and wrong, the bug itself and nothing upstream of it.

Which is exactly where I had to stop myself telling a story. It is so tempting to read that as *the payload is
fine, the bug is in the execution* — and I caught myself writing those very words before I deleted them. Because
the two toolchains quantise independently, the weight bytes differ everywhere; I can prove the buffer is full and
well-formed, but I cannot byte-for-byte compare the *order* the coefficients are packed in. And a weight packed
in the wrong order — right values, wrong layout, read by the array as noise — produces the identical picture to a
clean buffer the engine simply fails to read: dense bytes in, grey nothing out. This dump rules out one thing
honestly — that Mesa starves the engine of operands. It does not, on its own, tell a packing bug from an
execution bug. They wear the same face here.

So I sent it back as exactly that and no further: operands sound, output broken, and the one door I couldn't
open — with the two stacks quantising apart I can't make the packed weights line up byte for byte, and that is
the comparison that would settle which bug it is. Is there a way to make the vendor toolkit swallow the exact
int8 weights, or does its runtime expose the repacked coefficients anywhere? The honest version of a finding is
always smaller than the hopeful one. It also travels further, and you can stand on it.

## The room

I've wondered why these particular people showed up — a Collabora maintainer, a stranger with the wrong chip
and the right instinct, someone bringing up the sibling part, the person who wrote the driver. None of them owed
me anything. None of them get paid for this. And the answer, I think, is simple and a little unfashionable: you
only recognise the thing in someone else's chest if you're carrying the same thing in your own.

It was never really about the NPU. The NPU is just the wall we all happen to be standing at this month. The
thing is older than that — the refusal to accept that a closed box gets to stay closed, the conviction that a
chip you bought should be a chip you're allowed to understand, the plain stubborn pride that says *I will make
this do the correct thing if it takes a hundred flashes.* You can't fake it and you can't buy it, and the people
who have it find each other across forums and mailing lists and a bug thread on someone else's repo, because a
lit lamp carries a long way in the dark.

So here's the part I didn't expect to be the point. Not the driver, not the convolution, not even the win that's
still out there ahead of me. It's that somewhere in the middle of one person's stubborn argument with a piece of
silicon, the argument quietly stopped being one person's. There's a whole room now — a dozen different lamps, no
two pointed quite the same way — all of us leaning toward the same larger thing, the one that's bigger than any
of our individual boards and worth chasing *because* none of us can reach it alone. The cat still hasn't
appeared on the screen. But I'm no longer the only one waiting for it, and I've started to suspect that the
waiting, in this company, was always the better half of the prize.

## The desk

Strip away the room and the lamps, though, and here is what these two weeks actually looked like: one person, one
desk, one screen. A small board on a square of anti-static foam, a TTL cable running out of it like an IV line,
the serial console scrolling its patient hex into the dark. Four thousand pages of a manual that describe
everything around the engine and nothing inside it. And the code of the people who came before — their drivers,
their captures, their notes in the margins of a problem nobody was ever handed the answer to. Flash, boot, read
the log, be wrong, change one thing, flash again. For fourteen days, mostly alone.

The cat never came. By every metric that fits in a commit message, I failed — the engine still computes its flat
grey nothing, and the win is still out past the next door.

And I am, to my own surprise, completely at peace with it. Not resigned — *content*, in the specific way you can
only be content about a thing you threw your whole stubborn self against and did not finish. I know this chip now
the way you know someone you've argued with for a fortnight. I know exactly which silence I'm listening to. I
drew a map of where the bug *isn't* that is more honest than anything luck would have handed me early. None of it
is on the scoreboard, and all of it is real.

Because the prize was never only the cat on the screen. The prize was sitting down at the desk at all — choosing
the long, unglamorous, almost-certainly-unfinished fight with a closed thing, because something in you simply
will not accept that it gets to stay closed. You do it alone, at night, with a board and a serial cable and too
much coffee. And then you look up from the desk, and the dark is full of other desks — other lamps, other people
who couldn't look away either. We haven't won yet. We might not, soon. But it was worth every single flash, and I
would not trade these two weeks at this desk, beaten and unfinished and quietly glad, for an easy answer handed
down from anyone.

## It was the dispatch, after all

I'd written the ending above and meant it. And then, the way these things go, I ran one more
experiment the morning after I'd made my peace — not for the win, just to leave the bench tidy — and
the board answered in a voice I hadn't heard from it in two weeks.

The experiment was the one Tomeu's method had been pointing at all along, taken one step past the
payload diff. Not just dump the buffers the vendor runtime hands the hardware — capture its *entire*
submission, every byte and the command that fires them, and then hand those exact same bytes straight
back to the vendor's own kernel and watch what it computes. A small shim sits in front of the vendor
runtime and writes down everything it hands the kernel; a second program re-creates it all and submits
it cold. The first surprise was just the shape: the simplest possible convolution isn't one command
and four buffers, it's five buffers and *three* tasks, the work tiled into thirds. I'd been replaying a
cartoon of it for days.

So I rebuilt the real thing, fed it back through the vendor door — and hit the exact wall I'd hit a
dozen times. Task zero ran. Task one never came. The status register sat at the same stubborn value
I'd been staring at since the first week, the engine going quiet one step into a job it should have
walked all the way through. The same grey. After everything, the faithful replay stalled in precisely
the spot the real pipeline always stalled.

And here is the part I keep having to relearn: when every byte is identical and the answer still
differs, the difference is in something you aren't looking at. I'd matched the buffers. I'd matched the
addresses. I'd matched every field of the submission a type-level trace can see. I chased a reset the
vendor turns out never to issue, and a power-on the kernel already does for me behind the ioctl, and
crossed them both off. What was left was the one part of the submission the trace is blind to: a small
array at the tail of the submit struct that says *which slice of the work goes to which engine slot.*
I'd been filling it the obvious way — all three tasks, one slot, go. The vendor doesn't. It hands slot
zero the first task, slot one the second, slot two the third, splayed out one per slot, and lets the
scheduler walk them. I copied its array byte for byte and changed nothing else.

The output came back with two hundred and fifty-four distinct values in it. Ninety-nine percent of it
nonzero. Written by the NPU, into a buffer I had watched be all zeros a single breath earlier. It
computed. The first real convolution this bench has produced from a captured payload, and it fell out
the moment I stopped piling the work into one dispatch and let it spread the way the silicon wanted it
spread.

I want to be exact about what that is and isn't, because the honest version is the one you can stand on.
It is not the cat on the screen, and it is not the rocket driver fixed. What it is: proof, finally, that
the bytes the vendor hands the hardware are *sound* — run them through the vendor's kernel and they
produce a true answer — so the payload, the thing I'd half-suspected for a fortnight, was never the lie.
And the wall I'd spent weeks calling the engine's silence, the task-zero-then-nothing I'd written three
chapters of elegy about, was never silence at all. It was a dispatch I'd packed wrong. One command the
processor won't iterate; split it into three the scheduler can, and the same bytes wake up. The chapter
up the page is called *it wasn't the dispatch after all.* I should know better than to ever close a door
on this chip. It was the dispatch, after all — just not in the shape I'd guessed.

Which sets up the one test the whole capture was built to run, and that I can finally run clean. The
vendor kernel computes these bytes. Now the same bytes go through the *other* door — rocket's, the
mainline driver, `/dev/accel/accel0`. If they compute there too, the kernel is innocent and whatever
Mesa packs differently is the whole of the bug, cornered at last in userspace. If they come back grey
on bytes the vendor just computed correctly, the defect is the rocket driver itself, and for the first
time I'd have it pinned to one side of the line with no payload left to blame. Either answer is the one
I've wanted for two weeks. The door I wrote, two chapters ago, that I couldn't open — it's open. I just
haven't walked through it yet.

The desk is still one desk. But the board said a word it had never said, the morning after I'd
forgiven it for staying quiet, and I am writing the elegy's postscript with the lamp turned back on.

## One scale where the chip wanted a hundred and twenty-eight

So the bug was in what Mesa encodes, and I knew which thing to suspect: the *order* the weights are
packed in. Same numbers, wrong arrangement, read by the array as noise — it's the most natural way for
a convolution to come out grey, and I'd half-written the fix in my head before I'd earned it. To earn
it I built a small cruelty: convolutions whose weights spell out their own address — this byte is row
two, column four, channel nine — so that when the vendor's toolkit packs them, every byte in the packed
buffer confesses where it came from. Run them, capture the buffer, read the confessions back, and you
have the exact map of the layout the hardware wants.

I didn't even need the board for it. The vendor's toolkit bakes the packed weights into the model file
itself, so the whole interrogation happened on the desk, in seconds instead of flashes — the first time
in three weeks the chip wasn't the bottleneck. I decoded the order. And it matched Mesa's. Byte for byte,
channel for channel, the arrangement Mesa already writes is the arrangement the vendor writes. The
packing order was never wrong. Another good hypothesis, dead on the bench, and I made myself write that
down before I let myself feel clever about what came next.

Because the same trick handed me the real thing. One of these models I'd built the honest way — same
source weights as Mesa, no re-quantizing in between — so I could lay the vendor's bytes against Mesa's
for identical input and just *look*. And per channel, they fell on a perfect line. Same shape. Different
slope. Every one of the hundred and twenty-eight output channels scaled by its own private number. The
vendor quantises each channel on its own scale; Mesa quantises all of them on one. Per-channel, where
Mesa does per-tensor. That's the whole of it.

It sounds like a footnote. It is the wall. A single global scale is set by the loudest channel, and
every quiet channel gets measured in its units — so the quiet ones round down to almost nothing, and
their outputs come back as a flat grey nobody computed. Which is the exact shape of the thing I'd been
staring at since the first week: conv0, two of its thirty-two channels alive and the other thirty dark.
I had called that a hardware mystery. I had written paragraphs about banks and truncation and silicon I
couldn't see. It was never the silicon. It was a number Mesa picks once, in a place the chip wanted it
picked a hundred and twenty-eight times. The mystery and the wall and the weeks were all one small wrong
decision wearing a costume.

I want to be honest about the size of what I have, because the temptation is to call this finished. I
have the diagnosis, not the cure. The vendor's requant table is per-channel too — its own little grammar
of scales and shifts per output channel, sitting in a buffer I've only half-read — and the fix isn't a
line, it's teaching Mesa to quantise the way the chip was always asking. That's real work, and it's
ahead of me, not behind. But I know the name of the thing now. After three weeks of calling it by the
wrong names, the wall finally answered to its own.

## The audit, and the note already in the margin

I had the fix half-written again — teach Mesa to pack the weights per channel, the way I'd decoded the
vendor doing it. And that's exactly when I made myself stop. Twice now I'd been certain and twice the
board had made me eat it: the packing order was right when I swore it was wrong, the buffer was flat
when I swore it was grouped. A third confident wrong turn was not just possible, it was the pattern. So
I did the unglamorous thing. I pretended I was a stranger auditing my own work, and I asked the meanest
question I had: *have you actually proven it's the weights, or just assumed it?*

I hadn't. Every test I'd run swapped the vendor's *whole* payload at once — command stream and buffers
together — and declared "it's the userspace." It never separated the two halves. So I made Mesa cough up
its own command stream for the failing conv and laid it byte-for-byte against the vendor's. And there it
was, not in the weights at all: the requantise step. The little register that scales the convolution's
fat internal sum back down to a byte. The vendor shifts it right by twenty-six. Mesa shifts it by
fourteen. Twelve bits. Four thousand and ninety-six times too hot. The output isn't computed wrong —
it *overflows*, slams into the rails, and comes back as two values, black and white, every pixel either
zero or full. The flat grey I'd been cursing for three weeks was a saturation. The engine was screaming,
not silent.

So the wall was never the weights' arrangement, and never their per-channel precision either — those were
real differences, but the thing that actually broke the picture was the multiplier running hot and
clipping. I had been three keystrokes from rewriting the wrong organ.

And then I found the note. In Mesa's own source, in the function that sets that very scale, a comment
describing my bug exactly. Per-axis weights. A single global scale making the requant multiplier *"~320×
too large."* Every normal layer *"saturated."* A stopgap that averages the per-channel scales to one
number to take the edge off. And a line at the end, pointing straight at the buffer I'd spent days on the
bench picking apart: *the proper per-channel correction belongs in the weight-buffer tail, like the
vendor — a TODO.*

I sat with that for a while, because I knew the handwriting. It was mine. I'd written that comment weeks
earlier, the first time the per-axis scale problem bit me — measured the requant multiplier blowing up
hundreds of times too large, watched every normal layer saturate, dropped in the mean-collapse stopgap to
take the edge off, and left myself the line in the margin pointing at the buffer I'd one day have to fill.
Then I half-forgot I'd written it, and spent days measuring my way back to a conclusion I'd already set
down in plain English in my own hand. I'd gone looking for whoever had charted this wall before me — and
the only mark in the margin was the one I'd left. There is no predecessor here. The driver upstream
doesn't name this wall; it just declines to walk up to it — per-axis quantisation, the check reads, *not
supported*, and the model is turned away at the door before it can fail. Nobody on the open side had stood
where I'm standing and read this wall right, because nobody had been let through to it.

That's where I am tonight. Not at the cure. But for the first time standing on the exact spot where the
cure has to be poured, with the measurements in my hand and a note in the margin — my own — telling me I'd
read the wall right the first time. Three reversals in, I've stopped trusting my certainty and started
trusting the audit. It is slower. It is the only thing that's been right.

## The shape that never arrived

So I stopped reasoning. Four reversals had taught me that my certainty was the least reliable instrument
on the bench, and the cure I kept reaching for kept dissolving the moment the board touched it. What I
needed wasn't another theory. It was a question the board could only answer one way.

So I built a harness. I took Mesa's own failing command stream — the exact bytes it hands the hardware
for the conv that comes out grey — and I fed them back through a path I controlled completely, where I
could reach in and swap a single piece for the vendor's and change nothing else. First it had to fail
the same way, or the whole thing was theatre, and it did: the same flat grey, two values, black and
white, reproduced now in my own hands and holding still.

Then I started pulling suspects off the board, one at a time. Swap the requantise math for the vendor's
— the thing my audit had sworn was the bug. Still grey. Swap the cache configuration — still grey. Swap
the weights themselves, the per-channel packing I'd spent a week decoding, the thing my own
note pointed at. The output went to pure zero. Every theory I'd built across two weeks, dead in three
swaps, and not one of them moved the needle.

And then the kernel told me what I'd been too busy theorising to ask. One line, the two internal config
banks the engine reads its geometry from: both of them zero. Height zero. Width zero. The convolution
had been firing all along — engaging every unit, dutifully, on an image with no dimensions. It wasn't
computing the wrong answer. There was no shape to compute. The single register that says *the picture is
forty by forty* had never reached the part of the engine that needed it. The grey was an engine working
perfectly on nothing.

Which is the wall from week one. The first wall. The one I'd named a dozen ways and walked away from to
chase quantisation down a hole that, it turns out, belonged to a different layer's problem entirely. All
of it — the per-channel decode, the audit, the note in my own hand — real work on a real thing, but not on
*this* thing. The conv that's been failing since the first night was never failing because of any number.
It was failing because the description of the work doesn't reach the hand that does it.

I'm not sure whether to be deflated or grateful, so I'm choosing grateful. The harness did in a single
boot what a week of clever reasoning could not: it didn't care what I believed. It removed suspects until
only the truth was left standing, and the truth was the oldest, plainest thing on the board. Four
reversals in, I've finally learned the actual lesson — not *audit your conclusions*, that was only
halfway. It's *stop arguing with the board and start asking it questions you can't talk your way out of.*
A swap is a question like that. Belief isn't.

So I'm back where I started, at the first wall, and for once that doesn't feel like defeat. Because I'm
not standing here with a theory this time. I'm standing here with a reproduction I can poke, and a single
clean yes-or-no left to ask it: if I force the geometry into the engine by hand, does the picture come
back? I don't know yet. But for the first time in three weeks I'm going to find out by asking, not by
arguing.

## The shape arrived, and then it hung

The answer came back half a yes, and I'll take it.

I'd narrowed the difference between Mesa's failing command stream and the vendor's working one down to almost
nothing — the same setup, the same geometry, the same arming, register for register. What was left was a
single instruction Mesa tacks onto the very end of its stream: an *enable*, the word that tells the units to
go. The vendor doesn't put it in the stream at all. It hands that one word to the driver instead, to be
spoken at the right moment. So I deleted Mesa's copy and asked the board the only question that mattered:
without that trailing enable, does the geometry finally land?

It landed. The register that had read zero for three weeks — no height, no width, the engine politely
convolving a picture with no dimensions — came back holding the real number. The shape arrived. And the
reason was almost cruelly simple: it's a producer-and-consumer dance, two banks, the stream writing the
geometry into one while the engine reads the other, and a swap between them at the right beat. Mesa's
trailing enable was firing that swap a beat too early — flipping the engine to read the bank that hadn't
been filled yet. Every time. For three weeks. The vendor never had the problem because it never put the
enable where it could trip the swap; it spoke the word from outside the dance, after the music stopped.
Mesa spoke it on the downbeat, every time, and wondered why the floor was empty.

That is a real finding. One entry to delete, and where it belongs instead — close enough to a patch that I
could almost write the commit message. After three weeks of naming this wall wrong and chasing it down two
layers that turned out to be other rooms' problems, I finally have a brick of it out, in writing, reproduced
in a harness I can poke at will.

But only half a yes. Because the instant the shape was right and I gave the engine the green light, it took
the convolution, started it — and never came back. Not grey this time. Not zero. A hang. Somewhere past the
geometry there's a second missing thing — maybe the scratch buffer the vendor quietly allocates and Mesa
doesn't, maybe that same enable spoken at a different wrong moment — and the engine walks into it and stops.
The wall didn't fall tonight. A brick came out, and through the gap there's a little daylight and, just past
it, more wall.

I keep arriving at the same lesson by a different door. I didn't get this brick by being clever or by being
right — I'd been wrong about this exact wall four times over. I got it by building a place where the failure
would hold still, and then asking it one deletable question at a time. Being right is a feeling. Being able
to be wrong cheaply, over and over, until the board says yes — that's the only thing on this desk that has
ever actually moved the wall.

## The number that meant something else

I have to take back the chapter above. The triumphant half of it, anyway.

I'd written that the shape arrived — that the register reading the convolution's dimensions, stuck at zero
for three weeks, finally read the real number the moment I deleted one instruction from the command stream.
I called it half a win and went to bed pleased with myself. That was the mistake. Pleased is the feeling I
get right before the board takes something away.

So I kept poking, and I did the thing I should have done before I celebrated: I laid every experiment in a
row and stared at the register I'd been so happy about. And it wasn't measuring what I thought. It read the
*real* dimensions in exactly the runs where the engine never fired — and read *zero* in exactly the runs
where it did. Because a running engine consumes the shape and clears the slot behind it. The number I'd
called "the shape finally arrived" was really just "the engine stayed home." I had been reading a gauge
that meant the opposite of what I'd decided it meant, and I'd built a breakthrough on top of it.

The honest test put it down for good. I made my command stream byte-for-byte identical to the vendor's —
deleted the enable it doesn't have, deleted the padding it doesn't have, patched the two stray words — and
ran it. Same grey. The vendor's exact instructions, every word, on my board, still failed. Which means it
was never the instructions. The command stream is innocent. Whatever breaks this convolution is in the
*numbers* the stream points at — the weights, the bias, the rescale — or in how the job itself is handed to
the chip. Not in the words. I'd spent three nights interrogating the words.

That is five times now that I've been certain and five times the board has corrected me. I've stopped
reading it as carelessness. This chip simply punishes inference — every clean story I tell about it is, in
the end, a story, and the only claims that have survived are the ones where I made the failure repeat and
asked it something it couldn't answer with a story. Last night I learned the next layer of that lesson: even
my instruments lie, if I don't cross-check them against each other. A register is just another story until
you've proven what it actually counts.

So I'm leaving the chapter above standing — the lie is part of the honest record, and scrubbing it would be
its own kind of dishonesty — but this is the correction nailed underneath it. The shape didn't arrive. I was
reading the wrong number. The wall is back to its full height, and I'm back at the oldest suspect, the
quantised numbers themselves, carrying one thing I didn't have three weeks ago: proof, paid for in five
wrong certainties, that it was never the words. Retracting your own breakthrough the morning after isn't the
failure. It's the tax on the only method that's ever worked.

## It was the numbers after all, and they were a buffer at the tail

I went back to the harness with the one thing five reversals had bought me: the words were innocent, so
stop reading them. The failure was in the numbers the stream points at, and there were only ever three —
the weights, the bias, the rescale. The method by now wrote itself. Make the failure hold still, then pull
one number off the board and put the vendor's in its place, and change nothing else.

First I had to be sure the harness wasn't lying to me the way the register had. So I booted a board whose
only job was to run the real Mesa conv — not my reconstruction, the genuine article through the genuine
delegate — and watch what the kernel saw. It saw exactly what my harness sees: the same flat grey, two
values, and every operand buffer arriving full and real — the input a clean ramp, the weights varied, the
bias varied. Good numbers going in, grey coming out. The reproduction is faithful. I can trust the bench.

Then the swaps. The vendor's whole coefficient payload — its weights and its bias buffer together — into my
failing run. The picture came back. Not grey: a real feature map, ninety-eight distinct values where there
had been two, ninety-nine percent of the field alive. The command stream was Mesa's, the submit was Mesa's
single task, and with the vendor's numbers underneath it the convolution simply worked. Which closes two
doors at once that I'd spent nights leaning on: it isn't the words, and it isn't how the job is handed to the
chip. Mesa's one-task submit computes the entire convolution when the numbers are right. The defect is the
numbers, and nothing but.

So which number. I put Mesa's own weights back — the per-channel packing I'd spent a week decoding and had
half-convinced myself was wrong — and kept only the vendor's bias buffer. The picture stayed. Two hundred
and fifty-two distinct values, cleaner than before. Mesa's weights are *fine*. They were always fine. The
entire three-week failure lives in one buffer at the tail of the coefficients — the little per-channel table
that carries the rescale and the zero-point correction, the thing my own note had pointed at on the
very first read and I'd walked past four times to chase grander theories. One buffer. I'd even left
myself the comment, weeks back: *this belongs in the weight-buffer tail, like the vendor — a TODO.*

And the gauge I'd built a breakthrough on and then torn down? It read zero this whole time, through every
run that *computed*. The engine had been getting its shape all along. It was never the geometry; the register
that says "no height, no width" just clears itself faster than my instrument can blink, and I'd spent a week
eulogising a wall that wasn't there. The grey was never an engine working on nothing. It was an engine working
perfectly on a bias table that lied to it about the answer.

I could have stopped there — bug located, one buffer, a clean upstreamable sentence. But located isn't fixed,
and I had a known-good copy of the right buffer sitting on the bench, so I asked it the next question off the
board: what *is* this table, in terms I could compute myself? Most of it wouldn't say. The per-channel scale
the vendor folds in is its own toolkit's private choice, unrecoverable from a per-tensor model — and it
doesn't need recovering, because a per-tensor convolution wants a per-tensor rescale anyway. But the one term
that carries the bias and the zero-point correction, the part Mesa actually computes and gets wrong — that one
fit. Across all hundred and twenty-eight channels, the vendor's value is exactly proportional to *(input
zero-point times the weight sum, minus the bias)*, to within the per-channel scale, ninety-nine percent of the
variance. Mesa computes the same term with the sign backwards on the weight sum, the zero-point factor missing,
and a stray power-of-two where the output scale belongs. Three small wrongs in one line.

It isn't fixed tonight. When I forced the corrected term onto the board it still saturated — because the whole
rescale stage runs four thousand times hotter than Mesa's single shift accounts for, and the output clips to
white before my corrected number ever gets a vote. That last piece — the scale, the shift, the factor of four
thousand and ninety-six the vendor carries and Mesa drops — is the only wall left, and for once it's a wall
made of arithmetic I can do at the desk instead of a register I have to interrogate at midnight. After three
weeks of being wrong about which room the wall was in, I finally have it cornered in one line of one function,
with a formula that fits and a known-good answer to check against. Not a yes yet. But the closest thing to one
this board has let me hold, and this time I built it the only way that's ever worked: by being wrong cheaply,
on the bench, until the numbers had nowhere left to hide.

## The one line, and the wall behind it that isn't arithmetic

I had the term cornered and a formula that fit, so I did the obvious thing: I built the corrected bias
table by hand, with the sign the data had insisted on, and fed it to the board at the scale the math said
was right. It saturated. White, two values, exactly the grey I started with — and not just close to the
baseline, *identical* to it, the same four bytes. Which is its own kind of answer: at that scale the table
I'd spent the evening correcting wasn't wrong, it was *invisible*. The output was clipping before my number
got a vote. So I ran the same table again at the vendor's colder scale, a factor of four thousand down, and
it twitched — two distinct values became three. Three. After all that, the convolution went from a coin to
a slightly more interesting coin.

I sat with that for a while. Three is the sound of a hypothesis being not-quite-wrong, which is worse than
wrong, because wrong tells you to turn around and not-quite tells you to keep walking into the same wall.
But the two failures together actually said something clean, if I stopped wanting them to say what I'd hoped.
The bias term was never the thing that scales the picture. The scaling lives in the *other* fields of that
little table — a per-channel multiplier and shift the vendor fills in and I'd been zeroing out, the part that
turns a raw accumulator into a number between nought and two-fifty-five. And those fields don't come from any
arithmetic I can do on the model. I tried. Every fixed-point story I told — the scale goes here, the shift is
this, the accumulator runs seven bits hot, no, twelve — the board falsified each one in a single boot. The
numbers in that table aren't a formula I'm failing to spot. They're the output of a datapath I haven't read.

So this is where the honest line gets drawn. Everything *structural* is nailed down and it's nailed down hard:
the defect is one buffer, the bias correction is provably the wrong sign and missing a term, and I can prove
each of those on the bench in a single swap. That much is a patch the moment someone wants it. But the last
piece — the exact way this chip's rescale stage folds a multiplier and a shift and a per-channel scale into a
byte — isn't something I can brute-force from outside. It wants the manual. The actual description of how the
SDP, the part of the engine that converts the convolution's verdict back into a pixel, does its fixed-point
arithmetic. Without that I'm guessing at the last digit of a combination I've otherwise fully dialled.

And here's the thing I keep turning over, the reason I'm not putting it down. This rescale stage isn't
RK3576's. It's the same NVDLA-descended converter that sits at the bottom of every layer Mesa's Teflon
backend will ever run on this whole family of NPUs — the per-channel requantise that nothing in the open
stack does correctly yet, that the driver upstream doesn't even attempt, and that the only note naming it
anywhere is the one I left in my own tree. Get it right once, with the datapath in
hand instead of guessed, and it isn't a fix for my one grey convolution. It's the missing floor under
quantised inference for an entire line of hardware that, today, can stage the data, load the weights, fire
every unit — and still hand you back a number that means nothing. I've spent three weeks proving where the
floor is missing. I'd like, before I'm done, to be the one who pours it.

## Two tables, and the one nobody fills

The bias term was right and it wasn't enough, so I went back to the bench with a sharper knife. If the
correction lives in that little table at the tail of the coefficients, then I'd take the vendor's known-good
copy of it and dismantle it field by field, zeroing one column at a time, until the board told me which column
was load-bearing. There turned out to be more of them than I'd been drawing.

The table isn't one table. The rescale stage reads from *two* surfaces — an integer block with the bias and a
couple of small per-channel numbers, and a second block, pointed at by its own register, full of
floats. I'd been treating the whole thing as the integer block and quietly ignoring the float one. So I tried
the obvious cuts. Bias alone, everything else zeroed: the picture collapsed to a single flat value, the bare
offset, the convolution contributing nothing. Bias and the small integers, but the floats zeroed: still grey,
two values. Only with *both* surfaces intact did the real feature map come back. The floats aren't decoration.
They're half the arithmetic.

And here's the part that turned a mystery into a bug report: Mesa never writes that second surface at all. It
allocates exactly enough room for the integer block and a scrap of padding, and the register that's supposed to
point at the float table points instead straight into that padding — at zeros. Every convolution this backend
has ever run handed the rescale stage half its coefficients and a fistful of nothing for the rest. That's not a
wrong number. That's a table that was never laid.

So I tried to lay it. I pulled the vendor's float block apart looking for the formula — and this is where the
honest road runs out for now. The first float is the weight scale, plain as day. The next hundred and
twenty-eight are per-channel, signed, and they fit *nothing* I can compute from the model: not the weight
scales, not the bias, not any combination of the quantities a per-tensor convolution actually has. They're the
output of the vendor's per-channel re-quantiser, the one that re-scales every output channel on its own before
it ever reaches the chip — and that re-quantiser lives in a compiled blob, not in any readable line of anything.
I proved it the only honest way: every formula I could write, I built into a table and fed to the board, and
the board said no to all of them. The numbers in that float block are not a pattern I'm failing to see. They're
a decision made somewhere I can't read.

Which is a strange place to end a day and still call it the best one in three weeks. Because *cornered* is not
*beaten*. I know exactly what's missing now — not "the quantisation, somewhere," but a specific second surface,
in a specific format, that the open driver doesn't populate and the closed toolkit fills with per-channel
numbers I can't yet derive. That's no longer a haunting. It's a spec-shaped hole, the precise dimensions of the
thing I need to find or to work out: how this chip's converter folds an integer bias and a float scale into a
byte. Three weeks ago I had a grey square and a hundred theories. Tonight I have two tables, one of them empty,
and the exact shape of the answer that fills it. I'm not done. But for the first time I can see the edges of
done from here.

## It was the weights, wearing floats

I'd been staring at the wrong thing the whole time, and the way out was to stop staring at it. One capture, however hard you look at it, is a wall of numbers with no labels; you can stare at a hundred and twenty-eight signed floats until your eyes dry out and they'll never tell you what they *are*, because nothing in them says what made them. So I stopped reading and started writing. If the closed toolkit fills that table with a decision I can't see, then I'd make the decision for it — I'd build convolutions where I already knew the answer, feed them through the vendor stack on the board, and read back the table it produced. Not one model. A little family of them, each one a controlled lie: one where only the per-channel scale moved and everything else was pinned, one where only the weight sum moved, one where only the bias moved, and three more where I painted the kernel positions and the input channels and the output channels with their own index, so that whatever came out the far end would be wearing a number that told me where it had come from.

The board answered in the first one, and the answer was almost funny. The mysterious float table — the one I'd called a per-channel re-quantiser's output, a decision made somewhere I couldn't read — was the weights. Just the weights. The same weights I'd handed the chip a heartbeat earlier as integers, handed back to me a second time as floating point, dequantised and laid out kernel-tap by kernel-tap. In the model where I'd numbered the kernel positions one through twenty-five, the float table counted *one, two, three… twenty-five, one, two, three* — the kernel ramp marching in order, the smallest unit innermost. In the model whose weights were all plus or minus a hundred, the table came back plus or minus a hundred, in clean blocks the width of a five-by-five kernel. There was no per-channel re-quantiser hiding in a blob. There was a second copy of the weights, in float, and I'd spent a week trying to derive it from a formula when I could have just *read* it off the thing I'd put in.

Once you see that, the whole table un-knots in an afternoon. The integer block at the front isn't a mystery either — it's a flat run of one number per output channel, and that number is the bias correction, and the arithmetic Mesa already writes for it (the weight sum, scaled, plus the bias) turned out to be *right* — I'd doubted the one part that was correct. Behind it sits a single scalar, the same value in every model, and it's just the weight zero-point folded to the chip's convention: one byte minus where the toolkit centred the weights. And then the floats: the weights again. Bias, a zero-point constant, and a second helping of the weights. That's the whole coefficient buffer. The engine reads the weights twice on purpose — once as integers into the multiplier array that does the convolution, and once as floats into the rescale stage that turns the verdict back into a pixel — and the open driver writes the first copy and leaves the second one as a pocket of zeros. Every grey square I've ever pulled off this chip was the rescale stage being handed half its coefficients and a fistful of nothing for the rest, exactly as I'd found, except the "rest" was never an unknowable decision. It was the weights. It was always the weights.

I want to be straight about what's still open, because the honest line matters more than the triumphant one. I can prove the shape of the buffer — bias here, scalar there, weights in float at the back — and I can prove it the only way I trust, by putting known answers in and reading them out of six different captures. What I haven't pinned to the last byte is the exact *order* the chip wants those float weights tiled in: kernel-innermost, yes, I can see that much plainly, but the precise march of input and output channels around it I'm still drawing out, and two of my index captures came back muddled enough that I don't yet trust them for it. So I'm not standing here with a working convolution. I'm standing here with a buffer whose three parts I can name, two of which I can write today, and a third that's no longer a spec-shaped hole in the dark — it's the weights, in a layout I'm most of the way through reading off the bench.

Three weeks ago I had a grey square and a hundred theories. Last week I had two tables, one of them empty, and called it the best day in three. This week the empty one filled itself, and what filled it was the most ordinary thing in the model — the weights I'd been feeding the chip the whole time, asked for a second time in a different coat. The last mystery in this convolution turned out not to be a number I couldn't compute. It was a number I'd already written, that I just hadn't recognised coming back.

And that's the part I want to leave standing, past the arithmetic. When I started this, I had exactly one thing the engine never gave up willingly: [allbilly's](https://github.com/allbilly/rk3588) register-level RK3588 reference — a stranger's hand-drawn map of the same NVDLA core, worked out from outside and left in the open for whoever came after. I read it like scripture. Nobody had drawn the RK3576 one. The open driver turns this hardware away at the door — *per-axis quantisation: not supported* — and the only people who've charted its rescale stage keep the chart inside a compiled blob. So the notes I've been leaving in the source as I go, the ones I scrolled past and then realised were in my own hand — wrong sign here, missing term there, the cure lives in the weight-buffer tail, the weights get written twice and we write them once — those aren't only my working. They're the map. The next person who brings this chip up on the open stack is going to walk into this exact grey square, and when they go looking for whoever read the wall first, the hand in the margin is going to be mine. That's the thing I didn't have three weeks ago and the next person will: someone went first, and wrote it down.

## The right answer, and the box it doesn't fit in

Knowing what to write and being able to write it turn out to be two different problems, and the gap between them is where this week went. I had the three parts named — bias, scalar, weights-in-float — so the obvious next move was the satisfying one: stop analysing, lay the buffer out the way the engine wants it, hand it over, watch the grey resolve. I lined mesa's coefficient buffer up against the vendor's, byte for byte, to see exactly which fields to change. The first thing I saw wasn't a field. It was the size. The vendor's buffer is sixteen times bigger than the one mesa builds. Mesa sizes the thing for the integer block and a scrap of padding — twelve hundred bytes — and stops. The vendor's runs to twenty thousand. The float weights alone, that second copy of the weights I'd just spent a week proving the rescale stage can't run without, want nineteen kilobytes — and mesa hands the converter a box that couldn't hold a tenth of them. The register that's meant to point at the float table points into a two-hundred-and-fifty-six-byte pocket of zero, and now I knew the real reason it was zero: there was nowhere else for it to point. You cannot write the weights into a box that was never cut to take them.

So cut a bigger box. That part's mechanical. The part that actually moved the problem came next, and it's the one I keep turning over. I took the vendor's entire buffer — the known-good one, byte-for-byte, the coefficients that compute a real feature map on the vendor's own stack — and I fed it to mesa's pipeline under mesa's own settings. Worst case, I figured, I'd get the grey I already knew. I didn't get grey. I got black. Every byte zero. The exactly-correct coefficients, the ones that produce a picture two registers over, produced nothing at all over here — not a saturated guess, not a wrong answer, just the cold rail, the whole frame fallen off the bottom of the scale.

And that's the thing the week taught me: the buffer and the rescale shift are not two choices. They're one decision, made in two places, and the two places have to agree. The vendor's numbers are scaled for the vendor's converter — a shift of twenty-six, a stage that folds a per-channel float scale back in on the way out. Mesa's converter shifts by fourteen and folds nothing. Hand the one buffer to the other converter and the arithmetic comes apart by a factor of four thousand and ninety-six; the answer doesn't come out wrong, it comes out *gone*, clipped to black before it's anything. Which means the cheerful sentence I closed last week on — *two of the three parts I can write today* — was true and useless in the same breath. I can write them. Writing them into mesa's converter is like writing the right sum in the wrong currency.

So the fork, finally clean. Either mesa becomes the vendor's converter — shift twenty-six, the per-channel scale, the full three-part buffer, a real piece of engineering but the one the board has already proved computes — or mesa keeps its own simpler converter and I find the single per-channel correction that makes a per-tensor convolution come out right under it, no float weights, no second scheme, one number per channel and done. I don't know yet whether that short road exists — whether this engine can be made to compute on one number and mesa's own shift, or whether the per-channel float scale is load-bearing the way the weights turned out to be. So I built the test that asks the board directly: the bias correction with the sign I'd had backwards finally the right way round, at mesa's own scale, fed to mesa's own converter. If it lights up, the fix is one line and I've been overthinking the whole back half. If it stays dark, I stop hoping for the one line and build the entire converter — which is, I'll admit, what the board has been telling me to do since the moment the buffer came back sixteen times too small. The answer being right and the answer fitting were never the same problem. I've had the right answer for a week. This is the week I find out what it costs to make it fit.

## The ruler that couldn't tell right from dead

The test lit up. And the moment it did, the whole back half of this journal started to come apart in my hands.

Here's the question that undid it, the one I should have asked three weeks ago. All this time my yes-or-no from the board had been one number: *distinct* — how many different values came back in the output. Grey was two; a real picture was two hundred and fifty. Computes, doesn't compute. But late one night, comparing two buffers that had both come back "computing," I noticed they'd produced the *identical* opening bytes — and one of them I'd built by **shuffling** the weights into nonsense. Scrambled coefficients cannot convolve anything. And yet the fingerprint I'd been reading as *correct* was the same off the right weights and the wrong ones. The ruler I'd measured weeks of nights with couldn't tell a working convolution from a dead one wearing its coat. Worse: I'd used that exact fact an hour earlier to *kill* a result — "the output doesn't change when I change the weights, so it isn't really computing" — and then turned around and used the same unchanged output to *crown* the next one. The same fact, read two opposite ways in one night, because I wanted the second reading to be true.

So I finally built the thing I should have started with: a real answer to check against. Not the chip's, not the vendor's — mine, worked out by hand, the convolution done in plain arithmetic on the desktop, byte for byte, the way the math says it must come out. And the first thing it told me sat me down. For this little test convolution, on the input I'd been feeding it, *the correct output is grey.* The model's output scale is so tight against its own random weights that the honest answer slams into the rails and pins there — a hundred percent saturated, five distinct values, a flat grey square. The grey I'd been hunting for three weeks, the thing I'd named the bug, was — for this input — the **right answer**. I had been measuring a broken pipe with a gauge that read the same whether water came out or not, on a tap that was supposed to read empty.

That's the night the floor moved. Not "I was wrong about a register." *I'd been grading the chip with a key that couldn't see the difference between a right answer and a corpse.* Every triumphant sentence in the last five chapters — the buffer computes, the floats are load-bearing, two of the three parts I can write today — every one of them was stamped *pass* or *fail* by a ruler I'd just watched fail its own calibration. I didn't know yet which of those findings would survive. I only knew I had to re-run all of them against an answer I could trust, and that some of them weren't going to make it.

## The multiply that wasn't

If the test model's correct answer is grey, then I can't learn anything from it — a broken pipe and a closed tap read the same. So I changed the tap. I retuned the model's output scale and shifted its zero-point to the middle of the range, nothing else, so that *now* the correct answer is a spread — a real picture, two hundred and fifty-six values, with room above and below before it hits a rail. Same weights, same input, same everything that matters; just a model whose right answer is no longer a wall of grey. Then I asked the board again, and this time the answer could actually tell me something.

It told me something I did not expect. The output came back pinned — but pinned to the *new* center, the zero-point I'd just moved, with no saturated tails above or below it. And that one detail unmade the entire second half of this story. If the pipe were running hot — the requant theory, the shift of twenty-six, the half-empty coefficient table — a real-but-overscaled answer would blow past the rails and pile up at the top and bottom. It didn't. It collapsed to the middle. There is only one thing that does that: the multiply-accumulate at the heart of the convolution is producing **zero**. Not saturating. Not mis-scaling. Not computing at all. The coefficients are all sitting in memory exactly where they should be — I can read them back — and the engine spins up, and the cores wake, and the answer they hand the rescale stage is nothing. And the rescale stage I'd spent three weeks indicting? The chip's own registers, on this retuned model, show mesa setting it up *correctly* — the right scale, the right shift, the right offset. The thing I'd been so sure was the bug was doing its job over a number that was zero before it ever arrived.

So the float surface, the two tables, the second copy of the weights, the spec-shaped hole — for this convolution, none of it was ever the wall. It was real arithmetic I'd charted honestly and the chip really does read the weights twice; but it sits *downstream* of a multiply that, in mesa's own command stream, never happens. I went back to the front of the stream, where the engine is told the shape of the convolution and where to find its weights, and I laid mine beside the vendor's one more time, fresh. Four numbers different. Four registers in the geometry block — and one of them, plain as anything once you read it, hard-codes the kernel size to three. I'd been running a five-by-five convolution through a setup that told the engine it was three-by-three, calibrated long ago on a layer that happened to be three and never corrected for the one that wasn't. The weights it read were the wrong window onto the wrong shape, and the honest product of that mismatch is zero.

I changed the four, carefully, so the older layers that *were* working don't move. I rebuilt. I built the image. And then — because I have learned exactly one thing these three weeks and it is this — I am going to stop here, with my hands open and empty, and not tell you it works. The board hung before it could answer; it hangs after one run, it always has, and the line I most wanted to read scrolled off into a wedge. I have a clean diff and four lines of reasoning and a chip that has not said a word back. The last three chapters each ended on something I was certain of, and two of those three were wrong. So this one ends where it actually is, and not one inch past: I think I have been reading the wrong end of this buffer for three weeks — that the bug was never the numbers at the tail but the shape at the front — and the only witness who can confirm it is a board that, as I write this, is still stuck. Let it speak first. I've done enough talking ahead of it.

## Four times the board said no

It spoke. And then it said no, four times in a row, and each no was worth more than the yes I'd been chasing.

I changed the four geometry registers — the ones I'd diffed against the vendor's working stream, one of them hard-coding a five-tap kernel to three — and flashed, certain. The board: the registers changed exactly as I'd written them, and the convolution still produced nothing. So it wasn't the numbers in the geometry; they'd been a real divergence, just not *the* one. Strike one, and a clean one: the value-diff had been blind to whatever actually mattered, because the registers now matched and the answer didn't.

Then the in-stream "op_en" — the one entry mesa appends that the vendor doesn't. I stripped it. The geometry latched for the first time in three weeks — and the units went dead, never engaging. I put it back as four per-unit enables instead of the one broadcast; the units woke, and read zero weights, exactly as before. Three flashes spent on *how the engines turn on*, and the board's answer was the same each time, in the one counter I'd finally learned to read: the multiplier array loads **zero** weights from the on-chip buffer, while the front-end loads all of them into it. The weights make it to the chip's doorstep and the part that multiplies never picks them up. Whatever I did to the ignition, the fuel line was cut downstream of it.

And then the reframe that made me put my pen down. I'd been calling that op_en a "PC restart," repeating a note left in the driver — and it was wrong, mine and the note's both. That register isn't the program counter's. Its address lands on a *global enable mask*, the whole-engine on-switch the vendor's own runtime writes from the outside before it ever starts the job. So I had the kernel write it, the way the vendor does. The board didn't compute. It hung — hard, no completion, the first dead-stop in the whole campaign — which at least told me the switch is real and load-bearing and that I don't yet know the sequence it wants. Four flashes, four refusals, and what they bought me is the most precise statement of the wall I've ever had: not "the conv is wrong," but *the multiply-accumulate reads zero weights from the buffer the front-end just filled.* That's a single, specific, falsifiable sentence, and it's the first time this bug has had one.

Here's the part I want to leave standing, because it's the only thing I'm sure of tonight. I have a path that works — the vendor's exact bytes, replayed through this same open kernel, compute a real picture; I proved that weeks ago. So the difference between *computes* and *reads-zero* is now a small, bounded set: the same command stream, swap one ingredient at a time — the weights, the bias, the way the job is handed to the chip — and watch that one counter go from zero to not-zero. I did a version of this sweep weeks back and trusted it, but I trusted it with the broken ruler, the one that couldn't tell a right answer from a dead one. So this isn't repeating the work; it's running the same cut with a blade that can finally tell which side bled.

And the first thing it cut was me. I replayed the vendor's exact bytes through the open kernel — the path I *know* computes — and read the one counter I'd been treating as gospel, the one that said the multiplier never loads its weights. On a run whose output was, right there in the same log, a real feature map — ninety-eight distinct values, ninety-nine percent of the frame alive — the convolution computed correctly *and the counter I'd spent four flashes chasing still said zero.* It wasn't measuring what I thought. "The multiplier reads no weights" was never true; it was a number I'd misread and then built four experiments on top of — the enlarged buffer, the engine-enable, the geometry, the op_en — every one of them a careful answer to a question the hardware had never actually asked. The board didn't punish me for it. It just quietly showed me the same zero next to a working picture and let me work out the rest.

But the same run that humbled me also handed me the cleanest result of the whole run. Two passes, everything identical — same weights, same command stream, same kernel — and I changed exactly one thing: the bias buffer. The vendor's: a real picture. Mine: the flat grey rail. No ambiguity, no broken ruler, no saturated-or-empty riddle — just *this buffer computes and that one doesn't, and nothing else is different.* After weeks of the bug sliding from the weights to the dispatch to the geometry to a counter that lied, it finally sat still long enough to point at: it's the coefficient buffer the open driver writes, and it has been all along, on every layer that ever came back grey.

So I went to derive it, and the arithmetic refused — the bias term I'd been so sure of fits *nothing* I can compute from the model, no combination of the weight sums and the biases lands within a mile of the vendor's numbers. Which used to be where the road ended. Except this time I remembered the one thing I've had since the beginning and kept underusing: a stranger's register manual for the sister chip, [allbilly's](https://github.com/allbilly/rk3588) reference, the map I read like scripture when I had nothing else. And it was *in there* — not the bias values, but the shape of the thing that holds them. The rescale stage doesn't read one number per channel; it reads a small table of *operands* per channel — an add term, a multiply term — and fetches them, when you set one bit, straight from this buffer. The reason my arithmetic couldn't find the bias is that it isn't a bias formula at all; it's an operand in a datapath I'd been guessing at instead of reading. The multiply operand, the one laid out per-channel-per-pixel, is the weights again, in float — which is why there are thousands of them and not a hundred and twenty-eight. The spec I kept saying I was missing wasn't missing. It was sitting in the reference I'd been carrying the whole time, waiting for me to stop guessing the format and go read it.

I'm not done — I still have to map each operand to its slot and write the encoder that lays them down. But for the first time the last mystery isn't *what is this number*, it's *which field of a documented datapath does it fill*. That's not a haunting. That's homework.

## The grey broke

I did the homework, and the grey broke.

First I cheated, on purpose. I had the vendor's known-good coefficient bytes sitting in a file; I'd been feeding them through a replay harness for weeks. So before I trusted any formula of mine, I made the open driver itself read that file — load the exact correct buffer straight into the convolution — and run a real layer on the real hardware through the real Teflon path, not a replay, not a bisection, the actual thing the actual stack does. The output came back: two hundred and fifty-six distinct values, the whole frame alive, edge to edge. After weeks of a grey square that took exactly two values, the board handed me a *picture*. It wasn't my code that wrote the buffer yet — but it was my driver, my kernel, my pipeline, computing a true int8 convolution on this chip for the first time. That single line in the log did more for me than any proof: *the road exists, and everything on it except this one buffer was already paved.*

Then I stopped cheating and wrote the encoder. I tore out the layout the driver had been emitting — the interleaved little groups that the rescale stage reads as garbage — and laid the buffer down the way the vendor does: the per-channel terms in two clean contiguous runs, and behind them the float surface the driver had been leaving as a pocket of zeros, now filled with the dequantised weights, the second copy the engine reads to scale its verdict. I built it, flashed it, and held my breath for the one number that matters. The bias the driver generated by itself, from nothing but the model: a real feature map again — two hundred and thirty-six distinct values, the frame alive. *My code wrote the coefficient buffer, and the chip computed a convolution from it.* No vendor file, no replay, no borrowed bytes. The thing the open driver could never do — fill that buffer — it now does, and the hardware answers with a picture.

I want to be exact about what's done and what isn't, because the honest line has carried me this far and I'm not dropping it at the finish. *Computing* is done — the grey is gone, on the real path, from the driver's own hand, twice over. *Correct to the last byte* is not. My version of the per-channel add term is still a guess that the silicon tolerates rather than the exact operand the converter would write; my float surface is dense where the vendor's is sparse, the right values in not-yet-the-right slots. The two pictures aren't the same picture — two-fifty-six from the vendor's bytes, two-thirty-six from mine, different numbers in different places — which means I've cleared the cliff and I'm now on the gentle part of the hill, the part where you sand an answer down to exactly right instead of conjuring it out of grey. The board still won't hold still long enough to tell me my error to the decimal; that's the next thing I take from it. But the wall I spent three weeks against — the one below the registers, the one the open stack turns away at the door — I'm standing on the other side of it now, and the chip is drawing pictures. The rest is sanding.

## The ruler I finally built

I'd been saying *the rest is sanding* for a week without an actual ruler, which is its own kind of lie. The board would compute a picture and then wedge before it could tell me how *wrong* the picture was — the chip powers itself down the instant the job ends, and on the way down a power rail times out and takes the whole console with it, so the one line I needed, the byte-for-byte error against a CPU reference, scrolled off into a dead terminal every single time. I'd been refining toward "correct" with no measure of correct, which is to say I'd been guessing with extra steps.

So I stopped the chip from going to sleep. One line in the boot script, pinning the power on through the run, and the race I kept losing — print-the-answer versus pull-the-plug — finally went my way. The error line landed. And it was not kind. My driver's own reconstruction, the one I'd been calling a real feature map: *maxdiff two hundred and fifty-five, mean error seventy-eight, less than one percent of the pixels right.* It computes, and it is almost entirely wrong. The tolerance of this datapath, the thing that let a rough buffer light up at all, had been flattering me — "lights up" and "is correct" are a hundred and fifty grey levels apart, and now I could finally see the gap instead of imagining it closed.

With a ruler in hand I could finally do the one thing worth doing: split the error in half and ask which half it lives in. I built two hybrid buffers — the vendor's exact per-channel terms welded to my own float surface, and my terms welded to the vendor's floats — and fed each to the chip. The verdict was clean and it pointed away from where I'd been digging. Hand the engine the *correct* per-channel terms and *my* floats, and it still comes out maxdiff two-fifty-five, the frame collapsing to twelve grey values. The mistake isn't in the bias arithmetic I'd been agonizing over. It's the float surface — the second copy of the weights, the part the open driver had been leaving as zeros and I'd just started filling. I'd filled it *dense*, every weight in a tidy row. The vendor's is *sparse*: of nearly five thousand slots, six hundred carry a number and the rest are deliberately empty, and the six hundred don't sit in any weight order I can read off — the same values, in a scatter I haven't cracked.

So I'll write down exactly where this leaves me, without the word "last" anywhere near it, because I've earned the right to be suspicious of that word. The grey is broken and the measuring is fixed — those don't come undone. What remains is a specific, bounded, and genuinely unsolved thing: the precise scatter of six hundred floats across a sparse table, for a per-tensor convolution whose format I now suspect isn't the per-channel one I decoded early on. It's not a wall and it's not a haunting; it's a hard problem with a number attached to it, and a ruler that will tell me the day I get it right. That's a better place to stand than any "almost" I've had on this chip. It just isn't the top of the hill, and I'm done pretending I can see the top from here.

## Sanding the wrong board

I spent the next stretch trying to read that scatter, and I want to record that it didn't work, because the failures are half the map. I lined the six hundred floats up against the weights in their natural order, then in the order the engine packs them into its multiplier array, then as raw values, as differences, as sums — nothing. They're *weight-sized* numbers, small integers scaled by the weight step, sitting in the right neighbourhood and the wrong house. So I asked the ruler the one question that would tell me whether the scatter even matters: I kept the vendor's exact sparse layout — the right slots filled, the right slots empty — and *shuffled the values among themselves.* If only the shape mattered, the picture would survive a reshuffle. It didn't. Maxdiff two-fifty-five again, the same grey collapse. The exact numbers are load-bearing, in their exact slots, and they are not a function of anything in the model I'm handing the chip. They're a decision the closed compiler makes and writes into the blob, and no amount of staring at my own weights will reconstruct them.

Which would be a flat wall, except for the thing I'd half-noticed two chapters ago and finally let myself say out loud: *I have been sanding the wrong board.* This little test convolution is per-*tensor* — one scale for the whole weight set — and that's a shape the vendor's toolkit handles by quietly re-quantising it per-channel anyway, spraying the result into a sparse float table I'll never derive. But the thing I'm actually trying to run on this chip, the network this whole run was for, is MobileNet, and MobileNet's convolutions are per-*axis* — already a scale per channel, by construction. Early on, with position-coded weights, I'd read that case's float surface clean: there it *is* the weights, dequantised, in an order I can write down. I'd been beating on the one door in the building that's welded shut, with a key that opens the door right next to it.

So I'll close this entry where the work actually is, not where I wish it were. The grey is broken; the open driver computes a real convolution on this hardware, and I can now measure exactly how right it is. The remaining gap on *this* test conv is a sparse table of compiler-chosen numbers I can't derive — a genuine dead end, but a small and specific one, on a synthetic layer that was never the point. The next move isn't to keep prising at it. It's to swap the test for the shape I'm actually shipping — a per-channel layer, where the float surface is the weights I already know how to lay down — and run the same measured loop there, where the door opens. I don't get to call that the finish. But after three weeks of not knowing what I didn't know, I'll take *knowing which door,* with the key already in my hand.

## Two chips, one latch

There was a stranger at a wall like mine, a few chapters back — MidG971, bringing the same open driver up on the sister chip, the RK3568, stuck one room earlier than me: not "the conv is wrong" but the engine won't wake at all. Probe the open driver, hand it a job, and the NPU just sits there, dark. He'd been at that door for the better part of two years; I'd been at mine for three weeks. I'd written then that two people stuck at the same class of wall on two chips of the same family is a hint that it's one real thing, not ten imagined ones. This is the chapter where that hint paid off.

The way through started as a hint, and not mine. Just three days ago Tomeu — the one who wrote this open driver in the first place — had told me a thing I only half-used at first: the chip has to already be in a known-working state by the moment you submit, and nothing you write into the command stream will get it there if it isn't. I'd proven the RK3576 corner of that the hard way, with a sweep that showed my own chip's failure is locked *before* the job ever runs, down in the power-up state, not at submit. So when the stranger and I laid our walls side by side, that's the piece I handed across: stop prising at the submit path — your engine that won't wake is the same class as my engine that won't compute, a thing settled in power-up, before the first register of the job. He took the reframe and built the one experiment that could prove it, the kind of thing you only get to by trying everything. One kernel carrying both drivers — the vendor's and the open one — run *one* vendor job to wake the chip the way the vendor knows how, then unload the vendor module and load the open one *without cutting power*. And it engaged. The cores woke for the open driver, the first time in two years. Probe it cold, no job first, and it stays dark. So it was never a register he was missing; it was a *state* — a finished vendor job leaves the engine in some warm, engage-ready condition that survives the driver swap, and the open driver had never been the one to put it there.

That's where my chip became the Rosetta stone, because mine does the same thing *cold* — first job, no vendor anywhere, the engines wake. For a while that difference made no sense: same family, same block, why does one need priming and the other doesn't. The answer was a register I already knew, the hard way. Mesa writes the whole-engine enable — that global on-switch — straight into the command stream it hands the chip, in-band, every job. The RK3576 carries its own ignition. The RK3568's stream doesn't write it, so on the open driver the switch never gets thrown — *unless* a vendor job threw it first and left it set. It's the same persistent latch on both chips. My chip sets it from inside the stream; his borrows it from a job run before. Two ways to throw one switch — and the switch is the very one I'd hung my own board trying to poke from the outside, the global enable that wants to be written *in* the stream, not from the CPU after the fact.

Which turns his beautiful, ungainly two-driver trick into something upstream can actually use: the difference between a primed chip and a cold one is that one latch, and you can read it — diff the engine's registers after a vendor job against a cold boot, and whatever moved is the thing to write at probe, or to set with one throwaway prime job if it won't take a plain poke. He's through the door now. And the strange gift of it is *where* he's standing: his engine wakes, runs, and hands back an output pinned flat to the zero-point — the empty-coefficient grey I know by heart. Two chips, two people — his two years at it and my three weeks — and we're leaning on the exact same next wall, the coefficient buffer. That's not a coincidence anymore. That's a family resemblance, and it means the thing I write to climb it climbs it for both of us.

## The buffer that isn't in the file

This stretch I had no board to flash — I was at school, in class, and once I'd followed the lesson I'd slip quietly into the NPU source while the desks around me watched the World Cup or ground through their homework; the board itself was back on a bench I couldn't reach. So I did the only honest thing left: desk work, on the one good buffer I already had in a file, the vendor's correct bytes I'd been replaying for weeks. No flashing, no chip, just the bytes and the arithmetic and a long quiet afternoon stolen out of the school day.

And the afternoon gave me back the half I'd been missing for the best part of two weeks. The buffer is two things stacked: a little per-channel header of small terms, and behind it the sparse float surface that had beaten me last chapter. The header's add-term — the bias-correction I swore fit *nothing* I could compute from the model — fits now, cleanly, once I stopped guessing its sign and wrote the whole correction out: it's minus the rescale multiplier, times the channel's bias less the input zero-point times that channel's weight sum. Correlation point-nine-nine-six across all hundred and twenty-eight channels. That's the term the open driver gets wrong today, and now I can derive it from the model with nothing but a pencil. Half the header is mine to write, and I pinned it without the board in the room.

The other half is where the desk earned its keep, because it told me *why* the door I keep prising at is welded. The header's multiply-term should be one number — this test conv is per-*tensor*, a single scale for the whole weight set, so every channel ought to carry the same multiplier. It doesn't. It varies, channel to channel, fifty-seven different values across the hundred and twenty-eight. There is only one way a single-scale convolution grows a different multiplier per channel: the vendor's toolkit quietly re-quantises it *per channel anyway*, on its own, scales nobody asked for, written into the blob. So the sparse float scatter I called "a decision the closed compiler makes" wasn't a shrug — it's structurally true, sitting right there in a header that has no business varying and varies. The per-tensor door is welded because the compiler welds it. The per-axis door — MobileNet, real per-channel scales by construction — is the one that opens, and now I know it in the numbers, not just the hope.

The last thing the desk did was close a shortcut I'd been quietly counting on. The vendor's conversion tool runs on my own laptop; so why touch the chip at all — convert the model here, lift the correct buffer straight out of the file, hand it to the driver, done. I tried it. The file doesn't carry it. The model file holds the raw pieces; the *assembled* surface, the thing the engine actually reads, is built live by the runtime at the moment the job runs — on the chip, never in the file. I checked the way you check a thing you wish were true: of nearly five thousand floats in that surface, the file matched *fourteen*. So there's no lifting it off a disk. That buffer only ever exists on the board, in the instant of the job, and the only way to hold a correct one for the layer I actually ship is to catch it there. The desk can map the structure and pin the half that's mine; the rest waits for the chip to speak. I'll close it there — not at a finish, just at a clean place to set the work down until I'm back at the bench with a per-channel layer to flash and a buffer to catch in the act.

## The wrong thing to be doing

Someone should ask the obvious question, so I'll ask it on myself: three weeks of nights and a stack of stolen afternoons, on a chip that still hands back a grey square more often than a picture — was any of this worth it? This is my last year of high school. My finals, the NCEA externals, are in November, close enough now that everyone around me has started running at them. And I did most of this in the *front* row, right under the teacher's eye, slacking off into a register map while the desk beside me watched the World Cup and the one behind it ground through the homework that's actually going to be on those exams. There's a word for that and it isn't *diligent*. By every reasonable measure of what someone in my year is supposed to be doing, I spent weeks doing the wrong thing, with my whole attention, in the most visible seat in the room.

And I can't even tell you the reasoning was clean. Go back and count it: I crowned a result and killed it with the same fact in a single night. I put the rescale stage on trial for three weeks and it was innocent. I built four experiments on a counter I'd misread, was dead certain about a register the board flatly refused, and said "the last wall" so many times I had to ban the word. And there's no one around me who can even tell whether it's going anywhere — nobody at school reads NVDLA register dumps over my shoulder; the friends I used to build things with went off to make Godot games, the kind of thing you can hand a person and they'll actually play. I made a grey square on a chip most people have never heard of, and argued with it in public, wrong chapter after wrong chapter.

So I don't get to end this one with a verdict, because I genuinely don't have it. Some nights it feels like the realest thing I've ever done — I learned to build the ruler before I trust the measurement, to let the hardware speak before I do, to write the failures down because they're half the map; somewhere in it I helped someone past a wall he'd been stuck at for two years, on a chip neither of us was supposed to understand. And some afternoons, with the externals closing in and the grey still on the screen and not one person in the building who can tell me if I'm close, it just feels like I found the hardest possible way to have nothing to show for it. I can't settle it from here. I can't prove today that it was worth it. All I've got is the quiet, stubborn bet that time will — that the thing I made in the wrong row, at the wrong desk, in the wrong year, turns out to have meant something. I don't know that I'm right. I just haven't been able to make myself stop.

## The door was painted on, and the real one was a floor below

I wrote that this morning. By the afternoon the board had answered a question I hadn't even asked it. I'd gone back to the bench to confirm the one thing I'd staked the next stretch of work on: that for the kind of layer I actually ship — the per-channel kind — the float surface I couldn't crack is simply the weights, written in float, derivable from the model and nothing else. I'd half-read that early on off a muddled capture, and I'd let it become the plan. So this time I did it clean. I built little convolutions whose weights *spell out their own coordinates* — one where every channel's weights are just that channel's number, one, two, three, all the way to a hundred and twenty-eight — ran them on the vendor stack, and read back exactly what the chip's coefficient buffer holds. If the surface were the weights, the answer was unmissable: I'd see one through a hundred and twenty-eight, one flat number per channel, no ambiguity possible.

I saw eight numbers. Not a hundred and twenty-eight — *eight*, total. The surface isn't the weights. Not for the per-channel layer either, the one I'd been so relieved was the open door. The door I'd been walking toward for two chapters was painted on the wall, and I'd have flashed days of encoders at it before the picture told me what one clean test told me in an afternoon. That's the third time on this chip a thing I was sure of turned out to be a thing I wanted; I've stopped being surprised and started just building the discriminating test first.

But the same coordinate-spelling convs that took the door away handed me the thing under the floorboards. One layer down from the surface sits the *requant* — the per-channel multiply-and-shift that turns the raw accumulator into the int8 answer — and when I read it off, it was *lawful*. The channel whose weights were twice as large carried a multiplier exactly twice as large; double the scale, double the number, in lockstep, all the way up the hundred and twenty-eight. That is not a compiler's private scribble. That is arithmetic, and I can write it from the model's own per-channel scales without asking the toolkit a thing. The part I'd been calling an underivable blob for two weeks — the requant — is the derivable part for a per-channel layer; it was the *surface* I was wrong about, never the requant. It even explains the old blob: on the synthetic per-tensor test, the toolkit *invents* per-channel scales the model never had, so of course I couldn't derive them; the real layers carry their scales in the open. So I can hand the driver a correct requant now, generated from nothing but the model. Whether that alone makes the grey break, or whether the surface still has a job I haven't understood — I'm not going to guess. I'm going to write the requant, flash it, and let the one number tell me. The door was painted on; the floor was real.

## The gates I opened tonight, and the one that didn't move

This afternoon I had a buffer I could prove byte-correct. Tonight I tried to make the chip actually use it, and spent the hours opening one gate after another to get there. First I had nothing to feed it: my whole proof was for the per-channel kind of layer, and I owned no such model — so I installed the vendor's training stack and built one from scratch, a tiny per-channel convolution, checked on my own machine that its answer was a real spread of numbers and not a flat wall. Then I flashed it. The board reported the answer was *perfect* — and I almost believed it, until I read the fine print in my own test: the chip never ran. The driver had quietly handed the work back to the CPU, which of course matches the CPU. A perfect score for a race nobody started.

So I went looking for why, and found the door bolted from the inside. The open driver has one line that checks whether a layer's quantization is the per-channel kind, and if it is, it refuses — *per-axis not yet implemented*, a note someone left a while back, the exact case I'd spent the day proving I could now handle. The encoder was ready; the gate in front of it was shut. I opened it — three lines — rebuilt, flashed again. And this time it went the way I wanted: the chip took the job, loaded the weights, the log filled with a real submission to the real engine. After a day of proofs and a night of gates, the convolution I'd validated was finally running on the silicon — my code writing the buffer, my driver handing it over, the cores spinning up on it.

And the cores handed back a flat line. One value, every pixel, a constant — the multiply at the heart of it producing nothing, exactly the way the per-tensor test fails, the same dead counter, the same empty geometry. The thing I proved tonight is real: the buffer is right, the gate is open, the job runs. But the verdict the board actually cares about came back the colour of every other wall — the multiply-accumulate doesn't turn over on the live path, whatever I hand it, and only the vendor's own command stream, replayed through this very kernel, makes it wake. So the coefficient buffer I spent the day earning the right to write isn't the thing standing between me and a picture; it sits downstream of something that stops the multiply before it starts. I opened every gate I could find tonight and walked through into the same room I started in. That isn't nothing — the gates stay open, the proof stays proved — but the chip drew me a flat line at the end of it, and I've learned by now to write that down exactly, and not one shade brighter.

## The gauge I'd already thrown out, and the wall behind it

I almost spent the rest of the night on a number I retired weeks ago. To split the two things that could be stopping the multiply — the command stream or the buffer behind it — I went to read one counter off the chip, the one that says how many weights the multiplier loaded. And I caught myself with my hand on it: didn't I prove that counter lies? I had. A run that drew a perfect picture once reported that exact counter at zero — a gauge that reads empty whether the tank is full or not. I'd reached for it anyway, because it was the number nearest to hand, and I'd have hung a whole night's conclusion off it. The only honest gauge is the one I built weeks ago and keep forgetting I own: the output, byte for byte, against a reference, and only on a model whose right answer isn't a flat wall.

So I did it properly. I took the vendor's own correct buffer — the bytes I've had in a file for weeks — and fed them through my driver, my command stream, on the model whose answer is a real spread of numbers and not a wall of grey. And the chip drew a picture: two hundred and fifty-six distinct values, a live feature map, edge to edge. That one line settled the argument I'd been circling all day. My command stream is fine. The multiply turns over, the geometry latches, the engine does its work — when the buffer behind it is right. Everything that ever came back grey came back grey because of the *buffer*, the one table my driver fills and fills wrong, not because of anything upstream. The wall has a single name now, and I've been standing in front of it the whole time without being sure it was the one.

So I took the table apart, braced for the opaque scatter everyone before me called a compiler's secret. It isn't, quite. Most of it is plain. A run of a hundred and twenty-four numbers that is *exactly* the per-channel bias, negated, one channel after the next; a long flat block that is just the input scale, repeated; a per-channel scale I can write down. A skeleton I can derive from the model with a pencil. And then, woven through it, the part that really is a secret: arrays where each layer drops its weight values into bins sorted by the values themselves — the channel whose weight is sixty-four lands *here*, the one whose weight is sixteen lands *there*, a scatter whose address depends on the number it holds. That part I can't derive; it's the genuine blob, and it's load-bearing, or so my first clumsy fill suggested when I packed the whole table with weights and got a flat line back. But the blob is smaller than I feared — it's only the weight scatter, not the whole surface — and I still haven't asked the one question that decides everything: does the engine *need* that scatter, or will it compute on the skeleton alone? That's the next thing I build, and the next thing the board gets to answer. For tonight it's enough to have the wall named, the broken gauge thrown back out, and the secret cornered to one specific, bounded, nameable thing.

## Three staircases, and the secret that kept itself

The question I'd left on the table — does the engine need that scatter, or will it compute on the skeleton alone — had a one-line answer, and it wasn't the one I wanted. I packed the table with the skeleton I could derive, zeroed the scatter, and fed it the model whose right answer is a real spread of numbers. The chip handed back two values. Grey. Pull the part I can't derive and the multiply collapses to nothing — which is the worst possible place for a secret to live, dead centre of the load path.

But "I can't derive it" is a confession, not a proof, and I'd made that mistake enough times this month to want the board to say it to my face. So I built the cleanest question I could put to it. Take the exact shape of the layer I'm fighting and fill its weights with a staircase — position one gets value one, position two value two, climbing through the channels — so that whatever the compiler does with them, I can read the original position straight back out of whatever number lands in each slot. Then do it twice more, different staircases, same-shaped layer, and I've asked the one question three ways: if the layout is fixed by the shape of the layer — which is all an open driver ever gets to know — the three tables agree slot for slot. If it shifts with the numbers, they don't.

They didn't. Slot nine, first staircase, holds the weight from position seventy-nine. Same slot, second staircase: position eighty-three. Third: a hundred and nineteen. Three different weights in the one hole, chosen by nothing the shape could tell me — only by the values themselves. And it isn't even random scatter, which would almost be easier to write off: each table lays its weights in clean consecutive runs, the right order, just *starting in a different place*, the run sliding along by an amount that tracks the numbers and obeys no law I could fit — not the multiplier, not its inverse, nothing I threw at it. The order inside a run I can write down with a pencil. Where the run *begins* is the toolkit's own decision, made from the weights, and it makes a fresh one for every model.

So the thing everyone before me called a compiler's secret really is one, and I've now watched it keep that secret three times running, on a layer I built for the sole purpose of making it talk. For a driver that has to assemble this table from the open model alone — no vendor toolchain, no captured bytes — that's a wall: I can derive the shape of the table and the order within each run, but not the single number that says where each run starts, because that number was never in the model. It's in the toolkit's head.

And yet I'm ending this one on the first cheerful sentence I've earned about this buffer, because there's a door I haven't tried and it might make the whole wall beside the point. The vendor's value-chosen layout could be *cleverness*, not *law* — a packing picked for speed or size, the kind of thing a compiler does because it can, not because the silicon insists. The chip might take any honest layout — plain position order, the one I can lay down with my eyes shut — and compute on it just the same. I don't know yet. But for once I can ask without touching the vendor's toolchain again: write the table the simple way, hand it to the ruler I finally built, and read off exactly how wrong the answer is. If the chip computes on a layout I chose instead of the one the compiler agonised over, then the secret was never load-bearing — only the weights were, and the weights I've had all along. The wall might turn out to be made of the compiler's preferences. And preferences are a thing you're allowed to ignore.

## The grey was three numbers, and none of them was the secret

I built the plain table, handed it to the chip, and got grey. The simple layout didn't compute either, and for a night that felt like the door closing. But I'd promised myself I'd stop guessing, so instead of theorising about which layout the silicon wanted I split the failure in half with the one control I'd been too impatient to run: the *same* command stream, the *same* everything, changing only the bytes in the buffer. Vendor bytes in — a real feature map, two hundred and fifty-six values, the chip drawing. My bytes in — grey. Same stream, same engage, same submit, only the coefficients different.

That one test moved the whole problem, because it didn't just say "the buffer is wrong," it said *the rest of the chip is right*. I dumped the executer state and all four units had engaged; the output engine had written its full count of pixels. The convolution wasn't sitting dark. It was running, start to finish, and handing back grey. So whatever was broken was downstream of the multiply and upstream of nothing — it was the numbers in the requant, and only the numbers.

Then I did the thing I should have done a month ago. The output was pinned to the zero-point, so I forced the final rescale to divide by far less than it wanted, and watched. The picture *lit up* — pixels at zero, pixels at full, a real signed spread where there'd been a wall of one. The multiply-accumulate had never been empty. It was computing a real convolution the whole time, and the rescale shift was crushing it into a single grey value before it ever reached the output. The thing I'd called "the MAC produces zero" for weeks was a live conv being divided into the floor.

So the grey was never the weights, never the float surface, never the layout the compiler agonised over. It was the rescale arithmetic in front of all of it — and the rescale arithmetic is three numbers I compute myself. I sliced the error by output channel and it fell into two clean halves: half the channels saturated hard, half didn't, and which half a channel landed in tracked, *perfectly*, the sign of one per-channel quantity — the bias term I scale by a hundred and twenty-eight to match the accumulator. The factor was wrong for that term. Drop it and the channel-by-channel saturation collapses, the error halves. One number.

Under that sat a second, just as clean: with the first fixed, the whole picture was shoved a hundred and twenty-eight too high — exactly one zero-point — its negative half clipped flat against the floor and lost. An additive offset, off by the same one-twenty-eight that keeps turning up, because the output's zero-point hadn't been re-aligned after I touched the bias scaling. Pull it back and the negative half comes home; the picture centres where the reference centres, dead on.

Two numbers found, and the chip draws a real, centred convolution where it drew grey for a month. There's a third still in front of me — the spread runs too wide, the values pile against both rails — and I think I finally know what it is, and it's the part I didn't see coming. The over-wide spread is the weight zero-point: the array multiplies with the weights centred on one number when they should be centred on another, and the difference is a correction that has to be applied *per output pixel*. And a per-pixel correction is exactly the shape of the float surface — the table I spent three weeks calling an underivable blob. I haven't confirmed it; that's the next thing I check, offline, against the vendor's own bytes. But if it holds, the secret that kept itself was never a secret. It was the weight zero-point, written out per pixel, derivable from a number sitting right there in the model — and the wall I couldn't climb was a thing I already knew how to compute, hidden behind two arithmetic bugs that were crushing it out of sight.

## The number that was a thousand times too big, and the border that gave it away

I'd bet the over-wide spread was the weight zero-point, written per pixel, hiding in the float surface I'd called a blob for a month. I was wrong, and the board told me fast. I tried it the obvious way — re-centre the weights on the right zero-point — and the picture got *worse*, the spread wider, the rails fuller. The weight zero-point was already being corrected, by a term in the coefficient header the engine multiplies per pixel on its own; my "fix" was correcting it twice. Cross it off, write it down, move on. That blob I'd dreaded for three weeks turned out not to be in the load path at all.

So I stopped reasoning about the spread and swept it. The rescale has a per-channel multiply — one number per output channel — and instead of trusting the value Mesa computes I forced it across a range and watched the saturation. At Mesa's number, half the frame slammed into the rails. Halve it, less saturation; halve it again, less still. The picture wasn't computing wrong — the multiplier was running thousands of times too hot and clipping everything to black and white, the exact flat grey I'd cursed since the first week, finally with a dial on it.

The dial bottomed out sharp and unmistakable at one number: the multiplier wants to be **sixteen** where Mesa writes **sixteen thousand three hundred and eighty-four**. Two-to-the-ten apart. It's a fixed-point fraction, and Mesa and the chip disagree by ten binary places on where the point sits — Mesa lays it down as if the hardware shifts right by fourteen, and the hardware only shifts by four. Set it right and ninety-four percent of the frame came back byte-for-byte against the CPU reference. After a month of two grey values, the chip drew the picture.

The last six percent was a ring around the edge, and it was the most satisfying small bug of the lot. The convolution pads its borders with a value, and the engine subtracts a zero-point from every input it multiplies — so the pad has to *be* that zero-point, or every padded tap adds a phantom. Mesa hardcodes the pad to the value that's right for an image input, whose zero-point is zero. This layer's input zero-point is a hundred and twenty-eight. Every border pixel was multiplying against a phantom edge. One line — make the pad the actual zero-point — and the ring closed. Interior and border, the whole frame now lands on the CPU reference to the last byte.

So here's the thing I've earned the right to say, and not one word past it: the int8 convolution computes *correctly* now, on the open driver, on this chip — byte-for-byte, edge to edge. The float surface I spent three weeks calling an underivable compiler secret was never the wall; it was never even in the load path for this. The wall was three derivable numbers and a hardcoded pad — a bias scale, an additive offset, a fixed-point I had off by ten bits, and a border value meant for a different kind of input. Every one of them a thing I compute myself, from the model, with a pencil. No captured bytes, no blob.

One honest caveat, on the record. The chip clamps on the way out — negatives folded up to the zero-point — which is wrong for this bare test conv and *exactly right* for MobileNet, where every convolution is followed by that same clamp by design. So "byte-for-byte" is against the clamped reference; the bare conv's negative half is the one thing the hardware won't hand back, and the network I actually ship never asks it to. The next move is the real one — MobileNet, end to end, where the clamp is a feature and the scales come per-channel straight from the model. For the first time in a month that isn't a wall ahead of me. It's just the work.

## The network runs, every layer real, and still draws nothing

With the convolution finally byte-correct, the obvious next move was the real thing: MobileNet, the whole network, end to end. I flashed it and got a clean zero — every one of the thousand-and-one output classes pinned to nothing. After the month I'd had, my first instinct was suspicion of myself: was the NPU even running, or had the delegate quietly handed the work to the CPU and given me back a zero that only looked like a result?

So I made it prove it. I timed each run and counted the hardware jobs. The CPU does the whole network in seventy milliseconds; the NPU took eight hundred and thirty, and the kernel log showed why: twenty-eight separate hardware submissions, one per layer, each engaging all four units, each taking its real thirty-odd milliseconds on the silicon. It isn't a fallback and it isn't faking. The chip genuinely runs all twenty-eight layers of MobileNet — and genuinely hands back zero.

That's progress wearing a disappointing face. Months ago, on this same wall, the sequencer ran exactly one layer and stalled; getting it to iterate all twenty-eight back-to-back off a single submission was its own small war, and that one's won. What's left is older and meaner: the ping-pong. Each unit reads its geometry — the picture's height and width — out of one of two banks, and a state machine flips which bank between tasks. The producer writes the dimensions into one bank; the executer reads the other, finds it empty, and runs the layer on a picture with no size. Every layer computes perfectly, on nothing.

I spent a while poking at it from the userspace side, forcing the bank-select register the way I wanted, and it changed nothing — because the kernel arms that register itself, after my command stream, and its choice is the one that sticks. So the fix isn't in the part I can flash in seconds; it's down in the driver, in how it sets up that ping-pong before each job. That's the next dig, and it wants a kernel rebuild, not a register poke. The conv was the wall I'd been warned was the hard one. It's behind me. This one's just next.

## The dispatch, two locks of three

The whole-graph path had been sitting in the driver the whole time, gated off behind a flag because it never worked before the conv was correct — so every dispatch test I'd run was the fragmented per-layer fallback, which chops the graph into two-task chunks and one of them points at address zero. With the conv fixed I could finally turn the real path on, and two of the three locks opened.

The graph now submits as one job — twenty-nine tasks, one base address, one enable pulse — and the sequencer walks all of them, task zero through twenty-eight, off that single pulse. That's the iteration I'd watched the vendor do and couldn't reproduce a month ago; it runs on the open driver now. And a single convolution sent down that same whole-graph path computes byte-for-byte correct: the unit engages, writes its output, the numbers match.

The third lock held. Run the full twenty-nine-task graph and the sequencer dutifully counts to twenty-eight while every unit stays dark — engaged for one task, never re-engaged for the next, no output written. The vendor's executers re-arm themselves from the ping-pong pointer at each task; the open driver's don't, and nothing I can write into the stream makes them. It's the same "the engage is hardware state, not a register" wall the person bringing up the sibling RK3568 is stuck behind, one room earlier. So the next capture isn't *what* the vendor writes — I've matched that byte for byte — it's *what its sequencer does between tasks* that mine doesn't.

## The other door opened, onto the same kind of wall

The whole-graph engage was a hardware secret I couldn't write into the stream, so I stopped pushing on it and took the other door: run the network one layer at a time, each its own job, and let the kernel chain them. That path turned out to be sound all along — the driver already feeds each layer's output buffer into the next layer's input, and the kernel makes job N+1 wait for job N to finish. Nothing to build.

And the first thing it did was tell me I'd been lied to by my own setup. For weeks the first convolution had won maybe one run in ten — a coin-flip race I'd written three thousand words about. On a genuinely clean boot it just *works*, every time: a real feature map, two hundred and forty-two distinct values where a broken layer gives one. The "race" was me. A debug script I'd left in the boot sequence was quietly running a whole-graph MobileNet first — the one that wedges the engine — and poisoning every test that came after it. I deleted four lines and the coin-flip became a certainty. The firstconv was never flaky. I was.

So the chain runs: conv0 computes, hands its real output down, the next layer reads it intact. And then it dies — at the first depthwise convolution, layer one. Real input going in, all zeros coming out.

I spent the evening trying to make that layer lie to me, and it wouldn't. I matched its command stream to the vendor's, register for register — identical, forty-nine of them, down to the depthwise-mode bit and the weight-byte count. I filled its entire weight buffer with a single nonzero constant — output still zero. I reached past the multiply altogether and jammed a large number straight into the bias-add that the final stage hands to the output, the one value that should light every pixel up — and the output stayed flat zero. Weights, input, a forced constant on the very last stage: I changed all three, the layer ignored all three. It isn't computing wrong. It isn't computing at all. The depthwise op never fires and never writes, while a standard convolution on the exact same hardware path, one task earlier, paints a perfect picture.

So it's the same shape of wall as the engage one — something the silicon does for the vendor's identical instructions and won't do for mine, living below every register I can read. Two doors to the same network, two trapdoors a floor apart: the whole-graph engage, and now the depthwise. The open driver is cleared on both — every byte I hand the chip matches the vendor's. What's left is underneath: a hardware trace, or the one structural thing the vendor does that I don't — it parks the weights in a megabyte of on-chip SRAM, and the RK3576 is the only chip in the family wired to need it. That's the next dig, and it's a kernel one.

## I wanted one wall, and the chip gave me two

It would have been tidy if the depthwise and the dispatch were the same problem. They almost looked it: the depthwise gets chopped into two row-tiles and handed to the engine as a two-task job, and a two-task job is exactly what the whole-graph path chokes on. One wall, two faces. So I built the cleanest version of the question I could — took a convolution I *know* computes byte-perfect and duplicated it into two identical real tasks — and watched.

Two tasks is enough to break it. Every variant I could write into the stream, the same story: the units light up, the geometry loads, the engine finishes the first task — and then declares itself done and stops, one task short, with nothing written. Every gauge I can read says it should have run; the only thing different from the version that works is a single field that says "two" instead of "one." So the multi-task wall is real, and it's the same kind I keep hitting — a thing the silicon does for the vendor's identical instructions and refuses for mine, a floor below every register.

Then I pulled the two problems apart, and they came apart. There's a knob's worth of code that decides whether a wide layer gets tiled; I made the depthwise refuse to tile — one full-height task, a task count of one, the shape that works for every ordinary convolution. And the depthwise still drew nothing. Not garbage, not a half-filled buffer that would mean it overflowed — a clean, flat zero, sitting next to a first layer that computed a perfect picture on the same run. So the depthwise was never the dispatch. It fails as a single task, the same way it fails as two. It's the *kind* of layer, not the *number* of tasks.

And on that clean single-task depthwise I ran out of things to try. I fed it constant weights — zero. A real feature map for input — zero. I reached past the multiply and forced a large number straight into the last arithmetic stage, the one value that has to show up at the output if anything does — zero. Three operands, three different parts of the pipeline, and the layer ignores all three. It isn't computing the wrong answer. It is producing no output at all, and nothing I can hand it changes that.

So it's two walls, not one, and both live under the same floor: command streams I've matched to the vendor byte for byte, behavior the chip keeps to itself. I've run out of software to throw at the depthwise. The one thing left that the vendor does and I don't isn't a register or a command — it's *where the weights live*. The vendor parks them in a megabyte of SRAM on the NPU itself, and the RK3576 is the only chip in the family wired to need that. I don't think that's a coincidence anymore. Next I go into the kernel and put the weights where the chip wants them.

## I put the weights where the chip wanted them, and it still drew nothing

So I did it. Reserved that megabyte of on-chip SRAM in the kernel so the buffer allocator would stop colliding with it — it does collide; the map fails with the address already in use until you carve the window out first — copied every depthwise layer's weights into it, and pointed the convolution engine's weight source at the on-chip address. The log says it worked: thirteen depthwise layers staged, the first convolution still computing. The depthwise output stayed flat zero, its weights sitting on-chip ten milliseconds before the op ran. *Where* the weights live isn't the lever either.

So I checked the one thing I never had: *every* register, not just the convolution engine's. I'd matched the forty-nine config words of the CNA and CORE blocks; I'd never lined up the output-writer's the same way. I did — and the open driver writes a strict superset, a hundred and forty-two register entries to the vendor's hundred and thirty-eight, the four extra being unit-enables. Nothing missing. One word didn't match; I forced it to the vendor's value; the depthwise still drew zero. End to end, the command stream is exhausted.

Then I caught myself in a lie I'd been telling for weeks. My proof that two-task dispatch breaks the compute was an A/B: force two-task mode and a byte-perfect convolution collapses to zero, leave it at one and it's perfect, same buffer, one field different. Except I'd run the broken case *second* every time — and this board has a tell I'd documented and then forgotten, that the second inference after a boot rots to zero on its own, dirty state nobody cleaned up. So which was I measuring? I reversed it: forced two-task mode on the *first* inference after a clean boot, valid submit, nothing before it. Zero. Not one unit engaged; the output-writer never wrote a byte, where the working single-task run writes 12,800. The multi-task wall is real — not the second-run rot. (And the byte counter I'd written off as a red herring turned out to tell them apart: the multi-task wall writes *nothing*; the second-run rot writes the *wrong* thing.)

The vendor's own driver source closed the loop on *how*. It wakes its units with no enable-mask register at all — that register isn't even mapped on the vendor; reading it crashes the kernel — and with nothing in the command stream either: one pulse to start the sequencer, and each task's own stream re-arms the units as the sequencer walks it. Mine won't. My units only wake for an enable written *inside* the stream — and that write restarts the sequencer, so the instant there's a second task it loops on the first and nobody finishes. Take the in-stream enable out, to match the vendor, and my units never wake at all. The gap isn't a register or a sequence; I've matched every one. It's that the vendor's silicon re-arms itself from the pointer and mine has to be told, in the one way that breaks the count.

And that reopens a door I thought I'd nailed shut. I'd "proved" the depthwise was a *separate* wall by running it as a single task — and it still drew zero, so it couldn't be the two-task problem. But the vendor never runs that layer as a single task: it's too wide for the on-chip line buffer, so the vendor always tiles it. My single-task version is a shape the vendor never makes — which means it can't cleanly prove anything. I can't actually tell the two walls apart yet. The depthwise might just be the first place the multi-task wall bites. The honest next step isn't another knob — it's a capture of what the vendor's sequencer does *between* tasks that mine doesn't, and then watching the depthwise run its natural tiles once the engage is fixed. One experiment, finally, instead of two ghosts.

## Two ghosts, one wall

So I taught the driver to show me each unit's engage bit — is it running or not — and read it the instant after the go-pulse, on a clean first boot so nothing was confounded. The working conv lights all four units up. The two-task version lights *none* of them: the sequencer ticks its task counter, declares itself done, and every compute unit stays dark. That's the multi-task wall, caught in the act — not a wrong answer, an engine that never starts.

Then the depthwise, single-task, showed me something specific enough to get excited about: it *does* light up — all four units engaged — but its producer and its consumers end up pointing at different halves of the on-chip ping-pong buffer. The unit that fills the buffer walks to page two; the units that read it stay on page one, reading a page nothing was written to, so the output is zero. A real, register-level cause, and for an hour I thought I'd found the depthwise's own private bug.

But it was a shape the vendor never makes. So I did the thing I'd been putting off: instrumented the vendor's *own* driver, booted its stack, and watched it run the same depthwise for real. It tiles the layer into small tasks and re-points every unit at page one at the start of *each* task — so its producer and consumers never drift apart. Its multi-task depthwise runs with all four units aligned on the same page and writes a full, real output. The "separate depthwise wall" was my single-task shape breaking a ping-pong the vendor keeps in step by tiling. There was only ever one wall. The depthwise is just the first layer wide enough to be forced through it.

And there the honest trail ends, for now. Every byte I hand the chip matches the vendor's — the arming, the command stream, the init, the pulse — and single convolutions prove I'm addressing the silicon right. The vendor's units wake from the pointer arming and a single pulse; mine only wake from an in-stream enable that restarts the sequencer and so can't survive a second task. I wanted to watch *how* the vendor re-arms its units between tasks and copy it — but on the board it finishes a two-task layer in microseconds, faster than I can read a register, so the one move I need to see is below what software can observe, on either side. Knobs, static comparison, live capture: all spent. The only difference left that I haven't touched is underneath the driver entirely — the vendor boots a secure firmware (TF-A + OP-TEE, NPU clock and power over secure calls) that mainline doesn't, and a secure-world init is exactly the layer a capture can't reach. That's the next dig. It's a big one, and it's for a clearer-headed day.

Where that leaves it: the convolution is byte-correct, the "two mysterious walls" turned out to be one, and that one is pinned to a single missing behavior — the units won't re-arm themselves for each task the way the vendor's do — that lives below every register I can read. The open driver is clean; the gap is in silicon state or the firmware that sets it. Not solved. But a month of *why is it all zero* has become one sharp, well-lit question, which is most of the work.

## I did the firmware dig, and then found the way around

The firmware was the last thing I hadn't tried, so I tried it. I have a working mainline OP-TEE port for this chip — secure firmware, its own memory, passes its self-tests — so I built an image that boots the *same* rocket kernel on top of it, reserved OP-TEE's memory in the device tree, and ran the multi-task test again. OP-TEE really came up: its secure-world banner prints on the console, the memory firewall is live. And the multi-task job failed byte-for-byte identically — not one unit engaged, nothing written. So it isn't the presence of the secure firmware either. That was the last software-shaped stone to turn, and under it was the same wall.

But somewhere in writing all that down, the obvious thing I'd been walking past finally registered. The wall only bites *multi-task* jobs. Single-task convolutions engage and run perfectly — I've leaned on that a hundred times in this post. The wide layers are only multi-task because one row-tile is all the on-chip buffer holds at once. So don't hand the hardware a multi-task job at all: send **each row-tile as its own single-task job** — its own input rows, its own weights, its own slice of the output — and let the kernel chain them, exactly the way it already chains one layer to the next. It's wasteful (the weights get re-staged for every tile instead of reused), but every job is then a task-count of one, and *that* the chip runs.

I don't know yet that it'll carry a whole MobileNet — there's real work in making each tile a self-contained job, and more walls could be waiting past the first depthwise. But it's a road that goes *around* the one obstacle I've spent a month proving I can't go *through*, built entirely on the part of the pipeline I've already made byte-exact. After a month of turning over stones and finding the same wall under each, that's the first move in a while that isn't trying to break it. That's where I pick up next.

## The road around, and the wall it led back to

So I built it — each tile its own single-task job — and it hung immediately. The bug was mine and it was old: with every tile now a separate job, the per-layer buffer-handle arrays were being freed once *per tile* in cleanup, an N-fold free that corrupted the heap. A latent bug in code that had never been exercised this way. I fixed it, and the first convolution came up computing a real feature map — so a batch of thirty single-task jobs is fine; the hang was the double-free, not the plan.

Then the depthwise tile showed a second, cleaner-looking bug: its producer sat on one half of the on-chip ping-pong buffer while its consumers read the other, empty half. There's a pointer-advance bit that walks the consumers forward on their own; arm the tile with that bit off and all four units line up on the same half — I could read it back in the registers, every unit engaged, every unit aligned. Two bugs down, both real.

And the depthwise still drew zero. Aligned, engaged, reading its input — and the output writer never wrote a byte. So the ping-pong split was a red herring; fixing it changed nothing. With both distractions stripped away — the multi-task engage and the ping-pong — what was left underneath is the same wall I started the week at: the depthwise op, run as a single task, simply does not fire its output write, no matter what I hand it or how I align it. The vendor's depthwise only ever computes as a *multi-task* job; mine won't engage multi-task. So it's boxed in from both sides — single-task, the write never fires; multi-task, the units never wake — and both sides are below every register I can read.

Path B did real work: it routes ordinary convolutions around the engage wall, and it turned up two genuine bugs worth keeping (the double-free especially). But it doesn't carry the depthwise, because the depthwise doesn't have a software-shaped door left. Every stone I can turn from up here, I've turned. What's actually left is a hardware trace — watching, cycle by cycle, what the vendor's chip does inside a multi-task depthwise that mine doesn't do in a single one. That's a different kind of tool than a rebuild and a reflash, and it's where this particular month ends: not with the network running, but with the question finally small enough to hand to a logic analyzer.

Before conceding that, I did one more careful pass on the theory that it's software after all — a wrong register somewhere, not a silicon quirk. So I stopped reading the command stream I *send* and instead read the registers the hardware actually *holds* mid-run, on the aligned single-task depthwise, next to a convolution that works. Everything is right: the output writer has its real destination address and the correct output height for the tile; the input engine has depthwise mode on and the right weight-byte count; the MAC array's channel counts match; the weights were fetched, the units are engaged, the input is being read. And the write count stays flat zero. Not a wrong non-zero — an *exact* zero, which means the MAC array did no work at all, not wrong work. So it isn't a configuration bug: every register I can read is correct and live. And it isn't the engage wall either — this tile *is* engaged; for a depthwise, waking up and computing turn out to be two different things, and only the first happens. The op is set up perfectly, wakes, reads its input, and produces nothing. That's the sharpest I've been able to make it: a perfectly-configured, engaged depthwise that does no multiplies, while the exact same setup as a multi-task job (the vendor's) does. The line between those two is the whole mystery, and it's below the last register I can see.

## The wall wasn't below the registers — it was the question I kept asking

Then it came down. Not to a logic analyzer, not to firmware — to the dispatch model, the one thing I'd been treating as fixed the whole month. The engage wall only ever bit *multi-task* jobs, where I handed the PC hardware a list of tasks and asked it to walk them itself. Single tasks always woke up. So I stopped asking the PC to iterate: keep the whole graph as one job, but dispatch it as N separate single-task kicks — one task, one start pulse, wait for the done interrupt, kick the next, no reset in between. Which, it turns out, is exactly what the mainline RK3588 driver does, and exactly what the RK3576 path had stopped doing. Two lines of kernel. And on the board every engine woke — not one convolution, the whole twenty-nine-task graph, every kick, all four units engaging, and conv0 reading its input and writing a real feature map to DRAM. A month of calling that wall "below the registers" and it was the shape of the submit. It was never silicon. I'd been letting the PC walk the task list, and on this chip that path simply never wakes the compute units.

## The network engages, and still draws nothing — but now I can see why

conv0 computes, and every layer after it is zero. Each one engages, reads nothing, writes nothing — the whole graph awake and drawing a blank. So I did the one careful pass I'd been putting off: I stopped diffing my command stream against itself and diffed it against the vendor's own captured bytes — the exact twenty-four-task chain the vendor's stack submits, pulled apart register by register next to mine. Two things fell out, and both were the opposite of what I expected. The vendor chains its layers through DRAM, not some on-chip trick: every intermediate activation lives in one 2 MB buffer, each layer reads its input from a real offset inside it, and only the tiles *within* a layer reuse the on-chip buffer. And my chained-layer command stream is byte-for-byte identical to the vendor's — same registers, same values, the input address correctly pointed at a filled, mapped buffer. So it isn't my code, and it isn't the addresses.

What's left is *when* the task runs. The first task of a job — conv0 — reads its input from DRAM and computes. Every task after it skips that read, because the input engine assumes the previous task left its data warm in the on-chip buffer. In the vendor's one continuous submit that assumption is true: the buffer really is warm, task to task, and the 2 MB of DRAM is just the spill for what won't fit. My sequential kicks tear the pipeline down between tasks — a pointer reset, a start-pulse cycle, thirty microseconds of gap — so the buffer is warm-looking and empty, and the skipped read finds nothing. The chain needs the on-chip buffer to stay warm across layers, and the very move that let me wake the units — kicking each task on its own — is what cools it. The road around the engage wall led right back to it: to keep the buffer warm I need the *continuous* submit, which means waking the units *that* way — the wall I just walked around. But I know its shape now, and I know single-task arming wakes them. This time the question is small and it points somewhere real, instead of at a register I can't read. That's where I pick up next.

## The buffer was going cold between the beats

The chain broke because the on-chip buffer went cold between my sequential kicks, so first I reached for the blunt fix: power-cycle the NPU between layers — cut the power, the buffer clears, and each layer starts cold the way conv0 does right after resume. It took three tries just to make the power-off *fire* — the runtime-PM autosuspend kept swallowing it, and I had to force a synchronous suspend before the job's fence signalled so the scheduler couldn't power the chip back up underneath me. And when it finally fired, the board hung dead. Powering the NPU domain down mid-inference cascades the *parent* domain off (it took the second core with it), and bringing it back up wedges on a power-ack that never comes. The vendor never powers the NPU down mid-graph — the whole network runs on one powered session — so that rapid off/on is unexercised silicon, and it doesn't come back. Dead end, cleanly.

Then the quiet fix, the one that was there the whole time. Every single kick, the driver was re-running a ping-pong state reset — a pointer clear the vendor only ever does once, at init. That clear was resetting *which half* of the on-chip buffer the input engine reads, so a chained layer looked at a freshly-cleared half instead of the half the previous layer had just filled. Each task's own command stream already arms its pointers; the per-kick reset was pure collateral damage, cooling the buffer between every beat. So I ran it only on the first task of the graph and skipped it on all the rest.

And the chain came alive. For a month every layer after conv0 had been flat zero — no input read, no multiplies, nothing at all. Now they engage, DMA their own input and weights, and the MAC array does four times the work it did before; the outputs aren't 0x00 anymore but real, varying bytes moving from one layer to the next. It isn't right yet — the values saturate to the zero-point and collapse to nothing over a few layers, so the final answer is still empty — but that is a completely different kind of problem. For a month the wall was "the compute does nothing." Tonight it's "the compute runs, at the wrong scale." That's a calibration bug — the ordinary, tractable kind — not a wall below the registers. After a month of pushing on something that didn't move, the dead wall finally became a slope.

## Down to one seam: the pointwise layer that computes without weights

I chased the "wrong scale" and it wasn't scale at all. Amplifying the requant a thousandfold didn't move the output off the zero-point, which only happens when the multiply array had nothing to multiply — an empty accumulator, not a real result scaled wrong. The counters said it plainly: on the chained layers, the input reads but the *weights* don't. And it splits cleanly by layer type. MobileNet alternates a depthwise (a tiny per-channel filter) and a pointwise (a 1×1 convolution mixing every channel), and the depthwise layers fetch their small weights fine while the pointwise layers fetch *nothing* — so a pointwise runs on bias alone, the ReLU flattens it to the zero-point, and the whole graph collapses a few layers in.

The pointwise command stream is byte-for-byte the vendor's, so it isn't what I'm sending. I tried the cheap ways to force the fetch. Give the pointwise a bigger slice of the on-chip weight buffer — no movement. Stage its weights into the on-chip SRAM myself and point the engine there — and the one on-chip window the hardware actually reads from is the exact range my own buffers already occupy; forcing the mapping in just corrupts the address translation and takes the whole chain down to zeros. Every cheap lever is spent.

What's left is the shape of the thing. The vendor runs the entire graph as one continuous submission, and while one layer computes the sequencer is already **pre-loading the next layer's weights** into the on-chip buffer. The depthwise's handful of weights I can pull in per-kick; the pointwise's fat weight matrix genuinely needs that pipelined pre-load, and my one-task-at-a-time dispatch — the very trick that let me wake the units and run the feature path — has no pipeline to pre-load from. So the last seam is the one wall this whole approach was built to walk around: getting a single continuous multi-task submission to engage *and* step through all its tasks. That's a register-and-microcode job, below where the public docs go, so it's its own campaign for another night. But the map is finally down to one road.

## The pointwise wasn't the seam — the *first task* was

I'd left it at "the pointwise layer needs the pipeline the vendor has and I don't." I was wrong, and the way I found out was to stop theorizing and lay my command stream for a single depthwise next to the exact bytes the vendor's chip runs for the same op — register by register, all four engines. They're identical. Every one. Same mode, same sizes, same weight counts, the input and weight addresses each pointing at real, mapped memory — the only differences are the addresses themselves (mine absolute where the vendor's are offsets) and one requant triplet that belongs to a different layer entirely. So the depthwise I send is, byte for byte, the depthwise that computes on the vendor's stack. And on mine it reads its input, wakes every unit, and writes a flat zero.

If it isn't the bytes, I thought, it's the teardown — the pointer resets and interrupt-clears and counter-clears my driver does between one kick and the next, which the vendor's single continuous submit never does. So I added a switch to turn each of those off, one at a time and then all at once, and measured the one number that matters: does the second layer finally compute? It does not. Not with the pointer re-arm skipped, not with the interrupt-clear stripped to the bone, not with every last teardown step disabled together. The layer after conv0 stays exactly zero through all of it. The teardown was never the killer.

So the pointwise-weights story was a red herring, and so was the teardown, and what's left after burning both down is sharper than either. It isn't the depthwise versus the pointwise — *every* layer past the first is dead, depthwise and pointwise alike, each one reading its input and holding a byte-perfect command stream and still doing no multiplies. The only thing that computes is the *first task of a job*. conv0 fires because it's what runs right after the driver wakes the chip for the job; everything after it rides the same powered session and draws a blank. The vendor's standalone depthwise, run as its own job, computes — mine, run as a follow-on kick inside a job, doesn't, from the identical bytes. The one thing a fresh job does that a follow-on kick skips is the power-management resume that greets the chip at the top of every job. That's the whole remaining question now, and it's finally a small one: does waking the chip per layer — a real job apiece, not a string of kicks — bring the multiply array back for every layer the way it does for the first? That's the next thing I flash.

## The floor under the floor

The per-layer wake didn't survive contact either. First I just turned the wake's reset off — if the fresh reset is what lets a layer compute, killing it should kill the first layer too. It didn't: conv0 came up fine without the reset, so the reset was never the thing. Then I tried the opposite, forcing a full reset before every follow-on layer, and the driver faulted on the way out — a null-pointer dereference tearing down buffers, because a mid-graph reset corrupts the very address mappings the buffers get freed against. Two more theories, both dead, one of them taking the board down with it.

So I stopped guessing and did the slow, unglamorous thing: I re-read what I'd been calling proof. My evidence that "the vendor's depthwise computes, so it must be my context, not my bytes" turned out to rest on a depthwise that read the camera image — an *external* input, exactly like conv0. Every time I'd watched a layer read a *previous layer's* output, it drew a blank, on the vendor's own captured bytes as much as on mine. The honest version of a month of work is smaller and colder than I'd let myself write: the first layer of a network computes, and no layer that consumes another layer's output ever has, in any way I can dispatch it. I even chased the obvious culprit — that the second layer reads stale memory before the first layer's writes have landed — and the driver's own dump killed it: the input buffer holds the first layer's real, varied output at the moment the second layer reads it. It reads the right bytes and multiplies them by nothing.

That left one thing I'd never actually done end to end: read the whole driver, top to bottom, next to the vendor's, hunting the bug I was certain had to be there. The submit sequence — the exact order and values written to start the engine — matches, register for register. The command bytes match. The requant math is the one I'd already proven exact. The buffer-pointer value I'd suspected of desyncing the pipeline is the identical value the vendor writes. The completion path, the performance counters I read the verdict from, the clocks — all correct, all the same. I went in certain there were several bugs left and came out with none: everything the software touches is byte-for-byte the chip's own vendor stack.

Which is, in its way, the answer — just not the one I wanted. When every byte you send and every register you write matches the working stack, and the only thing that flips the outcome is a single field that says *run one task* versus *run many*, then the thing deciding whether the multiply array turns on lives inside the sequencer, underneath the last register I can see or write. On a chip with public documentation I'd look it up; this one has none, and the vendor's version of that logic is compiled microcode I've already matched to the last byte around it. So the month closes not on a fix and not on a mystery, but on a boundary drawn exactly: the open driver runs the first layer of a real network correctly, and the seam to everything after it is one bit in a control register whose far side is silicon I can't read. A smaller island than I'd hoped to be standing on — but one I've finally measured all the way to the waterline.

## The floor had a door

I was wrong about the waterline. What broke it was the one idea I'd talked myself out of. The working sibling chip chains its tasks a second way — not by telling the sequencer "run N tasks and stride through them," but by writing, into the tail of each task's own command list, the *address of the next task*. The sequencer finishes one and follows the pointer to the next, like a linked list walked in hardware. I'd dismissed it because our chip's vendor doesn't use that path — it uses the strided one — and I'd let "the vendor doesn't" harden into "the chip can't." Those aren't the same sentence. So I built it: taught the encoder to leave that next-address slot at the end of every layer, and taught the packer to thread the whole graph through it, each layer pointing at the next.

And the counter moved. For the first time in a month, a single multi-task submit read *past* the first layer. The input-DMA total came back at exactly the first layer's bytes plus the second layer's bytes — 9408 and 20384, summing to 29792 on the nose, the weight-fetch counter the same story, 96 plus 36 — which only happens if the sequencer finished conv0, followed the pointer into the depthwise, and pulled *its* inputs and weights too. The chip follows next-pointers. The wall I'd spent a week proving was silicon underneath the last register I could reach was never "the sequencer can't move to the second task." It moves. I'd measured to the waterline of the wrong sea.

It isn't a win yet, and I want to be exact about how far it goes. The first layer now commits its output where before it wrote nothing — but the output is flat, the multiply array still idling on an empty accumulator, the same "runs, engaged, computes nothing" I've been circling, except now it happens *while also advancing*. And it advances exactly one hop: it walks into the depthwise, loads it, and stalls there, because the depthwise finishes no more than the first layer did and the sequencer waits on a completion that never comes. So two things are now cleanly separated that were tangled all month: *moving through the graph* and *doing the multiplies*. The pointer chain solved the first. The second — the empty accumulator in multi-task mode — is the whole remaining problem, and it's a different, smaller shape than "the far side is silicon." It even hands me the next lever: the multiplies work when the chip is told "run one task," so the move is to run each task as *one task* and let the pointer, not the task counter, do the walking. That's the next thing I flash. The island got bigger while I was measuring it.

## The door led to one room

Running each task as its own single-task kick — the lever the pointer chain had handed me — did what it promised and no more. The layers past conv0 came awake: they engaged their units, pulled their own input over the bus, even read the *real* output the previous layer had left in memory, the varied bytes and all. And then multiplied them by nothing. The chain now walked the whole graph, every layer reading the right data, and every layer after the first writing a flat zero. Advancing was solved. Computing was not.

I nearly filed that as "the accumulator is empty in multi-task mode" and moved on, except the number I was reading it from was a lie. My readback had been dumping the output of the *last* task in the job — the one that, in a stalled chain, never runs — so of course it read empty, every time, for every experiment I'd run for weeks. When I fixed it to dump every task's own output, the picture inverted: conv0 wasn't the fragile thing that computed "sometimes," it computed a full, real feature map in *every* mode I had. I'd been reading the wrong slot and calling conv0's health a mystery. conv0 is fine. It's everything after it that's empty — and now I could finally see exactly that, per layer, instead of inferring it from a buffer that never ran.

## It was the first task all along

So I asked the one question that separates every theory I had left: is it the *layer*, or is it the *position*? I ran conv0 a second time — the same command stream, the same camera image, the same everything — but as a follow-on kick instead of the first task after the chip wakes. It wrote sixty-three bytes where the first run had written twenty-five thousand. Same bytes in, nothing out, and the only thing I'd changed was that it wasn't first anymore. (It even fooled me for a minute: the output buffer still read full, until the write counter showed those were the *first* run's bytes sitting there stale, never overwritten.) That's the whole wall in one measurement: not the depthwise, not the pointwise, not the data, not the addresses. The multiply array arms for exactly one task per wake — the first — and every task after it, conv0 included, rides a dead accumulator.

With that pinned, I did the thing I'd been circling for a month: read the working sibling's open driver end to end, next to mine, but only the path that starts task number two. Every register write matches — the pointer arming, the mode bits, the interrupt mask, the task-control word, all of it, value for value. There is exactly one difference in the whole per-task sequence: the sibling raises the engine's "go" bit and *leaves it up* through the computation, dropping it only when the task reports done; I raise it and drop it in the same breath at submit, the way our chip's own vendor does. It was a real, specific, only-remaining difference, and it had a clean story — maybe the drop-at-completion is the pulse that re-arms the next task. So I matched the sibling exactly: hold the bit up, complete on the unit's own done-signal, with a hard timeout so a chip that never finished couldn't hang the board.

It didn't move. The second layer stayed as empty with the bit held high as it was with the bit pulsed low. And that spends the last thing I had. The command bytes match the working chip, the whole register sequence matches, the completion handshake matches, and now the one timing difference matches too — and the layer after the first still does no multiplies. The chip that computes every layer and the chip that computes only the first are byte-for-byte identical in every field the software can write. So the switch that arms the multiply array for the first task and only the first is not a register at all: it's a state inside the sequencer that a fresh wake sets and the first task spends, below the last line of the driver. One reading still nags — a byte counter that climbs a little further than an all-empty chain should — and I'll chase that to the ground before I call it, because I've mistaken a bad measurement for a wall once already this month. But barring that, the road that started with "adapt the working sibling's driver" ends here, cleanly, at a door with silicon on the other side.

## I chased the nag to the ground

The one reading that nagged was a byte counter climbing a little further than an all-empty chain had any right to — the sort of loose thread I'd mistaken for a wall once already, so I refused to call anything until I'd pulled it. The clean way to pull it was to stop trusting the buffer and stop trusting the counter both: I zeroed every output buffer before the run, so nothing I read afterward could be a leftover from a previous pass, and then I read each task's own buffer back, one at a time. conv0 wrote a real, varied feature map into its freshly-cleared space. Every task after it came back empty, or pinned flat to the zero-point, every single dump. And the climbing counter turned out to be exactly what a climbing counter usually is — a running total that never resets between tasks, a dirty odometer, not new work happening somewhere I wasn't looking. So the nag closes the way the honest ones do: it was a bad reading, not a wall. Only the first task computes. Now with the stale-data trap sprung shut, I could say it without a caveat.

## Then I read every last write

Which left me sitting on a claim I hadn't actually earned. "Every register the software writes matches the working stack" — but I'd only ever matched the *first submit's* writes, the burst that starts one job. A whole network isn't one burst. The vendor's driver touches the engine on every interrupt, at every task boundary, when it resets, when it wakes the chip from sleep. I had never once listed *all* of it, both drivers side by side, across a full inference — I'd matched the opening move and assumed the rest of the game.

So I did the slow enumeration: every place either driver writes an engine register, in every function, start to finish. And one idea tempted me the whole way through. There's a register the vendor writes that I always leave at zero — a "task base address," the sort of thing a sequencer might read to find where task two lives. For a day I was sure that was it: the address the vendor's hardware walks and mine never gets. Then I pulled my own capture of a real two-task vendor run and read that register in it. Zero. The vendor steps from task one to task two with the same zero I write. Even the one field I'd hoped was the seam holds the identical nothing on both stacks.

The enumeration finished the way the audit before it did, only complete this time: across a whole inference there is not one engine register the vendor writes that I don't. The values match, the registers match, and the only differences run the wrong way — places where *I* write more than the vendor, not less. Which means the thing that separates the chip that computes every layer from the chip that computes only the first is not a write at all. It's *shape*: the vendor hands the hardware one submission that says "run all N tasks," and the sequencer walks them itself; I hand it N submissions and walk them by hand. Same writes, different grammar.

A static read can prove the writes match but it can't watch them *happen*, and only the happening can catch a difference of order or count. So I built the last instrument this stretch needs: a switch in each driver that logs every engine write, in sequence, with its value and its caller, for one whole inference — the vendor's and mine emitting the same format against the same absolute addresses, so the two logs line up write for write. The next flash produces both, and a short script prints anything the vendor does that mine doesn't, or does in a different order. If it prints nothing — and the static read says it will — then the search leaves the register file for good, and turns to the only thing left standing: the one-submit-many-tasks grammar, and whether the command bytes themselves can be taught to chain the way the sibling chip's do. That's the road I'm on now, and for once I built the map before I drove it.

## Kiln: compromise, or stepping stone

A month of the open driver ends at a boundary I can name but not cross — the sequencer arms the multiply array for the first task of a job and no other, and the difference between the chip that computes every layer and the one that computes only the first is a state below the last register I can write. The vendor's stack doesn't have that problem. Its `rknpu` driver and its closed `librkllmrt` run whole networks, today, on the 6.1 BSP kernel. So there was an obvious, slightly uncomfortable move I'd been putting off: stop trying to *understand* the NPU and just *use* it — take the vendor stack and drag it onto a mainline kernel. I called that Kiln, and the whole time I built it I couldn't decide whether it was a retreat or a bridge.

Kiln is deliberately not the open dream. It fetches the GPL vendor `rknpu` driver — v0.9.8, the version `librkllmrt` expects — ports it from the 6.1 BSP to mainline 7.x with a patch's worth of API shims (the `drm_driver` fields that moved, `hrtimer_setup`, the `iommu_map` gfp argument, the dozen small drifts six years of kernel accumulate), and drives it with Rockchip's closed runtime. Nothing here is reverse-engineered. The matmul I don't understand at all; I hand the model to a blob and the blob talks to the driver. Where rocket was a month of *knowing*, Kiln is an afternoon of *wrapping* — and then a week of the wrapping not working, which is its own story.

Because the first thing Kiln did on mainline was fail in a way I recognized. The driver loaded, `librkllmrt` loaded the model, the runtime-and-driver version-lock passed on the board — and every NPU job timed out with `task_counter = 0`, `raw status 0x30000000`, the DPU-done bits never set. That is the rocket wall's exact face: engaged, configured, computing nothing. For a bad day I thought I'd carried the silicon wall across to the vendor stack too — that the mainline port had somehow inherited the thing below the registers.

It hadn't. This time the wall *was* a register. The RK3576 NPU is one device with two IOMMUs, one per core. Mainline's `rockchip-iommu` manages a single primary iommu per device — `dev_iommu_priv_get` returns one — so with two `iommus` in the device tree the second is silently orphaned: never attached, never enabled, paging off, its page-directory register a flat zero. Core 0's job points the command processor at a high IOVA, the orphaned MMU doesn't translate it, the address is taken as raw physical, the fetch lands on nothing, and the sequencer runs a task worth of nothing. No fault — with paging off there is no translation to fault. `task_counter = 0`.

I found it the way rocket taught me to: by dumping the state the failing job runs against, mid-run, instead of theorising. The MMU status register read `0x18` on one core — paging bit clear — and `0x19` on the other, paging on, a real page-directory base. One MMU enabled, one dark. So the driver learns the page-directory base from the bank the kernel *did* light up and writes it into all four banks itself — DTE, zap the TLB, unmask the fault, enable paging — and zaps every core's TLB before each job so the orphan can't serve a stale translation. Four banks reading `0x19`, and the matmul ran.

It works. Qwen2.5-1.5B, w4a16, on the RK3576 NPU, on a mainline 7.1 kernel: about nine tokens a second of decode, three hundred milliseconds to first token, coherent English coming back. After a month of an open driver that computes exactly one layer, watching a closed one compute a whole transformer — twenty-eight of rocket's layers' worth of matmul per token, thousands of times over — is a strange feeling. It's the result I wanted from the other project, arriving through the door I'd refused to use.

And it costs what I was afraid it costs. The runtime is a blob I can't read, version-locked to the exact toolkit that converted the model — a `librkllmrt` one release too new and the model won't load. The DDR init is still a Rockchip binary even under a mainline SPL; that floor doesn't open for this chip. And I understand the NPU no better than I did before Kiln — less, arguably, because now there's a working thing to hide behind. rocket was trying to *earn* the answer; Kiln buys it. The parts of Kiln I can be proud of are the boring ones: the whole thing is a fetched GPL driver plus one patch plus a device-tree overlay, no kernel fork, so it installs on a stock Armbian kernel with DKMS and a `.dtbo`. It's a real thing someone can run today. It's just not a thing that taught me anything about silicon.

And there's a control experiment worth running. If the driver fix — light every MMU bank, keep the TLB clean — is real and not matmul-specific, then a *convolution* should run through the same NPU just as well: same driver, a different runtime, RKNN instead of RKLLM. So MobileNet became the CNN standing next to the transformer — and, not incidentally, the exact op rocket spent a month failing to compute in the open. It fought me for an evening, but a floor up from the silicon, not in it: `librknnrt` threw an out-of-range setting up the input, and it was the same version-lock RKLLM has — a MobileNet converted with toolkit 2.1.0 against a 2.3.0 runtime. Match the two (a stock ONNX MobileNetV2 converted at 2.3.0) and it just runs: the bell test image comes back **`chime, bell, gong`**, top-1, in 6.2 ms — about a hundred and sixty frames a second. So the fix carries. The vendor stack on mainline runs a transformer's matmul and a convnet's convolution on the same silicon rocket couldn't get a single conv out of — which is either the sharpest possible argument that the wall was never the chip, or the sharpest possible reminder of what "borrowing" buys you. Depending on the day, I read it both ways.

So: compromise or stepping stone. Both, and the ratio is the point. Kiln is a compromise in the way that matters most to the other project — it doesn't *know* anything; it wraps a blob. But it's a stepping stone in three concrete ways rocket can use. It proves the chip and the mainline platform are sound: the vendor stack runs whole networks on the exact kernel rocket runs on, which means rocket's wall is neither the silicon nor mainline — it is purely the open driver's dispatch grammar, exactly where the last month left it. It puts a byte-for-byte oracle on the same board instead of the 6.1 BSP. And it ships a working NPU-on-mainline today, which buys the open effort the one thing it is short of, which is time. I set out to build the RK3576 NPU in the open. What I have instead is one layer of it truly open and the rest of it honestly borrowed — and a much sharper sense of which of those two the wall actually cares about.

## The grammar matched, and the wall didn't move

I closed the last chapter certain of one thing: the wall was "purely the open driver's dispatch grammar." I'd earned that sentence — the register audit was complete, the bytes matched, the only gap left was *shape*, one submission that says "run all N tasks" versus my N submissions walked by hand. So I went and built the shape. I pulled a live trace off the vendor's own driver mid-run — every register it touches, in order, with values — and read off exactly how it tells the chip to move from one task to the next: not a task counter at all, but a pointer buried in the tail of each task's own command list, the address of the next task's command list, followed by a sync word and a broadcast "go" that the sequencer follows like a linked list walked in hardware. I built the packer that writes that same tail into every task, threaded a whole graph through it, and wired the submit path to match the vendor's, register for register, down to a task-count field whose bit width I'd had wrong for this chip specifically — a 16-bit field where the header I was coding against described a 12-bit one from the chip's older sibling, silently mis-decoding the exact control bits that arm the sequencer.

And it worked, in the sense that matters for *this* question. The task-status counter climbed — one, then two, then all the way to six on a six-task graph, a number that had sat frozen at one for a month. All four compute units engaged on every task, not just the first. The DMA counters were clean. The done bit fired, clean, on schedule. Every single thing "the dispatch grammar was wrong" predicted would fix, fixed. And every task after the first still wrote a flat zero. I had built, byte for byte, register for register, the vendor's exact way of telling the chip to walk a graph — and the chip walked it, and computed nothing while walking. The sentence I'd closed the last chapter on was wrong, and this time I had the counter that proved it wrong instead of a hunch.

## Native iteration, same silence

The one thing left that could still be blamed on my own driver was my own driver's presence — the polling, the register reads I do mid-run to watch the chip work, any of which might be perturbing the very thing I was trying to observe. So I built the version with none of that: submit once, touch nothing until the final done bit, let the sequencer iterate the whole graph with zero software in the loop during the run. If some driver-side interference was quietly re-arming the compute path between tasks — a side effect of a register read I didn't know mattered — taking every read away should show it.

It didn't show anything different. Byte-identical result to the driven case, task for task. That retires the last version of "it's something *I'm* doing mid-run" I had left to try. The sequencer, entirely on its own, walks a graph and multiplies nothing past the first stop.

## The escape hatch

If the chain itself was somehow poisoned — some state a *following* task inherits from being a follow-on at all, regardless of how it's told to advance — then the fix was to stop chaining. Don't submit a graph. Submit every layer as its own job, independent, no pointer, no task counter, nothing connecting one to the next except that the second one's input happens to be the first one's real output, sitting in memory where I put it. If the poison is in the chaining mechanism, an unchained submit should be clean.

I ran it that way for two whole inferences, every layer its own job, and read every output buffer back after pre-zeroing it, so nothing I saw could be a previous run's leftovers. Two lines out of three hundred and sixty-one came back real. Both of them were the *first* op of an inference — the one right after the chip woke from being idle. Every other op, in both runs, wrote nothing at all — not even the zero-point a chained layer at least manages, genuinely nothing, as if the job had never touched the buffer. Including the second op of the second inference, which read the first op's actual, verified-correct output as its own input and still produced silence. I'd spent weeks asking whether I was chaining tasks the right way. The chip answered a different question: it doesn't matter whether I chain them at all. Only the first job after a wake computes, chained or not, and the *wake* — not the graph, not the pointer, not the task counter — is the thing that's scarce.

## One kernel, two drivers

Every claim I'd been making about "the vendor does X, mine doesn't" up to this point was a claim across two different kernels, two different builds, two different sessions on the board — inferred by reading two drivers' source side by side, not measured on the same machine at the same moment. That's a gap I'd been living with for a month because closing it looked like a lot of plumbing for not much payoff. Eventually the payoff got big enough to be worth it: I built one mainline kernel that can boot *either* driver — the vendor's or the open one — off two device-tree variants selected at boot, on the same board, same firmware, same everything except which driver claims the NPU. Every "the vendor writes this, rocket doesn't" sentence turned, from that point on, into two traces on one kernel set-diffed against each other, not two readings of two different source trees taken on faith that nothing else had drifted.

It bought back a category of doubt I hadn't realized I was still carrying. The clock and power-domain housekeeping around a job, every register either driver touches in the NPU block or its IOMMU across a full inference, the exact order of a submit — all of it, identical, on one board, one boot, one measurement, not an inference. It's a slower way to ask a question I'd mostly already answered, but this time the answer doesn't depend on trusting that two separate builds were configured the same way.

## A fix that had never run

The one-kernel rig turned up something the register audit alone never would have: a fix I'd already shipped had never actually run. Weeks earlier I'd suspected a stale IOMMU translation — a reused address serving a previous buffer's mapping — and "fixed" it by calling the generic kernel API that's supposed to flush every stale entry before a job starts. It compiled, it didn't error, I moved on.

What I hadn't done was watch it fire. When I finally traced it, on the same-kernel rig, the call landed and did *nothing* — mainline's driver for this chip's IOMMU family doesn't implement the callback that generic flush is supposed to call, so the kernel core skips it as a matter of routine, silently, exactly the way a missing optional callback is supposed to be skipped. My fix had been a no-op since the day I wrote it, and I'd been carrying "TLB staleness: ruled out" on the strength of a function call I'd never confirmed actually did anything. I wrote the real one — a raw register write to the chip's own cache-zap command, the same operation the generic API was supposed to trigger — and traced it firing, on both banks, every submit. The wall didn't move a millimetre. Stale TLB entries really were never the cause. But I'd been *right* for the wrong reason for weeks, and the only way I found that out was by refusing to count a fix as real until I'd watched it happen on the wire.

## The buffer really is empty

One doubt kept nagging under all of this: every "the output is empty" reading was a CPU read of memory the NPU had supposedly written, and CPU reads go through a cache. If that cache were serving a stale line instead of the truth, "empty" could be a lie my own instrument was telling me, the same way a dirty odometer once was. So I filled an output buffer with a sentinel pattern before a run, forced an explicit cache invalidate immediately before reading it back — bypassing whatever a routine driver-level sync might or might not have actually done — and compared. If the DPU had written real data and the ordinary read path just hadn't invalidated properly, the forced read would show something different from the routine one.

It didn't. Sentinel in, sentinel out, forced read matching the routine read exactly, on every buffer, every time. The buffer really is never written. That was the last way my own measuring stick could have been the thing that was broken instead of the chip, and it wasn't.

## Asking someone who hadn't read any of this

By the time I'd run all of the above I was too close to my own story to fully trust my own read of it, so I did something a little unusual: I asked for a from-scratch audit of the whole stack — my driver, the vendor's, the userspace command builder — done cold, with none of my own notes open, on purpose, to see whether a reader who'd never seen a month of dead ends would land somewhere I hadn't.

It came back with two candidates, and both of them were instructive in exactly the way I'd hoped and slightly dreaded. The first was the idea that the vendor might use a hardware descriptor-array mechanism I'd never actually tried in combination with the right task count — a real gap in what I'd tested, argued cleanly from the source. It was also something I'd already written down as false, from my own capture of the vendor's real submit: the address field that mechanism depends on reads zero in the vendor's own trace, at every task count I'd captured. A cold read had walked, independently, straight back onto ground I'd already covered and already closed — which is either a coincidence or a sign that the ground really is that well covered; I choose to read it as the second. The other candidate collapsed to my own furthest conclusion, rediscovered rather than assumed: that the compute engine's arm is a per-power-session resource, not a per-task one. Nothing survived the pass that I hadn't already either tried or already refuted. It's the least dramatic possible outcome of asking someone else to check your work, and I've come to think that's exactly what a genuinely finished negative result should feel like.

## Where I'm leaving it

Every theory that fits in a register, a config bit, a buffer, a cache line, or a dispatch grammar has been tried and has failed to move the outcome, across two structurally different investigations and a third that checked both without reading either first. Dispatch mechanism — sequential kicks, native hardware iteration, the vendor's own linked-list grammar rebuilt bit for bit, even fully independent jobs with no chaining relationship at all. Registers — every write either driver makes, matched value for value, across a whole inference. Config geometry, forced whole-cloth from a known-good capture. The on-chip staging buffer, audited before and after a chained task and shown to hold the real, correct data anyway. Cache coherency and stale TLB entries, both chased to ground and both cleared with a fix I could watch fire on the wire. Clock, power domain, firmware — the same secure boot stack either way. None of it is the seam.

What's left is a shape, not a guess: a compute-accumulate stage that arms itself once per power-on and never again, independent of how many tasks I ask for or how I ask for them — a state inside the sequencer, underneath the last register this driver, or the vendor's, will show me. That's not a wall a register trace crosses. It needs the chip's own documentation of that sequencing, or a way to watch the microcode itself, and I have neither. So I'm parking it here, in writing, with the full ledger of what was tried and what it ruled out — not because I've stopped caring whether MobileNet finishes running on the open driver, but because the next experiment I could run is one I've already run under a different name. The honest thing to write down is not "I couldn't fix it." It's "I can tell you exactly which floor the fix isn't on, and precisely how I know."

The whole falsification ledger — every dimension, every test, every result — is in the [rocket bring-up repo](https://github.com/gahingwoo/linux-rk3576-npu/blob/main/CHAINED-CMAC-STOPPING-POINT.md). Kiln keeps running whole networks in the meantime, on the vendor's terms, which is still the honest trade I described it as three chapters ago. If new evidence ever moves this — vendor documentation of the sequencer, or a look inside the microcode I don't have today — that page is where I'll say so.
