# CGA2VGA — CGA-Composite-to-VGA Recolor TSR

A DOS TSR (Terminate and Stay Resident) that gives CGA composite games **16 colors on many VGA system**. It intercepts CGA video mode sets, converts the CGA framebuffer to VGA Mode 13h in real time using a lookup table, and displays the result with composite-style artifact colors — the same technique the Olivetti Prodest PC1 uses in hardware.

The target audience is games that were designed for CGA composite color and have **no other way** to display 16 colors — games like Hard Hat Mack, Bruce Lee, Flight Simulator, and many others that only support CGA. Games that already have EGA or VGA support (Sierra AGI/SCI, Commander Keen, etc.) are better off using their native higher-color modes.

By **Retro Erik** — [YouTube: Retro Hardware and Software](https://www.youtube.com/@RetroErik)

Written using VS Code with GitHub Copilot.

![IBM PC / Compatible](https://img.shields.io/badge/Platform-IBM%20PC%20%2F%20Compatible-blue)
![386+ VGA](https://img.shields.io/badge/Requires-386%2B%20%2B%20VGA-blue)
![License](https://img.shields.io/badge/License-CC%20BY--NC%204.0-green)

> **⚠ Work in progress.** This is an experimental project, not a finished product. Many games work well, but some are broken, some run too slow, and some run too fast. See [Game Compatibility](#game-compatibility-real-hardware) and [Known Limitations](#known-limitations) below.

---

## Screenshots (Real Hardware)

### WIC PC — Pentium 200 MMX, ATI Mach 64 PCI

| Hard Hat Mack | King's Quest 1 | Planet X3 |
|:---:|:---:|:---:|
| ![HHM](Screenshots/WIC%20Pentium%20200%20-%20ATI%20Mach%2064%20-%20HHM.png) | ![KQ1](Screenshots/WIC%20Pentium%20200%20-%20ATI%20Mach%2064%20-%20KQ1.png) | ![PX3](Screenshots/WIC%20Pentium%20200%20-%20ATI%20Mach%2064%20-%20PX3.png) |

| King's Quest 2 | Commander Keen 4 | Zak McKracken |
|:---:|:---:|:---:|
| ![KQ2](Screenshots/WIC%20Pentium%20200%20-%20ATI%20Mach%2064%20-%20KQ2.png) | ![Keen4](Screenshots/WIC%20Pentium%20200%20-%20ATI%20Mach%2064%20-%20KEEN4.png) | ![Zak](Screenshots/WIC%20Pentium%20200%20-%20ATI%20Mach%2064%20-%20ZAC.png) |

### West PC — 386-40 MHz, Trident TVGA 9000B ISA

<p align="center">
  <img src="Screenshots/West%20PC%20386%20-%20Bruce%20Lee.png" alt="Bruce Lee" width="640">
  <br><em>Bruce Lee — first time working with CGA2VGA</em>
</p>

| Flight Simulator 3 | Hard Hat Mack |
|:---:|:---:|
| ![FS3](Screenshots/West%20PC%20386%20-%20FS3.png) | ![HHM](Screenshots/West%20PC%20386%20-%20HHM.png) |

| King's Quest 1 | Police Quest 1 |
|:---:|:---:|
| ![KQ1](Screenshots/West%20PC%20386%20-%20KQ1.png) | ![PQ1](Screenshots/West%20PC%20386%20-%20PQ1.png) |

---

## The Problem

CGA games are limited to 4 colors from fixed palettes (cyan/magenta/white or red/green/brown). On a real CGA card connected to a composite monitor, adjacent pixels blend together to produce up to 16 artifact colors — but VGA systems display raw digital RGBI, showing ugly 4-color graphics.

## The Solution

CGA2VGA installs as a TSR and intercepts CGA mode sets (modes 4, 5, and 6). It sets VGA Mode 13h (320×200×256) behind the scenes, then converts the CGA framebuffer at B800h to VGA-displayable pixels at A000h using a 256-entry lookup table — 18 times per second via the hardware timer interrupt.

Each CGA byte is split into two nibbles. Each nibble maps to one of 16 colors, reproducing the composite artifact color palette. The result looks like a real CGA composite display, but on any VGA monitor.

---

## How It Works

### Two CGA Modes, Two Interpretations

**Mode 4/5 (320×200×4, 2bpp):** Each byte = 4 pixels at 2 bits each. Each nibble represents a pixel pair (left×4 + right), giving 16 combinations mapped to 16 composite blend colors.

**Mode 6 (640×200×2, 1bpp):** Each byte = 8 pixels at 1 bit. Each nibble = 4 adjacent bits, giving 16 patterns that map 1:1 to the 16 NTSC artifact colors. ~60 games use this mode: Flight Simulator, Sierra AGI, Planet X3, etc.

### Interrupt Hooks

| Interrupt | Purpose |
|-----------|---------|
| **INT 08h** (hardware timer) | Converts CGA→VGA framebuffer ~18.2 times/sec. Chains to original handler FIRST so game sound/music gets its tick on time. Throttled to BIOS tick rate to handle games that reprogram the PIT to higher frequencies. |
| **INT 10h** (video BIOS) | Intercepts mode sets (AH=00h). CGA modes 4/5/6 trigger emulation setup. Reports faked CGA mode via AH=0Fh. Tracks page flipping (AH=05h) for AGI games. |
| **INT 09h** (keyboard) | CTRL+ALT hotkeys for palette switching and VSync toggle. |

### VGA State Protection

CGA games directly program the CRTC registers at 3D4h/3D5h, which on VGA corrupts Mode 13h display timing. The TSR saves all critical Mode 13h CRTC values at setup and restores them every frame using word-sized writes (`out dx, ax`).

The Graphics Controller register 6 is set to 128K memory map (A0000–BFFFF), making both the VGA framebuffer (A000h) and CGA framebuffer (B800h) accessible simultaneously.

---

## Requirements

- **CPU:** 386 or higher (uses 32-bit registers for LUT conversion)
- **Video:** Any VGA card (ISA, VLB, or PCI)
- **Recommended:** 486+ with VLB/PCI VGA for smooth operation
- **OS:** DOS (real mode)
- **Build tool:** NASM (to reassemble from source)

---

## Usage

```dos
CGA2VGA              ; Install TSR
CGA2VGA /U           ; Uninstall TSR
```

Then run any CGA game. The TSR automatically detects CGA mode sets and activates.

### Live Hotkeys

Hold **CTRL+ALT** and press:

| Key | Action |
|-----|--------|
| `1` | Mode 4/5 curated palette (auto for 320×200) |
| `2` | Mode 6 curated palette (auto for 640×200) |
| `3` | Mode 4/5 reference palette (reenigne model) |
| `4` | Mode 6 reference palette (Nerdly Pleasures) |
| `V` | Toggle VSync wait (default: on) |

The TSR auto-selects the correct palette when a game sets the video mode. Hotkeys override the auto-selection at any time.

**VSync toggle:** VSync ON (default) waits for vertical retrace before each frame conversion — eliminates stutter but costs 0–16ms per frame. Toggle OFF on slow systems where the wait makes games too slow. Speaker click confirms the toggle.

---

## Palettes

Four palettes are included, inspired by the Olivetti Prodest PC1's V6355D hardware colors:

| # | Name | Mode | Description |
|---|------|------|-------------|
| 1 | Curated 4/5 | 320×200 | Hand-picked for CGA games. Best for KQ1, Bruce Lee, Zaxxon |
| 2 | Curated 6 | 640×200 | Hand-picked for composite artifact games. Best for FS3, Sierra AGI, PX3 |
| 3 | Reference 4/5 | 320×200 | Generated from reenigne's New CGA composite model |
| 4 | Reference 6 | 640×200 | Nerdly Pleasures NTSC artifact color chart |

---

## Game Compatibility (Real Hardware)

### Tested on West PC (386-40 MHz, Trident TVGA 9000B ISA)

| Game | Mode | Status | Notes |
|------|------|--------|-------|
| Planet X3 | 6 | **Works** | Music at full speed |
| Hard Hat Mack | 4/5 | **Works** | Music and graphics good |
| Flight Simulator 3 | 6 | **Works** | Best result of all games |
| King's Quest 1 | 6 | **Works** | Sound and graphics OK |
| King's Quest 2 | 6 | **Works** | |
| Zak McKracken | 4/5 | **Works** | A bit slow |
| NM-Pinball | 4/5 | **Works** | |
| Frogger 2 | 4/5 | **Works** | Non-composite game — colors reflect RGBI reinterpretation |
| Bruce Lee | 4/5 | **Works** | Slow on 386 — needs 486+ for full speed |
| Ms. Pac-Man | 4/5 | Broken | Crashes |
| Boulder Dash 1 | 4/5 | Broken | Black screen (non-standard VRAM layout) |

### Tested on WIC PC (Pentium 200 MMX, ATI Mach 64 PCI)

| Game | Mode | Status | Notes |
|------|------|--------|-------|
| Planet X3 | 6 | **Works** | |
| Hard Hat Mack | 4/5 | **Works** | |
| King's Quest 1 | 6 | **Works** | |
| King's Quest 2 | 6 | **Works** | |
| Commander Keen 4 | 4/5 | **Works** | |
| Zak McKracken | 4/5 | **Works** | |
| Battle Chess | 4/5 | **Works** | |
| Bruce Lee | 4/5 | **Works** | |
| Ms. Pac-Man | 4/5 | Broken | Crashes |
| California Games | 4/5 | Broken | |

### Tested on IBM ThinkPad i1411 (NeoMagic NM2160)

| Game | Mode | Status | Notes |
|------|------|--------|-------|
| Planet X3 | 6 | **Works** | Perfect speed and sound |
| Hard Hat Mack | 4/5 | **Works** | Too fast — game not speed-limited |
| Bruce Lee | 4/5 | **Works** | |
| King's Quest 1 | 6 | **Works** | |
| Tapper | 4/5 | **Works** | Music fine, gameplay too fast |
| Boulder Dash 1 | 4/5 | Broken | Black screen (music plays) |

### Hardware Compatibility

| VGA Chipset | Bus | Status |
|-------------|-----|--------|
| Trident TVGA 9000B | ISA | **Works** |
| NeoMagic NM2200 | Internal | **Works** |
| NeoMagic NM2160 | Internal | **Works** |
| ATI Mach 64 | PCI | **Works** |
| Cirrus CL-GD5424 | VLB | Broken — display engine incompatible with GC6=00 in chain-4 mode |
| Cirrus CL-GD5428 | VLB | Broken — same issue |

---

## Background

The Olivetti Prodest PC1 (1987) has a unique V6355D video chip that provides 16 colors in CGA modes with zero CPU overhead. It mirrors the CGA framebuffer from B800h to B000h and reinterprets each nibble as a 16-color palette index. Games see standard CGA, but the display shows 16 colors — no software required.

This TSR replicates that trick in software for any VGA system. Instead of hardware mirroring, a timer interrupt reads B800h, converts via LUT, and writes to A000h (Mode 13h). The overhead is ~20ms per frame on a 386/40, which is acceptable for most games on 486+ systems.

---

## Building

```dos
nasm -f bin CGA2VGA.asm -o CGA2VGA.COM
```

Produces a .COM file (3,324 bytes). No linker needed.

---

## Known Limitations

### Speed

The framebuffer conversion runs on the CPU at ~18 Hz. This adds overhead that affects game speed differently depending on the system and the game:

- **Too slow:** Action games like Bruce Lee and Hard Hat Mack can feel sluggish on a 386. A 486 or faster is recommended for these. Toggling VSync OFF (CTRL+ALT+V) can help.
- **Too fast:** Some games that rely on CGA timing loops may run faster than expected because Mode 13h has different vertical timing than CGA modes.

Speed optimization is ongoing work.

### Other Limitations

- **Cirrus Logic VLB cards** show garbled display. The Cirrus display engine cannot render Mode 13h correctly when GC register 6 is set to 128K memory map. This is a hardware limitation.
- **Ms. Pac-Man and California Games** crash. These games bypass INT 10h entirely for mode switching, using direct port I/O that the TSR cannot intercept.
- **Non-composite CGA games** (designed for RGBI monitors) will show composite artifact colors that don't match the original intent. This is inherent to the recoloring approach.

---

## License

Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0) — see [LICENSE](LICENSE) for details.

Copyright (C) 2026 Retro Erik
