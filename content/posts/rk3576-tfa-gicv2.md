---
title: "A One-Line TF-A Fix, and the Review That Came With It"
date: 2026-05-24
tags: ["tf-a", "trusted-firmware-a", "rockchip", "rk3576", "upstream", "firmware"]
description: "Deleting one redundant line from Trusted Firmware-A's RK3576 platform — and what upstreaming even a trivial patch actually looks like."
showToc: true
draft: false
---

This is the smallest patch I've ever upstreamed: it *removes* one line. Net diff is
negative. But it's also the first thing I sent to Trusted Firmware-A, and it got read
by engineers from ST, Google, and Rockchip before it landed. So it's a decent little
story about what upstreaming actually feels like, even when the change is nearly
nothing.

## The line I deleted

In `plat/rockchip/rk3576/platform.mk`, one line:

```diff
 ENABLE_PLAT_COMPAT		:=	0
 MULTI_CONSOLE_API		:=	1
 CTX_INCLUDE_EL2_REGS		:=	0
-GICV2_G0_FOR_EL3		:=	1
 CTX_INCLUDE_AARCH32_REGS	:=	0
```

That's the whole patch. `GICV2_G0_FOR_EL3` decides whether GICv2 Group 0 interrupts
are routed to EL3. The RK3576 platform was hardcoding it to `1`, and that override is
both redundant and wrong:

- **Redundant** — every other Rockchip platform leaves it alone, and the default in
  `make_helpers/defaults.mk` is already `0`. So RK3576 was the odd one out for no
  reason.
- **Wrong** — forcing Group 0 to EL3 isn't what these platforms want. It only ever
  looked harmless because the board is always built with `SPD=opteed` and nobody had
  hit the consequences. Carrying a non-default value the rest of the tree doesn't carry
  is exactly the kind of thing that bites a future configuration nobody's testing yet.

So: delete the line, let the default stand.

```
fix(rk3576): drop redundant GICV2_G0_FOR_EL3 override
```

Tested on a Radxa Rock 4D (RK3576, 12 GiB LPDDR5) with `SPD=opteed` — boots through
BL31 into OP-TEE and on to Linux, same as before.

## Why one deleted line is worth a post

Because "it builds and boots" is not why a patch gets merged. The reviewers don't have
my board. What they have is the diff, and they're going to ask: *is removing this safe
for every configuration, not just yours?* That's a different and harder question than
"does it work for me."

So I had to actually justify it: the default is 0, here's the line in `defaults.mk`;
no sibling platform sets it; the override only survived because one specific build
config happened to mask it. Once that case was airtight, the patch was obvious — but I
had to make the case, not just assert it.

That's the whole lesson, and it's the one that carried into every harder RK3576 patch I
sent afterward (OP-TEE, the NPU work): **upstream review is about defending every line
you touch to people who can't see your hardware.** A one-line delete and a
thousand-line driver get the same question. The delete is just where I learned to
answer it.

It also means the right first contribution to a big project isn't a feature. It's
finding the small, defensible, obviously-correct thing and shipping it cleanly. This was
mine.
