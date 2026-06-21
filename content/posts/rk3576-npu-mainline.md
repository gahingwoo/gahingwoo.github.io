---
title: "Bringing Up the RK3576 NPU on Mainline Linux"
date: 2026-06-15
lastmod: 2026-06-21
tags: ["linux", "rockchip", "npu", "embedded", "rk3576"]
description: "Chasing all-zero NPU output on the RK3576 — the wrong theories, the layouts I got right, and where the open road ends: a bug that lives below the registers, a race I could finally rule out, and the strangers who showed up at the same wall."
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

For two months the engines wouldn't start unless I shouted at them. I'd been ending every layer's
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
down the channels, every time, at a slightly different place. Two months of calling it a dead multiply,
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
sibling at the same wall, one stage back; and to **alchark** and the folks on the Flipper thread for the
introductions and the honesty about what's NDA'd and what isn't. The compute half isn't solved yet — but it's a
much better-lit room with all of you in it.
