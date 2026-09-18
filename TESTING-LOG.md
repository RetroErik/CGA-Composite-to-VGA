# CGA2VGA TSR — Testing Log

## Test Environment
- **DOSBox 0.74-3** — Config: `ASM-386-VGA/dosbox-dev.conf`, `machine=vgaonly`
- **Real Hardware** — Multiple systems tested (see Hardware Compatibility below)

---

## Game Compatibility

### Working (all versions since v0.1-fixed)
| Game | Mode | Notes |
|------|------|-------|
| Frogger 2 | 4/5 | Works reliably |
| Zack McKracken | 4/5 | Works reliably |
| Indianapolis 500 (`/c1`) | 6 | Always works |
| Commander Keen 4 | 4/5 | Confirmed v0.2 |
| Kings Quest 4 | 6 | Confirmed v0.2 |
| NM-Pinball | 4/5 | Confirmed v0.1 |
| Battle Chess (`chess.exe /comp`) | 4/5 | Confirmed v0.1 |
| Hard Hat Mack (`hhmcomp.com`) | 4/5 | Very colorful — good for video |
| Jungle Hunt | 4/5 | Starts, needs joystick |
| Bruce Lee | 4/5 | **Fixed in v0.9** — INT 08h hook resolved bypass-INT10h issue |
| Tapper | 4/5 | Works — music fine, gameplay too fast on faster systems |

### Broken — No Graphics (text works)
| Game | Mode | Symptom | Notes |
|------|------|---------|-------|
| Ms. Pac-Man | 4/5 | Black screen, text OK | Consistently broken all versions |
| California Games | 4/5 | Does not work | Confirmed broken v0.8c+ |

### Broken — Black Screen
| Game | Mode | Symptom | Notes |
|------|------|---------|-------|
| JBird | 4/5 | Completely black | Confirmed v0.1 |
| Jumpman | 4/5 | Completely black | Confirmed v0.1 |

### Broken — Partial
| Game | Mode | Symptom | Notes |
|------|------|---------|-------|
| Super Boulder Dash | 4/5 | Title screen works, game does not | Consistently broken all versions |

### Broken — Random/Intermittent
| Game | Mode | Symptom | Notes |
|------|------|---------|-------|
| KQ1 (`-c` composite) | 6 | Sometimes works, sometimes black | Random across all versions |
| Sierra AGI games generally | 6 | Intermittent failures | Race condition suspected |

---

## Version History & What Was Tried

### v0.1-fixed (baseline — 4 bug fixes)
The only version that actually changed behavior. All subsequent versions had no measurable effect on the broken games.

**Bug fixes that worked:**
1. **B800h not initialized** — Set actual CGA mode before Mode 13h so DOSBox initializes its B800h memory handler
2. **BDA leaked Mode 13h** — Patched 0040:0049 (mode), 004A (columns), 004C (page size), 0063 (CRTC port) back to CGA values
3. **VBlank wait hung forever** — Added 65536-iteration timeout on both VBlank wait phases
4. **"Don't clear" flag lost** — Properly saved/restored original AL with bit 7 across palette selection code

### v0.2 — AH=0Bh/10h interception + per-frame palette reload
**Theory:** Games calling INT 10h AH=0Bh (Set CGA Palette) were corrupting VGA DAC.
**Changes:**
- Intercepted AH=0Bh (CGA palette) — consumed when emulating
- Intercepted AH=10h (VGA DAC functions) — consumed when emulating
- Reloaded VGA palette every frame during VBlank
- Restored CGA pre-init before Mode 13h

**Result:** No change. Broken games still broken.

### v0.3 — Per-frame VGA state restoration (GC6, CRTC start, AC)
**Theory:** Games writing directly to CGA ports (3D4h/3D5h, 3D8h/3D9h) were corrupting VGA registers.
**Changes:**
- New `restore_vga_state` routine called every frame
- Reset GC register 6 (128K window)
- Reset CRTC start address to 0
- Reset Attribute Controller identity mapping (0→0 ... 15→15)

**Result:** No change. Broken games still broken.

