---
title: "Bringing Up the RK3576 NPU on Mainline Linux"
date: 2026-06-15
tags: ["linux", "rockchip", "npu", "embedded", "rk3576"]
description: "How I found the dispatch mechanism that makes the RK3576 NPU actually compute — and why the same regcmd that works on RK3588 produces all-zero output on RK3576."
showToc: true
draft: false
---

The RK3576 has a 6 TOPS NPU. The open-source `rocket` DRM-accel driver targets it.
After 168 submitted jobs, every output byte was zero. This is what happened next.

## Background

[fill in]

## The Setup

- Board: Radxa ROCK 4D (RK3576, 12 GiB LPDDR5)
- Kernel: linux-next 7.1.0-rc5
- Driver: `rocket` (DRM accel, `/dev/accel/accel0`)
- Model: MobileNetV1 224×224 via Mesa Teflon TFLite delegate

## What "Working" Looked Like — and Didn't

[fill in: 168 jobs, all-zero, executer bit16 never set]

## Offline Regcmd Extraction

[fill in: rknn-toolkit2 on aarch64, vendor command stream extraction]

## The CNA_CLK_GATE Dead End

`CNA_CLK_GATE (0x1090) = 0x2a` was missing from Mesa's register writes.
I added it. Still all-zero. The clock gate was a real bug, but not the root cause.

## Finding the Dispatch Mechanism

[fill in: PC_DMA_BASE_ADDR, rknpu_task descriptor, RK3576 vs RK3588 difference]

## Result

[fill in: STAT 0x1→0x20005, DPU DST non-zero, correct Top-1]

## What This Means for Mainline

[fill in: Mesa patch, upstream path]
