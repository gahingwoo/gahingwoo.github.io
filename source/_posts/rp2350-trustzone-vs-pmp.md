---
title: "Same Chip, Two Walls: TrustZone-M vs RISC-V PMP on the RP2350"
slug: rp2350-trustzone-vs-pmp
date: "2026-07-13"
categories:
  - Security & Isolation
og_image: /imgs/og-banner.png
tags:
  - rp2350
  - trustzone
  - risc-v
  - pmp
  - hazard3
  - security
  - firmware
  - embedded
  - cortex-m33
description: The RP2350 ships an Arm Cortex-M33 and a RISC-V Hazard3 on the same die, so I wrote the same isolation demo twice — TrustZone-M with SAU and CMSE veneers, then M-mode/U-mode with PMP and ecall — and ran both on the same board. They produce identical results and feel nothing alike. Here's what the hardware actually told me, including the address Arm hands you that Hazard3 doesn't, and the wall that only one of the two ever hit.
---

## TL;DR

The RP2350 has both an Arm Cortex-M33 pair (TrustZone-M) and a RISC-V Hazard3 pair
(PMP) on one die. I built the same minimal isolation demo on both — a guarded secret, a
call-in service, and a deliberate illegal read — and verified both on the same Pico 2
over SWD. Findings, all measured rather than read off a spec:

- **Same result, different shape.** Both block the illegal read with the secret intact.
  TrustZone partitions the *address map* and the toolchain builds the gate for you; PMP
  filters by *privilege* and you write the gate yourself.
- **Arm tells you where it broke, Hazard3 doesn't.** `SFSR = 0x48` sets `SFARVALID`, so
  the faulting address is there for the taking. Hazard3 leaves `mtval = 0` on a PMP
  access fault. `mcause = 5` is all you get.
- **The same silicon only fought one of them.** The Arm Non-Secure side hit two RP2350
  walls that forced a bare-metal, RAM-resident NS image. The RISC-V U-mode side just ran
  from flash.
- **Hazard3 has a trick TrustZone structurally can't do:** `Xh3pmpm` lets M-mode sandbox
  *itself*, reversibly.
- Neither of them covers the DMA. That's a separate MPU, and it's the RP2350 detail most
  likely to quietly ruin your day.

