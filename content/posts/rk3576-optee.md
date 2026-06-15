---
title: "Porting OP-TEE to the RK3576"
date: 2026-06-12
tags: ["op-tee", "tee", "security", "rockchip", "rk3576", "firmware", "upstream"]
description: "Bringing up a secure world on the RK3576 — a silent console, a different TRNG, an OTP key you can only write once, and a review that made all of it better."
showToc: true
draft: false
---

OP-TEE is the secure-world OS that runs at S-EL1, between TF-A and Linux. Getting it up
on a new SoC is mostly plumbing — memory map, console, crypto, entropy — except every
piece of that plumbing has a way to go silently wrong, and "silently" is the operative
word here, because the first problem was literally silence.

Target: Radxa Rock 4D (RK3576), firmware on SPI, kernel + an xtest initramfs off SD.
The port went up as OP-TEE PR #7821.

## The memory map, first

The boring part that has to be right or nothing else matters:

```
0x40000000  TF-A BL31 (TZRAM)
0x40800000  U-Boot
0x70000000  OP-TEE TZDRAM   — 32 MiB, secure, DDR firewall + no-map
0x72000000  OP-TEE shared memory — 4 MiB, non-secure
```

`platform_secure_ddr_region()` programs the SYS_SGRF firewall so the secure DRAM window
is actually enforced by hardware, not just politely avoided. RK3576 is 8 cores —
4×A72 + 4×A53 — GICv2, and once the regions and GIC addresses were right it came up on
all eight.

## Then: total silence

First boot, OP-TEE produced *zero* output. Not a crash — just nothing. On most platforms
OP-TEE finds its console from a device tree pointer that TF-A hands to BL32. On RK3576,
TF-A doesn't pass one ("No non-secure external DT" in the log), so the DT-based console
probe never runs, and you get a secure world that boots blind.

Fix is `CFG_EARLY_CONSOLE=y` so it brings up UART0 directly. Small catch that cost some
time: `conf.mk` sets `CFG_EARLY_CONSOLE ?= n` *globally*, and a `?= y` inside the
platform block is a no-op because the variable's already set. You need a forced
override, not a default. (This exact point came back in review — more below.)

UART0 itself was a second snag: TF-A uses UART0 (`0x2ad40000`) as its console, OP-TEE
defaulted to UART2. They have to agree or you're back to staring at a dead port.

## Entropy: the RK3576 has a different TRNG

By default OP-TEE will fall back to a software PRNG (Fortuna) and print:

```
WARNING: This OP-TEE configuration might be insecure!
```

To make that warning go away honestly, you need real hardware entropy. RK3576 uses the
RKRNG IP at `0x2a440000` — *not* RK3588's TRNG_V1, different register layout entirely.
I wrote a small `hw_get_random_bytes()` driver for it so `CFG_WITH_SOFTWARE_PRNG=n`
works cleanly.

Two ordering gotchas, because entropy gets asked for *early*:

1. `hw_get_random_bytes()` has to lazily map the RKRNG block on first call — the early
   MMU map from `entry_a64.S` is up before any initcall, so that's safe.
2. The stack-canary hook `plat_get_random_stack_canaries()` runs *before* `driver_init()`,
   so it has to read the RKRNG directly rather than going through the driver framework.

(In one hardware run the TRNG_S block didn't respond and we rode the SW-PRNG fallback —
so the fallback path isn't theoretical, it's load-bearing. A reviewer flagged checking
whether the TRNG clock is even enabled via SCMI, which is the right next thread to pull.)

## The OTP key you can only write once

The Hardware Unique Key (HUK) is derived from a one-time-programmable fuse. RK3576's HUK
lives at OTP_S index `0x80` (bytes 512–527) — RK3588 uses `0x104`, so this is a real
per-SoC value, not a copy-paste. On an unprogrammed board the slot reads all zeros, and
OP-TEE falls back to an **ephemeral** HUK: a fresh random key every boot.

That fallback is convenient and also a footgun, which a reviewer (QSchulz) caught
immediately: if someone flips on persistent OTP storage before the HUK index is
*confirmed* against the RK3576 docs, they burn a permanent fuse at possibly the wrong
row — irreversible. So provisioning is gated behind `CFG_RK3576_PERSIST_HUK=n` by
default, off, with the warning stated plainly. You opt into the one-way door
deliberately or not at all.

Same shape for the secure-boot PTA (RSA-2048): the public-key hash goes to OTP_S words
`0x184`–`0x187`, and `CFG_RK_SECURE_BOOT_SIMULATION=y` by default so you can exercise
the whole path without fusing anything. Flip it off only when you genuinely mean
"permanently, on this board, forever." Getting the secure-boot code to cope also meant
tearing out a `static_assert(size == 8)` and making the hash handling variable-length,
since RK3576 only has the RSA-2048 status fuse, not RSA-4096.

(The OTP layout analysis — HUK at 0x80, RSA hash at 0x184 — came from
[the-gabe](https://github.com/the-gabe), credited on those patches. Worth saying out
loud: a lot of bring-up is standing on someone else's careful reading.)

## What review actually changed

`xtest` on hardware: **113 tests, 1 failure** — and the one failure was a missing
initramfs config option (`CONFIG_TEE_SUPP_PLUGIN`), not a platform bug. So the secure
world genuinely works: TAs load, crypto runs, the lot.

But the more interesting output of this port wasn't the code, it was the review. Things
the maintainers pushed on that made it better:

- `$(call force, …)` vs `?=` for the early console — *why* does your platform need to
  force it? (Answer: because TF-A gives BL32 no DT. That belongs in the commit message,
  not just the makefile.)
- the ephemeral-HUK footgun → keep OTP off by default, document the irreversibility, and
  consider splitting platform-support and OTP into separate PRs so the dangerous part
  gets its own scrutiny.
- "did you actually run xtest, or just reach a U-Boot prompt?" — the difference between
  *boots* and *works*, which (if you've read my NPU post) is a drum I will apparently
  never stop banging.

None of those were bugs in the usual sense. They were the difference between "compiles
on my board" and "safe to put in front of strangers' boards." That gap is the whole job.
The patch that merges is the one where you've already answered the question the reviewer
was about to ask.
