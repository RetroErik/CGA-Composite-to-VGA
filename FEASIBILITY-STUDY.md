# CGA-Composite-to-VGA Recolor TSR — Feasibility Study

A DOS TSR that gives CGA games **16 colors on any VGA system** by converting CGA framebuffer data to VGA Mode 13h in real time. Inspired by the Olivetti PC1's zero-overhead hardware trick — reimplemented in software for the broader PC ecosystem.

## Background: The PC1 Trick

The Olivetti Prodest PC1 (Yamaha V6355D) has three hardware features that combine to give CGA games 16 colors with zero CPU cost:

1. **Hidden 160×200×16 mode** — 4-bit indexed color, 16 programmable RGB colors from 512
2. **Memory mirroring** — segments B000h and B800h map to the same physical 16KB VRAM
3. **Compatible bit layout** — CGA's packed pixel data is already valid as 4-bit color indices

A game writes CGA data to B800h. The hidden mode reads the same data from B000h. Each nibble becomes a color index. No CPU involvement — the video chip does the reinterpretation in hardware.

**This project asks: can we replicate this trick in software, on any 386+ VGA system?**

## The Problem

VGA cannot do this in hardware:

| Feature | PC1 (V6355D) | VGA |
|---------|--------------|-----|
| CGA segment (B800h) | Mirrored to B000h | Separate from A000h |
| 16-color packed mode | 4bpp nibble-indexed | Planar (4 bit planes) |
| Palette reprogramming | 16 colors from 512 | 16 colors from 262,144 |
| Layout compatibility | CGA bytes = color nibbles | CGA bytes ≠ VGA layout |

The fundamental mismatch: VGA's A000h is physically separate from CGA's B800h, and VGA's 16-color modes use planar memory — a completely different layout from CGA's packed pixels.

## Proposed Solution: Software Conversion TSR

### Architecture

```
┌─────────────┐    INT 08h/1Ch     ┌──────────────┐
│  CGA Game   │    timer tick      │  TSR Engine  │
│  writes to  │ ──────────────────>│  converts &  │
│  B800:0000  │                    │  copies to   │
│  (16 KB)    │                    │  A000:0000   │
└─────────────┘                    └──────────────┘
                                         │
                                         ▼
                                   ┌──────────────┐
                                   │  VGA Mode 13h│
                                   │  320×200×256 │
                                   │  (64 KB)     │
                                   └──────────────┘
```

### Step-by-Step Operation

1. **TSR installs** — hooks INT 10h (video BIOS) and INT 1Ch (timer tick)
2. **Game sets CGA mode 4, 5, or 6** via INT 10h — TSR intercepts, switches VGA to Mode 13h instead, programs DAC with 16 chosen colors, and sets emulation flag
3. **Game draws to B800h** as normal — CGA compatibility mode keeps these writes working
4. **Every frame** (via timer hook), TSR reads 16KB from B800h, converts packed CGA nibbles to linear VGA bytes, writes 64KB to A000h
5. **Game exits** or sets a non-CGA mode — TSR deactivates, restores normal VGA

### CGA-to-VGA Conversion Logic

#### Mode 4/5 (320×200×4, 2bpp packed)

Source: Each CGA byte = 4 pixels at 2 bits each.
PC1 interpretation: Each nibble = a pixel-pair combination (16 possibilities).
VGA Mode 13h: Each byte = 1 pixel (8-bit index into 256-color DAC).

**Conversion approach — 256-byte lookup table:**

```
; For each possible CGA byte value (0-255), pre-compute 4 VGA pixels.
; But 4 bytes output per 1 byte input = need a 1KB LUT (256 × 4 bytes).
;
; Alternatively, use the PC1's nibble interpretation:
;   High nibble → left pixel-pair color index (0-15)
;   Low nibble  → right pixel-pair color index (0-15)
;
; Each nibble maps to a DAC color. In Mode 13h, we double each pixel
; horizontally to fill 320 pixels from 160 logical pixels:
;
;   CGA byte → high nibble → pixel-pair color → 2 VGA bytes (doubled)
;            → low nibble  → pixel-pair color → 2 VGA bytes (doubled)
;
; Total: 1 CGA byte → 4 VGA bytes
; Can use a 256-entry LUT: index = CGA byte, value = 4-byte DWORD
```

Optimal inner loop (386+):

```nasm
; ds:si → CGA source (B800:xxxx)
; es:di → VGA dest   (A000:xxxx)
; ebx   → LUT base (256 DWORDs = 1024 bytes)

.convert_line:
    lodsb                    ; AL = CGA byte (2 pixels × 2bpp = 4 pixels)
    xor     ah, ah
    shl     ax, 2            ; ×4 for DWORD index
    mov     eax, [bx+ax]     ; 4 VGA pixels from LUT
    stosd                    ; write 4 pixels to VGA
    loop    .convert_line
```

