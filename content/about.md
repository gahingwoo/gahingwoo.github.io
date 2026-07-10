---
title: "About"
url: "/about/"
showToc: false
hidemeta: true
disableShare: true
ShowReadingTime: false
---

# Ga Hing Woo (Jiaxing Hu)

Hi — I'm Ga Hing Woo. I'm finishing high school and about to start university, and in
the meantime I spend an unreasonable amount of my free time at the very bottom of the
software stack: firmware, embedded Linux, and bringing up ARM SoCs that don't quite
work yet. Lately that's meant living inside the Rockchip RK3576.

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
- **NPU** — bringing up the RK3576's neural accelerator on the open-source `rocket`
  driver. This one's an ongoing fight and probably my favourite.

I also build tools when the existing ones annoy me — a device-tree consistency checker
for SoCs, and a cross-platform GUI for flashing Rockchip firmware.

I write most of this up on the [blog](/posts/) — the wrong turns included, because
that's where the actual story is. If any of it is useful to you, or you're poking at
the same hardware, I'd genuinely like to hear from you.

## Things I've built

[edk2-rk3576](https://github.com/gahingwoo/edk2-rk3576) ·
[bl32-rk3576](https://github.com/gahingwoo/bl32-rk3576) ·
[linux-rk3576-npu](https://github.com/gahingwoo/linux-rk3576-npu) ·
[SoC-Consistency](https://github.com/gahingwoo/SoC-Consistency) ·
[RKDevelopTool-GUI](https://github.com/gahingwoo/RKDevelopTool-GUI)

## Upstream

[OP-TEE PR #7821](https://github.com/OP-TEE/optee_os/pull/7821) ·
[OP-TEE PR #7841](https://github.com/OP-TEE/optee_os/pull/7841) ·
[TF-A Gerrit #51089](https://review.trustedfirmware.org/c/TF-A/trusted-firmware-a/+/51089)

## Say hi

[huhuvmb88@outlook.com](mailto:huhuvmb88@outlook.com) ·
[github.com/gahingwoo](https://github.com/gahingwoo)
