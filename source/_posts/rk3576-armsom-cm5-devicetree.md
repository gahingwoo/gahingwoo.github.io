---
title: "ArmSoM Noticed the Work, and the CM5 Device Tree Hits v4"
slug: rk3576-armsom-cm5-devicetree
date: "2026-07-17"
categories:
  - Firmware & Secure Boot
og_image: /imgs/og-banner.png
tags:
  - rk3576
  - armsom
  - upstream
  - device-tree
  - linux
  - edk2
  - uefi
  - rockchip
description: "ArmSoM's sales team emailed unprompted this week after spotting the CM5-IO credit in the edk2-rk3576 README — and asked the one question that actually matters: is the CM5 device tree headed for mainline Linux too? It is, and it's at v4."
---

## TL;DR

- **ArmSoM's sales team emailed unprompted** after noticing the CM5-IO listed as
  hardware-verified in the edk2-rk3576 README — kind words about both the UEFI port
  and the NPU mainlining work, and one real question: is the CM5 device tree headed
  for mainline Linux too, or just riding along with the UEFI path?
- **It's going straight into mainline.** `rk3576-armsom-cm5.dtsi` (module) and
  `rk3576-armsom-cm5-io.dts` (carrier) are on the linux-rockchip list at **v4**, split
  the same way as ArmSoM's own Sige5 — already in mainline as
  `rk3576-armsom-sige5.dts` since v7.2-rc3 — which I used as the direct reference.
- **The binding patch carries Krzysztof Kozlowski's Acked-by**, and the DTS keeps
  ArmSoM's copyright line.
- **Hardware-verified on the CM5-IO**: GMAC0 with the on-module YT8531 linking at
  1000 Mbit/s, RK806, HYM8563, eMMC, microSD, the USB3 hub, and PCIe all probe.
- A small side patch too: a `dwmac-rk` fix on netdev that ungates the 25 MHz
  reference the crystal-less YT8531 needs in RGMII mode.

<!-- more -->

<details>
<summary style="cursor:pointer;font-weight:600;">Read the full write-up</summary>

Backstory first, since it's short: back in May I asked ArmSoM for a CM5 + CM5-IO
sample to get a second RK3576 board under the UEFI port — checking peripheral
bring-up (HDMI, USB, eMMC, WiFi/BT) against a board design different from the one
I'd been using, with the intent of upstreaming CM5 platform support to edk2. They
sent a CM5 Basic + CM5-IO, credited in the
[edk2-rk3576](https://github.com/gahingwoo/edk2-rk3576) README ever since.

This week ArmSoM's sales team emailed again, unprompted — they'd noticed that
credit and wanted to say the UEFI work, and separately the NPU mainlining effort,
had been worth following. The one actual question in the email: is the CM5 device
tree headed for mainline Linux as well, or is that something that follows the UEFI
path for now?

It's going straight into mainline. The series adding `rk3576-armsom-cm5.dtsi`
(the module) and `rk3576-armsom-cm5-io.dts` (the carrier) is on the linux-rockchip
list at v4 — split the same way ArmSoM already did for their Sige5 board, whose
device tree (`rk3576-armsom-sige5.dts`) landed in mainline at v7.2-rc3. That was the
direct reference for what a merged RK3576 platform file is expected to look like,
since ArmSoM had already been through review for a sibling board. The binding patch
carries Krzysztof Kozlowski's Acked-by, and the DTS keeps ArmSoM's copyright line.

Hardware-verified on the CM5-IO so far: GMAC0 with the on-module YT8531 linking at
1000 Mbit/s, RK806, HYM8563, eMMC, microSD, the USB3 hub, and PCIe all probe
correctly.

One separate small patch came out of this too: a `dwmac-rk` fix on netdev that
ungates the 25 MHz reference clock the crystal-less YT8531 needs in RGMII mode —
without it the PHY doesn't get a clean reference and link training is unreliable.

No conclusions yet — the series is still at v4 and review is ongoing. Just noting
the timeline: hardware in hand since May, work upstreamed since, and a vendor
noticing enough to ask about it unprompted, which is a nice thing to have happen.

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