#### Mode 6 (640×200×2, 1bpp packed)

Source: Each CGA byte = 8 pixels at 1 bit each.
PC1 interpretation: Each nibble = 4 adjacent bits → 1 artifact color index (0-15).
VGA Mode 13h: Need to expand each nibble to pixels.

**Conversion: each nibble → 4 VGA bytes (pixel-quadrupled) or 2 VGA bytes (pixel-doubled)**

At 160 logical NTSC artifact colors across, doubled to 320 Mode 13h pixels:

```nasm
; Each CGA byte → 2 nibbles → 2 artifact color indices
; Each index → 2 VGA bytes (doubled) = 4 VGA bytes per CGA byte
; Same 1KB LUT approach works, just with different color mappings
```

### Handling CGA's Interleaved Scanlines

CGA framebuffer is split into two banks:
- **Even scanlines** (0, 2, 4, ...): offset 0000h–1F3Fh (8000 bytes)
- **Odd scanlines** (1, 3, 5, ...): offset 2000h–3F3Fh (8000 bytes)

Each scanline = 80 bytes. VGA Mode 13h is linear: scanline N starts at offset N×320.

The TSR must deinterleave during copy:

```nasm
; Pseudocode for full frame conversion:
;   for row = 0 to 199:
;     if row is even:
;       cga_offset = (row/2) × 80
;     else:
;       cga_offset = 2000h + ((row-1)/2) × 80
;     vga_offset = row × 320
;     convert 80 CGA bytes → 320 VGA bytes via LUT
```

## Performance Analysis

### Data Volumes

| Item | Size |
|------|------|
| CGA framebuffer (source) | 16,000 bytes (80 × 200) |
| VGA framebuffer (dest) | 64,000 bytes (320 × 200) |
| LUT | 1,024 bytes (256 × 4) |
| Total memory throughput | 80 KB per frame (16KB read + 64KB write) |

### CPU Cycle Budget

At 60 Hz (CGA/VGA refresh rate), one frame = 16.67 ms.

| CPU | Clock | REP MOVSD rate | Effective throughput | 80KB copy time | % of frame |
|-----|-------|----------------|---------------------|----------------|------------|
| 386 SX/16 | 16 MHz | ~4 MB/s | ~2 MB/s (with LUT) | ~40 ms | **240%** ❌ |
| 386 DX/25 | 25 MHz | ~8 MB/s | ~4 MB/s (with LUT) | ~20 ms | **120%** ❌ |
| 386 DX/33 | 33 MHz | ~10 MB/s | ~5 MB/s (with LUT) | ~16 ms | **96%** ⚠️ |
| 386 DX/40 | 40 MHz | ~12 MB/s | ~6 MB/s (with LUT) | ~13 ms | 80% ✓ |
| 486 DX/33 | 33 MHz | ~25 MB/s | ~12 MB/s (with LUT) | ~7 ms | 40% ✓ |
| 486 DX2/66 | 66 MHz | ~50 MB/s | ~20 MB/s (with LUT) | ~4 ms | 24% ✓ |
| 486 DX4/100 | 100 MHz | ~60 MB/s | ~25 MB/s (with LUT) | ~3 ms | 18% ✓ |
| Pentium 60 | 60 MHz | ~80 MB/s | ~40 MB/s | ~2 ms | 12% ✓ |

> **Note:** "Effective throughput" accounts for the LUT conversion overhead (~2× slower than raw REP MOVSD) plus the CGA interleave handling. Real numbers will vary based on cache, ISA/VLB/PCI bus speed, and VGA write speed.

### The VGA Write Bottleneck

**Critical issue:** VGA video memory writes are significantly slower than system RAM. On ISA-bus VGA cards (most 386 systems), writes to A000h go through the 8 MHz ISA bus regardless of CPU speed:

| Bus | Peak write bandwidth |
|-----|---------------------|
| ISA 8-bit (8 MHz) | ~4 MB/s theoretical, ~2-3 MB/s real |
| ISA 16-bit (8 MHz) | ~8 MB/s theoretical, ~5-6 MB/s real |
| VLB (33-40 MHz) | ~30+ MB/s |
| PCI (33 MHz) | ~30+ MB/s |

Writing 64KB at ISA 16-bit speed: ~64KB / 5 MB/s = **~13 ms** — this alone consumes 78% of a frame. The ISA bus is the real bottleneck, not the CPU.

### Verdict

