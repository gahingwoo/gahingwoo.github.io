---
title: Ga Hing Woo (Jiaxing Hu)
og_image: /imgs/og-banner.png
---

Hi — I'm Ga Hing Woo. I'm finishing high school and about to start university, but
most of the work I actually care about already happens upstream. I live in the
low-level guts of ARM and RISC-V platforms — firmware, TEEs, embedded Linux, and
silicon bring-up — across Cortex-A, Cortex-M, and RISC-V. Lately that's meant living
inside the Rockchip RK3576.

I like the layer where there's no app, no framework, sometimes no documentation — just
a board, a serial console, and a peripheral that refuses to cooperate. Most of what I
do is the same loop: form a theory, flash it, watch what the hardware *actually* does,
and let it tell me I was wrong. I usually am, for a while. That's the fun part.

So far that loop has taken me across most of the RK3576 boot chain and back:

- **TF-A** — upstreamed a fix to Trusted Firmware-A, reviewed by engineers from
  STMicroelectronics, Arm, and Rockchip. (My first upstream patch to a security
  project.)
- **OP-TEE** — wrote the RK3576 secure-world platform port: memory map, hardware TRNG,
  OTP-derived keys, secure boot. The base platform support is **merged into mainline
  OP-TEE**; the OTP key-derivation follow-up is still in review.
- **EDK2 / UEFI** — a real UEFI firmware for the board, which meant teaching it to drive
  HDMI, USB, and eMMC, each of which broke in its own special way.
- **U-Boot & Linux** — device trees, board bring-up, and the small fixes that turn
  "it boots" into "it actually works."
- **NPU, both stacks.** On the vendor runtime (RKNPU/RKLLM) I got real LLMs and vision
  running on a mainline kernel — Llama-3.2-1B at ~13 tok/s, Qwen2.5-1.5B at ~9,
  MobileNet at ~169 fps. On the fully open stack (mainline `rocket` driver) I
  reverse-engineered the undocumented compute registers, got a single int8 convolution
  byte-exact against a CPU reference, then falsified my way down to exactly which
  fixed-function hardware block below the driver is stalling chained layers —
  cross-confirmed on RK3568 and RK3588, not just RK3576. Written up as
  [a preprint](https://doi.org/10.5281/zenodo.21348017).

I've also taken the isolation half of this work across ISAs, on the RP2350:
SWD-verified TrustZone-M on its Cortex-M33 cores (proven by a caught SecureFault) and
a sibling RISC-V PMP example on the Hazard3 cores.

I also build tools when the existing ones annoy me — a device-tree consistency checker
for SoCs, and a cross-platform GUI for flashing Rockchip firmware.

I write most of this up on the [blog](/posts/) — the wrong turns included, because
that's where the actual story is. If any of it is useful to you, or you're poking at
the same hardware, I'd genuinely like to hear from you.

## Things I've built

[kiln](https://github.com/gahingwoo/kiln) ·
[edk2-rk3576](https://github.com/gahingwoo/edk2-rk3576) ·
[bl32-rk3576](https://github.com/gahingwoo/bl32-rk3576) ·
[linux-rk3576-npu](https://github.com/gahingwoo/linux-rk3576-npu) ·
[rp2350-tz-tee](https://github.com/gahingwoo/rp2350-tz-tee) ·
[SoC-Consistency](https://github.com/gahingwoo/SoC-Consistency) ·
[RKDevelopTool-GUI](https://github.com/gahingwoo/RKDevelopTool-GUI)

## Upstream & publications

[OP-TEE PR #7821](https://github.com/OP-TEE/optee_os/pull/7821) ·
[OP-TEE PR #7841](https://github.com/OP-TEE/optee_os/pull/7841) ·
[TF-A Gerrit #51089](https://review.trustedfirmware.org/c/TF-A/trusted-firmware-a/+/51089) ·
[Preprint (DOI)](https://doi.org/10.5281/zenodo.21348017) ·
[ORCID](https://orcid.org/0009-0002-0840-8951)

## Say hi

[huhuvmb88@outlook.com](mailto:huhuvmb88@outlook.com) ·
[github.com/gahingwoo](https://github.com/gahingwoo)