Code: [rp2350-tz-tee](https://github.com/gahingwoo/rp2350-tz-tee) —
[`minimal-tz`](https://github.com/gahingwoo/rp2350-tz-tee/tree/main/examples/minimal-tz)
(Arm) and
[`minimal-pmp`](https://github.com/gahingwoo/rp2350-tz-tee/tree/main/examples/minimal-pmp)
(RISC-V).

<!-- more -->

<details>
<summary style="cursor:pointer;font-weight:600;">Read the full write-up</summary>

## Why this comparison is worth anything

Most TrustZone-vs-PMP writing compares specifications. That's fine, but specs don't tell
you that Hazard3 won't report a fault address, or that Non-Secure reads of XIP flash come
back as zero on a bare-booted RP2350. Only the board tells you that.

So this is the same experiment twice, on the same chip:

- A **secret + a signing key** in memory the untrusted side must never read.
- A **service call** in: give me a counter, sign this challenge with your key.
- A **deliberate illegal read** of the secret from the untrusted side.
- Results published to a RAM mailbox and read back over **SWD** — no UART on either side,
  so the verdict is bytes out of the chip, not a `printf` I chose to believe.

Same demo, same board, same readout. What differs is only the mechanism.

## The mapping

| Arm Cortex-M33 (`minimal-tz`) | RISC-V Hazard3 (`minimal-pmp`) |
|---|---|
| Secure world | M-mode |
| Non-Secure world | U-mode |
| SAU region | PMP region |
| NSC veneer (SG gateway) | `ecall` |
| S to NS via `BLXNS` | M to U via `mret` |
| Illegal NS read to SecureFault | Illegal U read to PMP load access fault |
| Secure handler, `SFSR` / `SFAR` | M-mode trap handler, `mcause` / `mtval` |

The table is tidy. The engineering underneath it is not symmetric at all.

## The gate: a branch versus a trap

On Arm, the gate is a **function call**. You tag a function `cmse_nonsecure_entry`, and
the toolchain does the rest. The compiler emits a Secure Gateway stub, the linker pins it
into a region the SAU marks Non-Secure-Callable, and a second link pass hands the
Non-Secure image an *import library* containing only the gateway addresses. From my built
Secure image:

```
100ff000 T secure_sign                    <- the SG veneer, in the NSC region
100ff008 T secure_get_counter
10000570 T __acle_se_secure_get_counter   <- the real body, in Secure .text
100005e0 T __acle_se_secure_sign
```

The Non-Secure image links against the import library, so it resolves `secure_sign` to
`0x100ff000` and *never sees* `__acle_se_secure_sign`. The call site is an ordinary C
call with a real type signature. That is genuinely elegant: the security boundary is a
linkage boundary, enforced by the build.

On RISC-V there is no such thing. The gate is a **trap**:

```c
register uint32_t a0 __asm__("a0") = arg0;
register uint32_t a7 __asm__("a7") = svc;
__asm__ volatile ("ecall" : "+r"(a0) : "r"(a1), "r"(a7) : "memory");
```

U-mode puts a service number in `a7` and traps. M-mode catches `mcause = 8`, demuxes the
number, does the work, writes the return into the saved `a0`, bumps `mepc` past the
`ecall`, and `mret`s back. I wrote all of that: the assembly trampoline that swaps to an
M-mode stack via `mscratch`, the register frame, the dispatcher.

That's the real split, and it isn't about strength:

- **Arm hides the mechanism in the toolchain.** Less code, a typed interface, and a
  compiler that will not let you accidentally export the implementation. But you're
  trusting machinery you can't see, and when it misbehaves you're debugging CMSE.
- **RISC-V hands you the mechanism.** More code, no types, a syscall number in a
  register. But there is nothing hidden: every instruction across the boundary is one I
  wrote and can read.

The same asymmetry shows up in pointer validation. Both sides must refuse a malicious
pointer from the untrusted world — otherwise the untrusted side just asks the trusted side
to read the secret *for* it. Arm gives you an intrinsic:

```c
if (cmse_check_address_range((void *)challenge, len,
                             CMSE_NONSECURE | CMSE_MPU_READ) == NULL) {
    return -2;
}
```

That call asks the actual SAU/MPU whether Non-Secure could legitimately touch that range.
RISC-V has no equivalent, so on the PMP side I wrote the check by hand — and a hand-rolled
range check is exactly the kind of thing that's fine in a demo and a CVE in a product.
This is the one place I think Arm is meaningfully ahead: not because PMP is weaker, but
because Arm shipped the safety rail and RISC-V left it as an exercise.

## The wall: an address map versus a privilege filter

The SAU carves the address map into regions and labels them. The RP2350's IDAU treats
everything as Secure by default, so you carve out what Non-Secure gets. Read back from the
running board in Secure state:

```
SAU->CTRL = 0x00000001
region 0:  RBAR=0x100ff000  RLAR=0x100fffe3   <- NSC (veneers)
region 1:  RBAR=0x10100000  RLAR=0x101fffe1   <- Non-Secure flash
```

PMP is not a map. It's a **filter on the privilege ladder**, evaluated first-match, and
the default is the interesting part: if no entry matches, an M-mode access *succeeds* and
a U-mode access *fails*. So U-mode starts with access to nothing, and you grant it.

```
pmpcfg0 = 0x00001f18
  entry 0 = 0x18   NAPOT, no R/W/X   -> the secret region: deny
  entry 1 = 0x1f   NAPOT, R+W+X      -> everything else: allow
```

Two entries: deny the 64-byte secret first, allow the whole map second. First match wins,
so U-mode can run its own code and touch its own stack, and the hole in the middle faults.
Leaving the lock bit clear is what keeps M-mode out of scope, which is how M-mode still
reads the key to sign with.

Conceptually: **TrustZone is spatial** (this address belongs to that world), **PMP is
modal** (this mode may touch this address). They meet in the middle for a two-world demo,
but they generalise in different directions. TrustZone gives you two worlds and each has
its own privilege ladder underneath. PMP gives you one ladder and a programmable filter.
If what you want is "a secure world with its own OS," Arm's model is shaped like your
problem. If what you want is "keep this task away from that buffer," PMP is.

## When it breaks: what the chip is willing to tell you

Both demos end the same way: the untrusted side reads the secret, and doesn't get it.

Arm, from the Secure fault handler's mailbox at `0x200006dc`:

```
5ecf0000  00000048  00000001  00000002  00000000  a9dd58a4  00000000  0000bad0
MARK      SFSR      CNT1      CNT2      SIGN_RC   SIGN_R0   LEAKED    NS_STAGE
```

RISC-V, from `g_mb` at `0x20000000`:

```
504d5002  5ec00001  00000005  5ec00001  00000055  00000001  00000002  aca4a4a4
MAGIC     XH3_BEF   XH3_CAUSE XH3_AFT   U_UP      CNT1      CNT2      SIGN0
00000005  00000000  00000000  0000600d
MCAUSE    MTVAL     LEAKED    STAGE
```

Both worked. Services returned counters `1, 2`. Both signed correctly with a key the
untrusted side never saw (`a9dd58a4` is `01 02 03 04` XOR `A5 5A DE AD`; `aca4a4a4` is the
same challenge XOR the RISC-V demo's `A5 A6 A7 A8`). Both report **`LEAKED = 0`**.

But look at the fault reporting, because this is a real, measured difference:

- **Arm: `SFSR = 0x48`** — that's `AUVIOL` (attribution unit violation: Non-Secure touched
  Secure) *and* `SFARVALID`. The valid bit means the faulting address is sitting in `SFAR`
  for you to read.
- **Hazard3: `mcause = 5`** (load access fault), **`mtval = 0`**.

The RISC-V privileged spec *permits* `mtval` to be zero for access faults, and Hazard3
takes that option. So on the Arm side the hardware tells you what was touched; on the
RISC-V side it tells you only that something was. I could recover the faulting
*instruction* from `mepc` (`0x100001f6`, exactly the U-mode `lw`), and from there infer the
address by reading the code — but that's me doing forensics the Arm part answers directly.

If you're building a fault handler that reports or recovers, that gap is not academic.

## The twist: the same silicon only fought one of them

Here's the part I did not expect, and the reason I think this comparison earns its keep.

The obvious Arm design — a normal pico-sdk Non-Secure image executing in place from flash
— **does not work on a bare-booted RP2350**, and it took SWD to find out why. With the SAU
and ACCESSCTRL both verified correct on the running board, the Non-Secure image faulted
immediately inside the C runtime. The register file told the story:

```
r4 = 0x1010337c    <- walking the init_array
r3 = 0x00000000    <- the function pointer it just loaded
```

It had loaded an initialiser pointer from flash and gotten **zero**. The debugger, reading
the same address, saw the real pointer (`0x10101259`). So: Non-Secure *instruction fetch*
from XIP flash works, Non-Secure *data reads* of XIP flash return zero. `blx 0`, UsageFault,
done. Invalidating the XIP cache changed nothing — it's the read path, not stale lines.

Relocating the Non-Secure image into SRAM (Secure copies it in before `BLXNS`, since Secure
*can* read flash) fixed that, and revealed the next wall: the pico-sdk runtime then hung
forever in `runtime_init_early_resets`, polling `RESETS_RESET_DONE`. The debugger saw the
bits set. The Non-Secure CPU didn't. Same shape of problem, one layer down.

So the Arm Non-Secure side ended up as a deliberately tiny **bare-metal** image: its own
vector table, no libc, no clock or reset setup, copied into Non-Secure SRAM by the Secure
world. Two hundred bytes. That's not elegance, that's what the platform left standing.

The RISC-V side had none of this. U-mode read flash normally the moment a PMP entry granted
it. No copy, no bare-metal retreat, full pico-sdk runtime. **Same chip.**

The lesson isn't "RISC-V is better." It's that the *platform*, not the architecture, decided
which path was pleasant. The RP2350's Arm secure story is the productised one — TF-M has a
real `rpi/rp2350` port, and I ran its regression suite to 16/16 on this board before writing
any of my own code. But that path goes through BL2 and secure boot. Step off it and build a
plain SDK Secure+Non-Secure pair, and you're in territory the SDK doesn't support yet —
which is precisely what
[pico-examples#708](https://github.com/raspberrypi/pico-examples/issues/708) has been asking
for. The RISC-V PMP path is less travelled and has no framework at all, and it just worked.

## The thing Hazard3 has that TrustZone structurally can't

Base RISC-V PMP has an awkward corner: entries don't apply to M-mode unless you set the
lock bit — and the lock bit is *permanent until reset*. So "temporarily sandbox the most
privileged mode" isn't in the base ISA. You can have M-mode restricted, or you can have it
reversible. Not both.

Hazard3 adds `Xh3pmpm`: a custom CSR (`PMPCFGM0`, `0xbd0`) where one bit per region means
"apply this to M-mode too, *without* locking it." The RP2350 datasheet's own framing is
that PMP is useful for non-security things like stack guarding, and this lets M-mode use
unlocked regions for its own purposes.

I put it in the demo, because it's the one place the RISC-V side is strictly more expressive:

```
XH3_BEFORE = 0x5ec00001   M-mode reads the secret: allowed
XH3_MCAUSE = 0x00000005   set PMPCFGM0 bit 0 -> M-mode faults on its own region
XH3_AFTER  = 0x5ec00001   clear it -> M-mode reads again
```

M-mode sandboxed itself, took the fault, lifted the restriction, and carried on. TrustZone-M
has no analog: Secure is Secure. You can constrain Secure *privilege* with the MPU, but
there's no "make the Secure world subject to the SAU for a while, then stop."

(Worth noting pico-sdk already uses exactly this for optional stack guards — entry 0 plus
`PMPCFGM0`. They're off by default, which is why entry 0 was free for me.)

## The thing neither of them has: the DMA

Both mechanisms protect *the CPU's* accesses. The RP2350's DMA engine has **its own MPU**
(`dma_hw->mpu_region[]`), and it does not consult the SAU. Configure only the SAU, and
Non-Secure code can program the DMA to fetch Secure memory on its behalf and hand it over.
Your beautiful two-world partition is a formality.

The fix is to mirror the SAU partitioning into the DMA MPU, which TF-M's port does and which
I carried into `minimal-tz`. I've never seen a generic Cortex-M33 tutorial mention it,
because it isn't a Cortex-M33 fact — it's an RP2350 fact.

Which is the general point in miniature: the architecture manual describes the wall around
the CPU. The chip contains other things that can read memory.

## What I actually take away

TrustZone-M and PMP look like competing answers. They're not. They're answers to different
questions that happen to produce the same demo output.

TrustZone asks *"which world does this address belong to?"* and answers it with a linker
script, a compiler attribute, and an import library. When it fits, it's beautiful — a
security boundary you can typecheck. When you step outside the supported path, you're
alone with `mepc`-equivalents and a chip that returns zeros.

PMP asks *"may this mode touch this address?"* and answers it with two CSR writes and a trap
handler you wrote yourself. Nothing is hidden and nothing is provided. `mtval` won't even
tell you the address.

I only know any of this because I ran both on the same board and read the bytes out over
SWD. The spec would have told me neither that Non-Secure XIP data reads return zero, nor
that Hazard3 zeroes `mtval`, nor that the fancier-tooled of the two would be the one that
fought back. Both demos say `LEAKED = 0`. Everything interesting is in what it cost to get
there — and that only shows up on hardware.

Same drum as always: *boots* is not *works*, and the only way to know which one you have is
to make the chip tell you.

</details>

<script src="/js/reveal-toc.js" defer></script>

<div style="margin-top: 2.5em;">
<div class="a2a_kit a2a_kit_size_32 a2a_default_style">
<a class="a2a_dd" href="https://www.addtoany.com/share"></a>
<a class="a2a_button_facebook"></a>
<a class="a2a_button_twitter"></a>
<a class="a2a_button_linkedin"></a>
<a class="a2a_button_reddit"></a>
<a class="a2a_button_hacker_news"></a>
<a class="a2a_button_slashdot"></a>
<a class="a2a_button_telegram"></a>
<a class="a2a_button_whatsapp"></a>
<a class="a2a_button_line"></a>
<a class="a2a_button_facebook_messenger"></a>
<a class="a2a_button_mewe"></a>
<a class="a2a_button_flipboard"></a>
<a class="a2a_button_email"></a>
<a class="a2a_button_google_translate"></a>
</div>
<script async src="https://static.addtoany.com/menu/page.js"></script>
</div>