| System | Feasible? | Notes |
|--------|-----------|-------|
| 386 SX/16 + ISA VGA | ❌ No | Too slow on both CPU and bus |
| 386 DX/25 + ISA VGA | ❌ No | ISA bus alone takes most of the frame |
| 386 DX/33 + ISA VGA | ⚠️ Marginal | Possible at reduced framerate (30 fps) |
| 386 DX/40 + ISA VGA | ⚠️ Marginal | Workable at 30 fps |
| 486 + ISA VGA | ✓ Yes | CPU fast enough, ISA bus still the bottleneck |
| 486 + VLB VGA | ✓✓ Yes | Sweet spot — both CPU and bus are adequate |
| Pentium + PCI VGA | ✓✓✓ Yes | Trivial — well under 1 frame |

**Practical minimum: 486 with VLB or PCI VGA** for smooth 60 fps operation.
A **386DX/33+ with ISA VGA** can work at reduced framerate (every other frame = 30 fps).

## Optimization Strategies

### 1. Skip Unchanged Frames (Dirty Detection)

Don't redraw if nothing changed. Compare a hash/checksum of the CGA framebuffer against the previous frame:

```nasm
; Quick 32-bit XOR checksum of CGA framebuffer
xor     eax, eax
mov     ecx, 4000           ; 16000 bytes / 4
mov     esi, cga_buffer
.hash:  xor     eax, [esi]
        add     esi, 4
        loop    .hash
cmp     eax, [last_hash]
je      .skip_frame          ; nothing changed, skip conversion
```

Cost: ~4000 cycles (trivial). Saves entire frame when game is idle/paused.

### 2. Partial Updates (Dirty Rectangles)

Divide the screen into horizontal bands (e.g., 8 bands of 25 scanlines). Only convert bands where CGA data has changed. For many games, only a small portion of the screen updates each frame.

### 3. Reduced Framerate

Convert every 2nd or 3rd timer tick instead of every tick. 30 fps is still smooth for CGA games (which often ran at 15-30 fps anyway). Cuts CPU overhead in half.

### 4. Unrolled LUT Conversion

Instead of `lodsb` + LUT + `stosd`, unroll the inner loop to process 4 CGA bytes (16 VGA pixels) per iteration, keeping the LUT in cache:

```nasm
; Process 4 CGA bytes per iteration, 20 iterations per scanline
.row_loop:
    mov     al, [esi]
    mov     edx, [ebx+eax*4]
    mov     [edi], edx
    mov     al, [esi+1]
    mov     edx, [ebx+eax*4]
    mov     [edi+4], edx
    mov     al, [esi+2]
    mov     edx, [ebx+eax*4]
    mov     [edi+8], edx
    mov     al, [esi+3]
    mov     edx, [ebx+eax*4]
    mov     [edi+12], edx
    add     esi, 4
    add     edi, 16
    dec     ecx
    jnz     .row_loop
```

### 5. VBlank-Synchronized Copy

Start the conversion at the beginning of VBlank (poll port 3DAh bit 3) to minimize visible tearing. The VBlank period is ~1.1 ms at 70 Hz — not enough to copy the full frame, but enough to update the top portion. The rest is written during the next active display, which may cause a visible tear line that scrolls. This is acceptable for most CGA games.

## TSR Design

### Memory Footprint

| Component | Size |
|-----------|------|
| INT 10h hook | ~100 bytes |
| INT 1Ch hook (timer) | ~50 bytes |
| Conversion routine | ~300 bytes |
| LUT (mode 4/5) | 1,024 bytes |
| LUT (mode 6) | 1,024 bytes |
| State variables | ~32 bytes |
| Signature + uninstall | ~100 bytes |
| **Total resident** | **~2.6 KB** |

This is tiny — smaller than most sound card TSRs.

### Hooks

| Interrupt | Purpose |
|-----------|---------|
| INT 10h | Intercept mode set (AH=00h). When game sets mode 4/5/6, switch VGA to Mode 13h, load palette, activate conversion. On non-CGA modes, deactivate. |
| INT 1Ch | User timer tick (called ~18.2×/sec by default). Perform the CGA→VGA conversion. Reprogram PIT for higher rate if needed. |
| INT 09h | Keyboard handler. CTRL+ALT+1..4 to switch palettes (same as PC1 version). |

### Mode 13h as Target

Mode 13h (320×200×256, linear) is ideal because:

- **Linear layout** — no planes, no latches, simple byte-per-pixel writes
- **256-color DAC** — set indices 0-15 to any RGB values (18-bit, 262,144 colors)
- **Correct resolution** — 320×200 matches CGA's logical resolution (with pixel doubling for mode 6)
- **Full VGA compatibility** — works on every VGA card ever made

### Palette Configuration

VGA DAC registers 0-15 are loaded with the same RGB values used by the PC1 TSR, scaled from the V6355D's 3-bit-per-channel (0-7) to VGA's 6-bit-per-channel (0-63):

```
VGA_R = PC1_R × 9    ; 0-7 → 0-63
VGA_G = PC1_G × 9
VGA_B = PC1_B × 9
```

The curated palettes from the PC1 NTSC TSR transfer directly.

