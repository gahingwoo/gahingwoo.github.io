---
title: "rknn-toolkit2 2.3.2 Conversion Runs Natively on arm64 — and the Two Gotchas Nobody Documents"
date: 2026-07-10
tags: ["rknn", "rockchip", "arm64", "aarch64", "npu", "rk3576", "toolchain"]
description: "The folk wisdom says you need an x86 box to convert models for a Rockchip NPU. On rknn-toolkit2 2.3.2 that's stale — the aarch64 wheel builds an onnx into a .rknn end-to-end. Here's the proof, the two traps that'll stop you first, and why the output md5 not matching is completely fine."
showToc: true
draft: false
---

## TL;DR

If you've read that Rockchip's `rknn-toolkit2` model converter "only runs on x86," that
was true once and isn't anymore. On **version 2.3.2** the official **aarch64** wheel
installs, imports, and converts an ONNX model to a `.rknn` end-to-end — I did it on a
plain arm64 Ubuntu 24.04 host (Python 3.12), no x86 anywhere, no cross-machine dance.

The conversion itself is boring, which is the point. What isn't boring is the two things
that stop you before you get there — both undocumented, both a fast dead end if you don't
know them:

1. **`pip install 'setuptools<81'`.** rknn-toolkit2 2.3.2 imports `pkg_resources` at load;
   modern setuptools deleted it, so `from rknn.api import RKNN` blows up before you write a
   line of your own code.
2. **Your output `.rknn` won't match anyone else's md5 — and that's normal.** rknn files
   aren't byte-reproducible. If you "verify" a fresh conversion by diffing checksums against
   a reference, you'll scare yourself for no reason. The real check is elsewhere.

The rest is the walk-through and the reasoning.

## The setup

- aarch64 Ubuntu 24.04, Python 3.12, in a venv
- `rknn-toolkit2` **2.3.2** (the official arm64 wheel), `librknnc` 2.3.2 (@2025-04-03)
- Target SoC: RK3576
- Test model: a one-layer ONNX — a single Conv2d, 3→32, 3×3, stride 2, 224×224 in →
  112×112×32 out. Small on purpose; I want to test the *converter*, not a model.

Why one conv and not a full MobileNet: if the toolchain is broken on arm64, one conv finds
out just as fast as a whole net and the logs are readable. And I turn quantization **off**
for this first pass — `do_quantization=False` — so I'm testing exactly one thing, the
onnx → rknn build path, with no calibration dataset in the way to muddy a failure.

## It converts

The whole script:

```python
from rknn.api import RKNN

rknn = RKNN(verbose=True)
rknn.config(target_platform='rk3576')
print('config done')
print('load_onnx ret:', rknn.load_onnx(model='conv0.onnx'))
print('build ret:',     rknn.build(do_quantization=False))
print('export ret:',    rknn.export_rknn('conv0_arm64.rknn'))
rknn.release()
print('CONVERT OK')
```

And it runs — the closed-source compiler does real work on arm64, not a stub:

```
I rknn-toolkit2 version: 2.3.2
config done
D base_optimize ... done.
D fold_constant ... done.
D fuse_ops ... done.
I RKNN: librknnc version: 2.3.2 (@2025-04-03T08:30:46)
...
D ID  OpType          Target  InputShape                     OutputShape
D 0   InputOperator   CPU     \                              (1,3,224,224)
D 1   Conv            NPU     (1,3,224,224),(32,3,3,3),(32)  (1,32,112,112)
D 2   OutputOperator  CPU     (1,32,112,112)                 \
load_onnx ret: 0
build ret: 0
export ret: 0
CONVERT OK
```

Every stage returns 0, the layer table shows the Conv correctly assigned to the **NPU**
with the right shapes, and a `conv0_arm64.rknn` lands on disk. That's the whole claim:
arm64 converts. The "you need x86" advice you'll find in forum threads predates this wheel.

Now the two things that'll trip you on the way in.

## Gotcha 1: pin setuptools below 81

Fresh venv, install the wheel, first import — and it dies inside `pkg_resources`.

rknn-toolkit2 2.3.2 still imports `pkg_resources` (the legacy setuptools API) at module
load. Setuptools removed `pkg_resources` in the 81 series, so on any recent box the very
first `from rknn.api import RKNN` throws before your code runs. Nothing in the rknn docs
mentions it because the wheel was cut against an older setuptools.

The fix is one line, before or after installing rknn:

```bash
pip install 'setuptools<81'
```

One thing that confuses people: even with the pin in place you'll *still* see