### v0.4 — Comprehensive CRTC/Seq/AC restoration
**Theory:** Games programming CGA CRTC timing registers destroyed Mode 13h timing/addressing.
**Changes:**
- Full CRTC register table (18 registers) for Mode 13h
- CRTC protection bit (reg 11h bit 7) to block game writes to regs 0-7
- Sequencer regs 2/4 restoration (chain-4 mode, plane mask)
- AC mode registers (10h-14h) restoration
- All restored every frame during VBlank

**Result:** No change. Broken games still broken.

### v0.5 — Rolled back to v0.1-fixed baseline
Stripped all v0.2-v0.4 additions. Clean baseline for real hardware testing.

### v0.6-diag — Diagnostic: Overscan border flash (ACCIDENTALLY FIXED SIERRA!)
**Purpose:** Add border-color flashes via AC register 11h (overscan) to diagnose B800h state.
**Changes:**
- Read port 3DA (reset AC flip-flop) + write AC reg 11h via port 3C0 every frame
- Red = mode handler fired, Green = B800h has data, Blue = B800h empty
- Full 16KB B800h scan loop (4096 dword reads) before conversion

**Result:** Border not visible in DOSBox (it doesn't render overscan area). But **Sierra AGI (KQ1) suddenly worked every single time** — the AC register I/O sequence accidentally stabilized DOSBox.

### v0.6a-diag — Diagnostic: Pixel block instead of overscan
**Purpose:** Replace invisible overscan flash with 8×4 pixel block drawn to A000h.
**Changes:**
- Removed AC register 11h writes (the stabilizer!)
- Drew 8×4 colored block at top-right of VGA framebuffer instead
- Block drawn AFTER conversion so it wouldn't be overwritten

**Diagnostic results (DOSBox):**
| Game | During Load | During Gameplay | Notes |
|------|-------------|-----------------|-------|
| Frogger 2 | Green | Green | Working game — data present |
| KQ1 (`-c`) | Blinking green | Blue when working | Only works randomly again (lost Sierra fix!) |
| Indianapolis 500 | Green | Blue | Works despite blue — might use different offsets |
| Ms. Pac-Man | — | No box at all | `is_emulating` gets turned off |
| Bruce Lee | Blue (loading) | No box (gameplay) | Blue = no data on load; emulation disabled during gameplay |

**Key insight:** Removing the AC register I/O broke Sierra again. The pixel block version is only memory writes, no port I/O → no stabilizing effect.

### v0.6b — Full scan always + GC6 re-assert (no AC touch)
**Theory:** Maybe the full 16KB scan itself was the stabilizer, and it needed to never early-exit.
**Changes:**
- Pre-scan always reads full 16KB (no early exit on first non-zero byte)
- GC register 6 re-asserted to 128K mode every frame before scan

**Result:** No change. KQ1 still random. The scan and GC6 alone don't stabilize DOSBox.

### v0.6c — GC6 re-assert + AC register touch + full scan
**Theory:** The AC register 11h write via 3DA/3C0 is the specific DOSBox stabilizer.
**Changes:**
- GC reg 6 re-assert every frame
- 3DA read + AC reg 11h write (overscan=black) every frame — the exact I/O from v0.6-diag
- Full 16KB pre-scan

**Result:** No change. KQ1 still random. The AC I/O touch was coincidental timing, not a real fix.

### v0.7 — Stripped back to clean v0.5 baseline (again)
All v0.6 diagnostic/stabilizer code removed. Clean baseline for real hardware testing.
GC6 re-assert, AC touch, pre-scan — all removed. None reliably helped in DOSBox.

**Current code state:** Clean v0.5 = v0.1-fixed. No diagnostic code, no per-frame workarounds.

### v0.8 — Real Hardware: CRTC save/restore + GC6 re-assert (per-frame)
**Purpose:** Fix real hardware issues where CGA games' direct CRTC writes corrupt Mode 13h display.
**Changes:**
- Save 13 critical Mode 13h CRTC registers at mode setup time (chip-specific values from BIOS)
- Restore all 13 CRTC registers every frame (with protection bit unlock/re-lock)
- GC register 6 re-asserted to 128K map every frame
- CRTC start address reset to 0 every frame

**Result on real hardware:** Works on Trident TVGA 9000B (ISA), NeoMagic NM2200, ATI Mach 64 (PCI). Cirrus Logic VLB cards still show garbage (same as without CRTC restore).

### v0.8a — Shadow Buffer Approach (Cirrus fix attempt)
**Theory:** Cirrus display engine corrupts Mode 13h rendering when GC6=00. Toggle GC6 only during B800h reads.
**Changes:**
- Added 16KB shadow_buffer in resident data
- Saved GC6 Mode 13h default at mode setup (gc6_saved)
- convert_frame: set GC6=00 → rep movsd B800h→shadow buffer → restore GC6 → convert from buffer
- Restored GC6 to Mode 13h default after clears during setup

**Result:** Black screen on all systems. Game writes to B800h go nowhere when GC6 is at Mode 13h default — B800h is unmapped on VLB/PCI.

### v0.8b — Shadow Buffer with GC6=00 as resting state
**Theory:** Keep GC6=00 between frames (so game B800h writes work), toggle to gc6_saved only during A000h write phase.
**Changes:**
- GC6=00 left as permanent resting state after mode setup
- convert_frame Phase 1: copy B800h→shadow (GC6 already 00, no toggle needed)
- convert_frame Phase 3: set gc6_saved → convert shadow→A000h
- convert_frame Phase 4: restore GC6=00

**Result:** Cirrus still shows only moving objects (same as original). NeoMagic NM2160 (ThinkPad i1411) crashed during gameplay on multiple games — shadow buffer + GC6 toggling destabilized it.

### v0.8c — Revert to v0.8 + Speed Optimizations
**Purpose:** Remove shadow buffer (broken), keep working CRTC restore, add speed improvements.
**Changes:**
- Removed shadow_buffer, gc6_saved, all GC6 toggling code
- Reverted to permanent GC6=00 (128K map)
- `movzx eax, byte [si]` replaces `xor eax,eax` / `mov al,[si]` — saves 2 bytes + 1 cycle per LUT lookup (16,000 per frame)
- Even/odd row pairs with incremental BX+80 replaces per-row `imul` — saves 200 multiplications per frame
- File size: 3,274 bytes (down from 19,620 with shadow buffer)

**Result:** Works on Trident, NeoMagic NM2200, ATI Mach 64. Cirrus VLB still broken (accepted limitation). NM2160 needs re-testing with this version.

### v0.9 — INT 08h Hook + BIOS Tick Throttle + VSync Toggle + Word CRTC
**Purpose:** Fix slow music/sound on 386, add VSync toggle, optimize CRTC restore.
**Changes:**
- **INT 08h hook instead of INT 1Ch**: Chain to original INT 08h FIRST (game sound handler + BIOS tick + EOI all complete before conversion). Fixes timer tick starvation — game audio gets its tick on time.
- **BIOS tick throttle**: Games that reprogram the PIT to higher rates (e.g. PX3 at 240 Hz) call our INT 08h on every tick. Throttle by comparing BIOS tick counter (`0040:006C`) — only convert when it changes (~18.2 Hz). Extra calls are instant no-ops.
- **CTRL+ALT+V VSync toggle**: Default ON (wait for VBlank). Toggle OFF for ~16ms/frame savings on slow systems. Speaker click feedback on toggle.
- **Word-sized CRTC writes**: `out dx, ax` (AL=index, AH=data) replaces 26 individual `out dx, al` with 13 word writes. Halves CRTC restore port I/O count.
- File size: 3,324 bytes

**Result on 386/40 (Trident ISA):**
- **Music/sound fixed**: PX3 music at full speed, HHM music good, FS3 sound best ever
- **Bruce Lee works!** First time — bypass-INT10h games now work (cause: INT 08h hook runs even when `is_emulating` would skip INT 1Ch — the BIOS tick counter check still triggers conversion)
- **VSync ON** (default): No stutter in HHM, but Bruce Lee too slow
- **VSync OFF**: HHM and Bruce Lee faster, but some games may stutter
- **Games that reprogram PIT**: PX3 graphics+sound correct with throttle (was garbled without it)

---

## Theories Tested & Disproven

| Theory | Version | Why It's Wrong |
|--------|---------|----------------|
| AH=0Bh palette corruption | v0.2 | Intercepting it didn't fix anything |
| AH=10h DAC corruption | v0.2 | Intercepting it didn't fix anything |
| VGA palette drifts between frames | v0.2 | Per-frame reload didn't help |
| CRTC start address corruption | v0.3 | Resetting every frame didn't help |
| AC identity mapping corruption | v0.3 | Resetting every frame didn't help |
| Full CRTC timing corruption | v0.4 | Restoring all 18 regs didn't help |
| Sequencer mode corruption | v0.4 | Restoring chain-4 didn't help |
| CRTC protection prevents damage | v0.4 | Enabling protection didn't help |
| `machine=svga_s3` causing issues | — | We were using `machine=vgaonly` all along |
| Full 16KB pre-scan stabilizes DOSBox | v0.6b | Scan alone without AC I/O doesn't help |
| GC reg 6 re-assert stabilizes DOSBox | v0.6b | GC6 alone doesn't help |
| AC reg 11h I/O stabilizes DOSBox | v0.6c | Was coincidental timing, not reliable |
| Any per-frame port I/O helps | v0.6a-c | None reliably fixed KQ1 randomness |

---

## Diagnostic Findings

### Bruce Lee / Ms. Pac-Man — Bypass INT 10h for mode switching
- Loading screen: Blue box (B800h empty) or no box at all
- Gameplay: No diagnostic box = `is_emulating` is 0 = our timer handler isn't running
- **Root cause:** These games call INT 10h to set a non-CGA mode (text mode 0/3) and then directly program the CGA 6845 CRTC via port I/O to switch to graphics. Our INT 10h hook only catches modes 4/5/6, so a text mode call turns off emulation.
- **v0.9 fix (Bruce Lee):** Switching from INT 1Ch to INT 08h hook accidentally resolved Bruce Lee. The INT 08h chain-first approach means our handler always runs for the hardware timer, and the BIOS tick counter check still triggers conversion even after a text mode set turns off `is_emulating`... (TODO: investigate exact mechanism — Bruce Lee may be re-setting a CGA mode that we do catch, and the timing change made it work)
- **Still broken (Ms. Pac-Man):** Crashes. May use a different bypass mechanism.

### KQ1 / Sierra AGI — Timing-dependent, AC I/O stabilizes it
- Works reliably ONLY when AC register 11h is written via 3DA/3C0 every frame
- Without that specific I/O sequence, success is random (~50/50)
- The stabilizing effect is specifically from the **port 3DA read + port 3C0 write** sequence
- Not from the GC6 re-assert, not from the B800h pre-scan

---

## Current Best Theory

**Two separate problems:**

1. **Sierra/KQ1 (random):** DOSBox's Attribute Controller state machine needs periodic touching via 3DA/3C0 to keep its internal VGA state synchronized with the 128K memory mapping. The AC I/O acts as a "keep-alive" for DOSBox's page handler. Testing v0.6c to confirm.

2. **Bruce Lee/Ms. Pac-Man/JBird/Jumpman (consistent):** These games bypass INT 10h for mode switching. They set text mode via INT 10h (which turns off our emulation), then directly program CGA hardware registers via port I/O. Our TSR never sees the CGA mode set happen. This is a fundamentally different problem requiring port-level interception or BDA polling.

## Next Steps

1. ~~**Test on real VGA hardware** — PRIORITY.~~ DONE — see Real Hardware Testing below
2. ~~**If KQ1 works on real hardware** → DOSBox issue, ignore it~~ CONFIRMED — KQ1 works reliably on all real hardware
3. **If Bruce Lee still broken on real hardware** → add BDA polling in timer tick to detect mode changes made without INT 10h
4. **Try DOSBox-X or DOSBox Staging** — may handle GC reg 6 memory mapping more correctly
5. **Performance optimization** — reduce TSR timer tick consumption (especially for 386-class systems)
6. **Cirrus Logic VLB** — research chip-specific extension registers (GR9-GR11) for potential fix
7. **Tseng ET4000AX** — CONFIRMED chipset limitation (timing/BIOS/cache all ruled out) — see Real Hardware Testing below. Optional: research Tseng extended registers (3D4h index 33h/34h, legacy 3BFh segment switch) as a low-probability fix attempt.

---

## Real Hardware Testing (v0.8c)

### Hardware Compatibility

| System | CPU | VGA Chipset | Bus | Status |
|--------|-----|-------------|-----|--------|
| West PC | 386-40 MHz | Trident TVGA 9000B | ISA | **Works** |
| IBM ThinkPad 390 | Pentium? | NeoMagic NM2200 (MagicMedia 256AV) | Internal | **Works** |
| WIC PC | Pentium 200 MMX | ATI Mach 64 | PCI | **Works** |
| AMD DX4-100 | DX4-100 | Cirrus CL-GD5424 (512KB) | VLB | **Broken** — only moving objects visible |
| AST Advantage 6066d | Pentium ODP 83 MHz | Cirrus CL-GD5428 (1MB) | VLB | **Broken** — only moving objects visible |
| IBM ThinkPad i1411 | ? | NeoMagic NM2160 (MagicGraph 128XD) | Internal | **Works** (v0.9) — crashed on v0.8b shadow buffer |
| West PC | 386-40 MHz | Tseng ET4000AX | ISA | **Broken** — deterministic noise in dithered texture areas (see ET4000AX section below) |

### Cirrus Logic VLB — Root Cause Analysis

Both Cirrus VLB systems (CL-GD5424 and CL-GD5428) show identical symptoms: moving sprites briefly visible, static backgrounds garbled. Four different approaches were tried:

1. **GC6=00 permanent** (v0.8): garbage display — Cirrus display engine misreads chain-4 VRAM with 128K map
2. **No GC6=00** (quick test): white screen — B800h unmapped on VLB (not backed by system RAM)
3. **Shadow + restore GC6 after copy** (v0.8a): black screen — game B800h writes lost when GC6 isn't 00
4. **Shadow + GC6=00 resting** (v0.8b): back to garbage — display engine still sees GC6=00 between conversions

**Conclusion:** Cirrus VLB is a fundamental hardware limitation. GC6=00 is required for B800h access on VLB, but Cirrus cannot render Mode 13h correctly with that setting. Fixing would require Cirrus-specific extension register programming (GR9-GR11) — a separate research project.

### Tseng ET4000AX — Root Cause Analysis

West PC's Trident TVGA 9000B was swapped for a Tseng ET4000AX (same 386-40 MHz system, same ISA slot). CGA2VGA installs fine, but no tested game renders correctly.

**Symptom (Indianapolis 500, `/c1`, mode 6):** Sky, clouds, road surface, cars, and HUD/scoreboard text all render correctly. Only the dithered 1-bit guardrail/embankment texture strips show random color noise ("TV static") instead of a consistent artifact color. This is a different signature than Cirrus VLB (only moving sprites visible, static background garbled) — here flat-color and sharp-edge content is fine, only fine alternating-bit dither patterns are corrupted.

**Eliminated causes (tested in this order):**
1. BIOS "Memory Remapping" (A0000-FFFFF remap to top of RAM) — disabled, no change
2. BIOS "Shadow RAM" (all regions) — disabled, no change
3. Gate A20 Emulation setting — not applicable (all TSR memory access is below 1MB)
4. CPU clock speed 40 MHz → 13 MHz — no change
5. DRAM Wait States 1 → 2 — no change
6. AT Bus Clock 40/3 (13.3 MHz) → 40/8 (5 MHz) — no change
7. CPU cache: `Fast Cache Read/Write Hit` disabled + `Non-Cacheable Block1` enabled over A0000h-BFFFFh (640KB base, 128KB size) — no change

**Conclusion:** Since neither BIOS memory-decode settings nor any CPU/bus/DRAM/cache timing adjustment affected the noise, the corruption is deterministic, not a marginal timing race. This points to the ET4000AX's own display engine mishandling the non-standard GC6=00 (128K memory map) + chain-4 Mode 13h combination that CGA2VGA depends on — the same general class of issue as the Cirrus VLB limitation above, though the specific failure mode (noise in dithered patterns vs. garbled static backgrounds) differs. Treated as a hardware/chipset limitation, not fixable via BIOS configuration. Reverting to the known-working Trident TVGA 9000B card resolves it.

### Game Compatibility — Real Hardware

#### WIC PC (Pentium 200 MMX, ATI Mach 64 PCI)

| Game | Mode | Status | Notes |
|------|------|--------|-------|
| Planet X3 | 6 | **Works** | |
| Hard Hat Mack | 4/5 | **Works** | |
| Kings Quest 1 (`-c`) | 6 | **Works** | |
| Kings Quest 2 | 6 | **Works** | Speed perfect at "Fast" setting |
| Commander Keen 4 | 4/5 | **Works** | |
| Zak McKracken | 4/5 | **Works** | |
| Bruce Lee | 4/5 | **Broken** | Intro works, gameplay black screen |
| Ms. Pac-Man | 4/5 | **Broken** | Crashes |
| California Games | 4/5 | **Broken** | Does not work |

#### West PC (386-40 MHz, Trident TVGA 9000B ISA)

| Game | Mode | Status | Notes |
|------|------|--------|-------|
| Planet X3 | 6 | **Works** | v0.8c: slow audio. **v0.9: music at full speed** |
| Hard Hat Mack | 4/5 | **Works** | v0.9: music and graphics good. VSync ON = no stutter |
| Kings Quest 1 (`-c`) | 6 | **Works** | Sound and graphics OK |
| Kings Quest 2 | 6 | **Works** | Slow music on intro |
| Zak McKracken | 4/5 | **Works** | A bit slow |
| Flight Simulator 3 | 6 | **Works** | v0.9: fastest and best ever |
| NM-Pinball | 4/5 | **Works** | v0.9: works fine |
| Bruce Lee | 4/5 | **Works** | **v0.9: first time working!** VSync ON = slow but correct. VSync OFF = faster but slow |
| Ms. Pac-Man | 4/5 | **Broken** | Crashes |
| Frogger 2 | 4/5 | **Works** | Strange colors — expected; game designed for RGBI CGA, not composite |
| Boulder Dash 1 | 4/5 | **Broken** | Music plays fine, black screen — may use non-standard VRAM layout |

#### IBM ThinkPad i1411 (NeoMagic NM2160) — v0.9
| Game | Mode | Status | Notes |
|------|------|--------|-------|
| Planet X3 | 6 | **Works** | Perfect speed and sound |
| Hard Hat Mack | 4/5 | **Works** | Too fast — game speed not limited by TSR overhead on this CPU |
| Bruce Lee | 4/5 | **Works** | |
| King's Quest 1 | 6 | **Works** | |
| Tapper | 4/5 | **Works** | Music fine, gameplay too fast |
| Boulder Dash 1 | 4/5 | **Broken** | Black screen — music plays fine |

#### IBM ThinkPad 390 (NeoMagic NM2200)
| Game | Mode | Status | Notes |
|------|------|--------|-------|
| Planet X3 | 6 | **Works** | Music at ~80% speed (timer tick consumption) |

### Real Hardware Findings

**KQ1 reliability:** Works 100% of the time on real hardware. The DOSBox randomness was a DOSBox-specific issue.

**KQ1 vs KQ2 speed difference:** Sierra AGI versions use different speed control. Earlier AGI (KQ1, v2) uses CPU-calibrated busy-wait loops — unaffected by timer tick rate, runs at CPU speed. Later AGI (KQ2, v3) uses BIOS timer tick (INT 1Ch) for regulation — TSR consuming ticks effectively slows it down, making "Fast" feel correct.

**Bruce Lee / Ms. Pac-Man / California Games:** These games bypass INT 10h entirely. They set text mode via BIOS (turning off our emulation), then directly program CGA hardware registers (3D4h/3D5h, 3D8h/3D9h) via port I/O to configure custom CGA graphics modes. Our INT 10h hook never sees a CGA mode set.

**Frogger 2 colors:** The green/blue/yellow colors are correct composite artifact recoloring. Frogger 2 was designed for RGBI CGA (cyan/magenta/white palette), not composite. Our TSR reinterprets RGBI pixel patterns as composite artifact colors — inherent limitation for non-composite games.

**386 performance:** Timer tick starvation was the dominant issue in v0.8c. v0.9 fixes this by hooking INT 08h (chain-first) instead of INT 1Ch — the game's sound handler and BIOS tick counter complete before conversion begins. Additional PIT throttle prevents high-frequency timer games (PX3 at 240 Hz) from triggering 100% CPU conversion. Music now plays at full speed on the 386/40. VSync ON adds 0-16ms per frame — some games are too slow with it but none stutter.

**Video BIOS Cacheable BIOS setting:** Does not matter. Controls whether Video BIOS ROM (C0000-C7FFF) is cached in RAM. Only affects INT 10h call speed. TSR hot path reads/writes VRAM (B800h, A000h) which is always uncacheable memory-mapped I/O.