### CGA Compatibility Concern

When VGA is in Mode 13h (A000h), does CGA memory at B800h still work? **Yes:**

- VGA hardware maintains the CGA-compatible memory window at B800h in all modes
- In Mode 13h, writes to B800h go to VGA's internal RAM but aren't displayed (the display reads from A000h)
- The data is still readable by the CPU from B800h
- Some VGA cards may not maintain B800h in Mode 13h — needs testing

**Fallback:** If B800h is not readable in Mode 13h on some cards, use VGA's CGA-compatible mode (mode 4/5) on the VGA side as well, and convert from B800h. But then the VGA output would be the unconverted CGA image. A better fallback: keep the VGA in a text/CGA mode and periodically switch to Mode 13h just long enough to update the display, then switch back. This is complex and probably unnecessary for most VGA cards.

## Comparison: PC1 Hardware vs. VGA Software

| Aspect | PC1 NTSC TSR | VGA Recolor TSR |
|--------|-------------|-----------------|
| CPU overhead | Zero | 5-40% (depends on CPU/bus) |
| Latency | Zero (same VRAM) | Up to 1 frame (16.67 ms) |
| Resolution | 160×200 | 320×200 (pixel-doubled) |
| Colors available | 16 from 512 | 16 from 262,144 |
| Palette quality | 3-bit RGB (V6355D) | 6-bit RGB (VGA DAC) |
| Minimum system | PC1 (8088-class) | 486 + VLB/PCI VGA |
| Compatibility | PC1 only | Any VGA system |
| Tearing | None (same VRAM) | Possible (async copy) |
| Game compatibility | All CGA games | All CGA games* |

\* *Some CGA games use direct port I/O to the CGA controller (3D8h/3D9h) instead of INT 10h. The TSR would need to handle this — either by hooking additional CGA registers or by detecting CGA-mode writes on the timer tick.*

## Risks and Open Questions

1. **B800h readability in Mode 13h** — Needs testing across VGA chipsets (Tseng, Trident, Cirrus, S3, ATI, etc.). If some cards don't maintain B800h in Mode 13h, may need a different approach.

2. **CGA register-level games** — Games that bypass INT 10h and program CGA registers directly (3D8h, 3D9h) won't trigger the TSR's mode detection. Solution: poll CGA status register on timer tick and detect mode changes heuristically.

3. **Palette register games** — CGA games that change the background color or palette via port 3D9h need the TSR to monitor this and adjust the 16-color palette accordingly.

4. **Timing-sensitive games** — Games that use CGA's horizontal/vertical retrace timing (port 3DAh) for synchronization. The TSR must not interfere with these reads.

5. **Snow avoidance** — Original CGA has "snow" artifacts during VRAM access. Some games deliberately time their writes to avoid snow. On VGA, there is no snow, but the TSR's timer-based copy adds a different kind of artifact (potential tearing).

6. **Self-booting games** — Games that boot from floppy without DOS cannot use a TSR. These are beyond scope.

7. **Memory managers** — EMM386, QEMM, and other 386 memory managers may conflict with timer-tick processing in the TSR. Testing required.

## Conclusion

**The project is feasible.** The core conversion is straightforward — a 1KB lookup table and ~300 bytes of conversion code, running once per frame on a timer tick. The main constraint is bus bandwidth, not CPU speed.

**Minimum practical target:** 486 with VLB or PCI VGA for 60 fps. A fast 386 with ISA VGA can work at 30 fps.

**What makes this unique:** No known DOS TSR has ever done this. DOSBox and other emulators solve this at the rendering layer (host-side), but on real hardware, CGA games have always been stuck with 4 colors on VGA. This would be the first tool to bring the PC1's 16-color trick to the broader PC ecosystem — in software rather than silicon.

The PC1's discovery of the NTSC recoloring principle, the curated palettes, and the nibble-to-color mapping all transfer directly. The only new engineering is the framebuffer copy and CGA deinterleaving, which is well-understood.

## Next Steps

1. **Prototype:** Build a minimal non-resident test program that sets Mode 13h, loads a palette, reads a CGA framebuffer from a file, converts via LUT, and displays it. Verify the visual output matches the PC1.

2. **VGA chipset testing:** Verify B800h readability in Mode 13h on common VGA chipsets (Tseng ET4000, Trident 8900, Cirrus 5426, S3 Trio, ATI Mach32/64).

3. **TSR skeleton:** Build the interrupt hooks (INT 10h mode intercept, INT 1Ch timer conversion, INT 09h keyboard palette switching) with install/uninstall logic.

4. **Performance profiling:** Measure actual conversion time on target hardware (486 VLB, 386 ISA) to determine achievable framerate.

5. **Game testing:** Test with a representative set of CGA games (both INT 10h-based and register-direct) to assess compatibility.