```
UserWarning: pkg_resources is deprecated as an API.
```

every time you import. That's just the deprecation notice from the `<81` versions that
still ship `pkg_resources`. It's **harmless** — the warning means it's working, not
breaking. The failure mode is the import raising, not the warning printing. Don't chase it.

## Gotcha 2: the output md5 won't match, and that's fine

Here's the trap that cost me a double-take. I had a known-good reference `.rknn` for the
same conv, converted earlier. Natural instinct after a fresh conversion: `md5sum` both and
confirm they're identical.

They aren't:

```
38583  conv0_arm64.rknn                (just built, arm64)
37969  conv0_rk3576.rknn               (reference)
6d5a31d6...  conv0_arm64.rknn
5a3a6f1d...  conv0_rk3576.rknn
```

Different size, different md5. That looks like a red flag and it is **not one.** Two
reasons a `.rknn` is not byte-reproducible:

- The container embeds build metadata (compiler config, and effectively build-time state)
  that varies run to run. Even the *same* model built twice on the *same* machine won't
  md5-match.
- My reference was built with different options (it was quantized; this pass wasn't), so of
  course the bytes differ — different graph, different data.

So **md5 comparison proves nothing about a converter** — not equivalence, not correctness,
neither direction. If you're using it as your success check, throw it out. What actually
tells you the conversion is sound:

- **the build return codes** — `load_onnx` / `build` / `export_rknn` all 0;
- **the layer info table** — ops land on the units you expect (Conv → NPU here), input and
  output shapes match your model;
- and for *semantic* correctness — the only check that really counts — **run the `.rknn`
  on the actual NPU and compare against the reference.** I did exactly that; the last section
  is a whole MobileNet converted on arm64 and classifying correctly on the board. That's the
  check md5 was only ever pretending to stand in for.

## Bonus trap: the venv that isn't activated

Not rknn-specific, but it bit me mid-session and it'll bite anyone scripting this, so it's
worth ten seconds. I ran the conversion as a one-liner:

```bash
source ./env/bin/activate && python3 convert.py
# ModuleNotFoundError: No module named 'rknn'
```

The `activate` didn't take — chained into a single non-interactive shell invocation it
doesn't reliably alter the `python3` that then runs, so you get the system interpreter and a
missing module. The robust fix is to skip activation entirely and call the venv's
interpreter by absolute path:

```bash
~/rknn/rknn-convert-env/bin/python3 convert.py
```

Same trick works in Makefiles, systemd units, CI steps — anywhere a login shell isn't
guaranteed.

## The real proof: a whole MobileNet, on the board

The single conv proves the toolchain runs. To prove it produces a *correct, usable* model I
converted a real one — the ONNX MobileNetV2 (`mobilenetv2-12`) from Rockchip's model zoo,
with the vendor's `mean`/`std` preprocessing, `target_platform='rk3576'`, on the same arm64
host.

One surprise before I even touched hardware: my arm64 output came out **7,640,625 bytes —
the same size, to the byte, as the vendor's x86-converted reference.** The md5 still differs
(it always will), but a byte-level `cmp` says only **10,490 of those 7.64M bytes differ —
0.14%.** The other 99.86% is identical. The differing sliver is embedded metadata; the
compiled graph and weights are the same model. That's the md5 gotcha above, quantified: same
model, different checksum, and the whole difference is header.

Then the run — on a Radxa ROCK 4D, **mainline kernel** with the out-of-tree vendor `rknpu`
driver and `librknnrt`, no vendor BSP anywhere:

```
rknn_mobilenet mobilenetv2-12_rk3576_arm64.rknn test.jpg

top-5  (NPU inference 6.2 ms):
  1. [ 494] chime, bell, gong            18.6562
  2. [ 653] milk can                     12.1406
  3. [ 469] caldron, cauldron            11.6016
  ...
[bench] rknn inference: 6.2 ms (162.4 fps)
```

Correct top-1 (the test image is a bell), the same top-5 as the vendor build, ~6 ms, 162 fps.
That's the whole loop closed on arm64: convert the model *and* run it on the NPU, with no x86
in the pipeline at any step.

## Who this saves

If you're standing up an RK3576 / RK3588 workflow and you've been told to keep an x86 box
around *just* to convert models — on 2.3.2 you don't. Install the aarch64 wheel, pin
setuptools under 81, ignore the deprecation warning, ignore the md5 mismatch, and convert on
the same arm64 machine you build everything else on. The whole detour disappears.
