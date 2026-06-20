---
title: "RK3576 UEFI: Teaching EDK2 to Drive HDMI, USB, and eMMC"
date: 2026-06-20
tags: ["edk2", "uefi", "rockchip", "rk3576", "firmware", "hdmi", "usb", "emmc"]
description: "Replacing U-Boot proper with EDK2 on the RK3576 — and the three peripherals that each had their own way of refusing to work."
showToc: true
draft: false
---

The goal was a real UEFI firmware on the RK3576: boot the standard chain but swap
U-Boot proper for EDK2, so the board comes up to a proper UEFI environment (think
ESXi-on-Arm, Windows, EBBR distros). The boot chain:

```
BootROM → U-Boot SPL (idbloader) → TF-A BL31 → EDK2 UEFI (BL33 @ 0x40800000)
```

SPL loads a FIT image — from SPI `0x60000` or SD sector 16384 — containing BL31 and
EDK2. The unbreakable rule: **U-Boot proper must never end up in that FIT.** Half of
the early bugs were exactly that leaking back in (u-boot.bin in the FIT, raw SPL with no
RKNS header, FIT entries pointing at BL31 load addresses that didn't match the ELF's
actual segments). Once the packaging was honest, the fun started: three peripherals,
three completely different failure personalities.

Boards: Radxa ROCK 4D (SPI boot) and ArmSoM CM5-IO (SD boot).

## HDMI: where reading a register breaks the picture

VOP2 is Rockchip's display controller, and the RK3576's is *almost* the RK3588's, which
is the worst kind of almost. The differences that cost real time:

- **Pixel clock divider is ÷2, not ÷4.** RK3588 uses ÷4; RK3576 halves the VOP2 DCLK
  core rate (`VPixclk >> 1`). Wrong divider, no usable signal.
- **`IF_CTRL` pin polarity** lives in bits [5:4]; for +H/+V sync you write `0x80000033`.
- **HPD routing through GPIO4 PC0–PC3, all function 9** (CEC + HPD + SCL + SDA). PC0
  specifically *must* be fn9 or the IOC won't route hot-plug detect.
- **`IOC_MISC_CON0` CLR bit must stay latched** — it's not write-1-to-clear like you'd
  assume. Clear it and you freeze the hot-plug detector solid.

And then the two that genuinely felt like the hardware was messing with me:

- **`PRE_DITHER_DOWN_EN = 1` kills the signal** in our incremental-write VOP2 init —
  even though mainline sets that exact bit. The difference is mainline computes the whole
  register and writes it once; we were touching registers live, and enabling pre-dither
  mid-sequence drops the output. Leave it 0 unless you refactor to compute-then-write.
- **Reading VOP2 registers after enable kills the picture.** I added register dumps to
  debug a blending issue and the dumps *themselves* took down HDMI. On this block, reads
  are not side-effect-free. That one cost an afternoon of chasing a "bug" that was my own
  diagnostic.

If you skim my edk2-rk3576 git log around the HDMI work it is a graveyard of
`fix:` immediately followed by `Revert "fix:"`. That's not noise — that's what bring-up
on an undocumented display path actually looks like. Try, flash, look at the screen,
revert, try the next thing.

### The picture was there the whole time

Here's the part I'm slightly embarrassed by, kept in because it's the actual lesson.

Once I stopped reading registers, the monitor synced and — for a moment when I glanced
at it mid-boot — showed black. Valid timing, valid TMDS, nothing on it. I concluded the
overlay (the block that composites windows onto a video port) must be wrong: RK3576's is
laid out differently from RK3588's — per-window `VP_SEL` registers and a per-VP
`OVL_LAYER_SEL` instead of the RK3588 central pair at 0x604/0x608 — so surely EDK2 was
programming an overlay the chip ignores. I spent an evening "fixing" it against mainline
`rockchip_vop2_reg.c`, flashed, and turned a working picture into a *dead signal*.

Then I pulled the EDK2 firmware volume out of the one image that actually drove a picture
and diffed it against my "fix." The working binary was the **original, unmodified**
overlay. The RK3588-style central `OVL_LAYER_SEL`/`OVL_PORT_SEL` path composites perfectly
well on RK3576; my rework left the window half-routed and dropped sync. The black frame I'd
panicked over was just the boot logo not yet painted at the instant I looked — once BDS
draws the framebuffer, TianoCore is on the glass:

| Radxa ROCK 4D | ArmSoM CM5-IO |
|---|---|
| ![EDK2 UEFI on ROCK 4D via HDMI](/imgs/monitor-4d.png) | ![EDK2 UEFI on CM5-IO via HDMI](/imgs/monitor-cm5io.jpeg) |

The only real HDMI bug was the register dump killing the signal. Everything after that was
me debugging a problem that didn't exist — exactly the failure mode this whole section warns
about. The CM5-IO does have a small horizontal offset (the RK3576 background/pre-scan delay
still uses the RK3588 formula — a genuine one-register fix for another evening), but a
shifted picture beats a week of black screens, and it was one revert away the whole time.

## USB: a hub that won't enumerate

CM5-IO routes both USB-A ports through an onboard 4-port USB3 hub IC hanging off DRD1.
No direct port — everything goes through the hub, so if the hub doesn't enumerate, you
have no USB at all. Two independent DWC3 xHCI bugs, both in EDK2's `XhciDxe`:

**1. SuperSpeed `EvaluateContext` times out.** The RK3576 DWC3 never raises a Command
Completion event for `EvaluateContext` on a SuperSpeed slot, so enumeration hangs waiting
for it. The saving grace: on SS, EP0's max packet size is always 512, which is *already*
the value the Address-Device context was initialised with. The command is a structural
no-op. So: when `MaxPacket0 == 512`, skip it and return success. (512 is unique to SS;
HS/FS/LS EP0 is ≤64, so the check can't misfire.)

**2. Hub `ConfigHubContext` times out after `SetConfig`.** Once the hub's interrupt
endpoint goes active, the controller serialises Configure-Endpoint commands behind
endpoint-transfer processing and deadlocks. Fix is to set the Hub=1 slot-context flag
*before* `SetConfigCmd` activates that endpoint (with a placeholder port count), then
tolerate the later "real values" update failing — the hub's already marked as a hub, so
it keeps working. (Cost: TT routing for full/low-speed devices behind the hub is
approximate, but HS/SS storage and HID — the stuff people actually plug in — are fine.)

After both: `PORTSC` shows the SS and HS hub links trained to U0 at ReadyToBoot.
Devices appear. Ship it.

## eMMC: held in reset the whole time

`SdCardIdentification: Executing Cmd0 fails with Time out`. eMMC never showed up. The
root cause is almost funny:

`EMMC_EMMC_CTRL` bit 2 is `EMMC_RST_N`, and its power-on default is **0** — eMMC held in
hardware reset. On RK3588 boards this is invisible because SPL boots *from* eMMC and
clears the reset on its way through. On RK3576 booting from SD or SPI, nothing ever
touches the eMMC controller, so it sits in reset until UEFI tries to talk to a device
that is, electrically, switched off.

Fix: `MmioOr32(EMMC_EMMC_CTRL, BIT2)` to deassert reset, then a 200 µs stall per the
eMMC spec, before CMD0. Universal — *any* platform that boots from SD/SPI needs it.

That got CMD0 talking, and then HS200/HS400 hung, which opened a whole second saga of
about seven smaller fixes to get a stable 52 MHz High-Speed mode (`ForceHighSpeed`): the
SDHCI base-clock value not propagating to the divisor math, the init CRU running at the
wrong frequency, `CARD_IS_EMMC` only being set on the DLL path, DLL bypass/RXCLK gating
constants lifted from U-Boot's non-DLL path, an RK3576-specific STRBIN delay (`0xa`, not
RK3588's `0x10`)... and the one that was the *actual* CMD0-timeout root cause hiding
under all of it: **`MISC_INTCLK_EN` (the internal-clock enable) gets cleared by
`SW_RST_ALL` and was never re-set.** Mainline's `rk35xx_sdhci_reset()` always restores
it after a reset; we weren't, so the SDHCI internal clock was simply off and *every*
command timed out. Restoring it after reset is what finally made it stick.

The recurring tell across all of it: the Rockchip SDHCI's clock divider bits aren't
functional — the real eMMC clock follows the CRU, and the SDHCI divisor is ignored. Once
you internalise that, half the "impossible" clock numbers explain themselves.

## The pattern

Three peripherals, three different lessons, one shape. HDMI: *your debugging can be the
bug.* USB: *the controller's idea of a no-op isn't the spec's.* eMMC: *the thing was
never powered on, you were talking to a brick.* None of it came from a register manual —
it came from mainline Linux and U-Boot as the reference for *what the working values
are*, then flashing real boards and reading what the silicon did. The screen, the
`PORTSC` bits, and the CMD0 timeout were the only honest witnesses. Everything else was
a theory waiting to be reverted.
