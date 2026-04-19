; ============================================================================
; CGA-Composite-to-VGA Recolor TSR
; ============================================================================
; Gives CGA games 16 colors on any 386+ VGA system by converting CGA
; framebuffer data to VGA Mode 13h in real time with a lookup table.
;
; Inspired by the Olivetti PC1's zero-overhead hardware trick — the V6355D
; chip mirrors B800h to B000h and reinterprets CGA nibbles as 16-color
; indices. This TSR replicates that trick in software: a timer interrupt
; reads B800h, converts via LUT, and writes to A000h (Mode 13h).
;
; Two fundamentally different CGA graphics modes are intercepted:
;
;   MODE 4/5 (320x200x4, 2bpp):
;     Each byte = 4 pixels at 2 bits each. Each nibble = pixel pair
;     (left*4 + right), giving 16 combinations mapped to 16 colors.
;     Games designed for composite monitors create blended colors via
;     pixel patterns. Non-composite games still work — solid areas
;     display correctly, edges show color fringing.
;
;   MODE 6 (640x200x2, 1bpp):
;     Each byte = 8 pixels at 1 bit. Each nibble = 4 adjacent bits,
;     giving 16 patterns that map 1:1 to the 16 NTSC artifact colors.
;     Games using this mode are ALWAYS using composite artifact color.
;     ~60 games use this: Flight Simulator, Sierra AGI, Planet X3, etc.
;
; The TSR auto-selects the correct palette when a game sets the video mode.
; CTRL+ALT+1..4 overrides the auto-selection at any time.
;
; Requires: 386+ CPU, VGA display adapter
; Recommended: 486+ with VLB/PCI VGA for smooth 60fps operation
;
; Assembly: nasm -f bin CGA2VGA.asm -o CGA2VGA.COM
; Usage:    CGA2VGA.COM           (install)
;           CGA2VGA.COM /U        (uninstall)
;           CTRL+ALT+1..4 during game (switch palettes)
;
; Author: Retro Erik, 2026
;
; License: GNU General Public License v3.0
; Copyright (C) 2026 Retro Erik
;
; This program is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License
; along with this program.  If not, see <https://www.gnu.org/licenses/>.
; ============================================================================

[BITS 16]
[ORG 0x100]
CPU 386                             ; Enable 386 instructions

; ============================================================================
; STARTUP - Jump to main (past resident data)
; ============================================================================
jmp main

; ============================================================================
; CONSTANTS
; ============================================================================
CGA_SEG             equ 0xB800      ; CGA video memory (game writes here)
VGA_SEG             equ 0xA000      ; VGA Mode 13h framebuffer
VGA_MODE_13H        equ 0x13        ; 320x200x256 linear
CGA_MODE_4          equ 0x04        ; Standard CGA 320x200x4
CGA_MODE_5          equ 0x05        ; Standard CGA 320x200x4 (variant)
CGA_MODE_6          equ 0x06        ; CGA 640x200x2 (composite artifact)
NUM_PALETTES        equ 4           ; Total palettes (0..3)
CGA_STATUS_PORT     equ 0x3DA       ; CGA/VGA status register
VGA_DAC_WRITE       equ 0x3C8       ; VGA DAC write address
VGA_DAC_DATA        equ 0x3C9       ; VGA DAC data (R, G, B × 6-bit)

; ============================================================================
; TSR SIGNATURE AND STATE DATA (resident)
; ============================================================================
tsr_id:             db "CGA2VG"     ; 6-byte signature

; Original interrupt vectors (offset first for jmp far [mem])
orig_int10_ofs:     dw 0
orig_int10_seg:     dw 0
orig_int09_ofs:     dw 0
orig_int09_seg:     dw 0
orig_int1c_ofs:     dw 0
orig_int1c_seg:     dw 0

; State
current_mode:       db 0            ; 0=inactive, 4/5/6=CGA mode being emulated
current_palette:    db 0            ; Active palette index (0..3)
current_page:       db 0            ; Reported page (always 0 for CGA)
is_emulating:       db 0            ; 1 = TSR active, converting frames
in_conversion:      db 0            ; Re-entrancy guard for timer handler
mode4_palette_idx:  db 0            ; Default palette for mode 4/5
mode6_palette_idx:  db 1            ; Default palette for mode 6
tick_counter:       db 0            ; Frame skip counter (convert every N ticks)
tick_divider:       db 1            ; 1 = every tick, 2 = every other, etc.

; ============================================================================
; VGA PALETTES — 16 colors × 3 bytes (R, G, B) per palette, 6-bit VGA DAC
; ============================================================================
; Converted from V6355D 3-bit (0-7) to VGA 6-bit (0-63) via: VGA = PC1 × 9
;
; MODE 4/5 (320x200x4): Color index = CGA pixel pair (left*4 + right)
;   Index 0 = (0,0) both background    Index 5 = (1,1) both color 1
;   Index 10 = (2,2) both color 2      Index 15 = (3,3) both color 3
;   Others = artifact blends from adjacent pixel interactions
;
; MODE 6 (640x200x2): Color index = 4 adjacent 1bpp pixels
;   Index 0 = 0000 (all off)           Index 15 = 1111 (all on)

; ────────────────────────────────────────────────────────────────────────────
; Palette 0: CURATED — MODE 4/5 (320x200x4)
; ────────────────────────────────────────────────────────────────────────────
; Hand-picked for 320x200 CGA games. Auto-selected for mode 4/5.
; Best for: KQ1, Bruce Lee, Ms. Pac-Man, Zaxxon, Galaxian
palette_0:
    ;       R    G    B       ; PC1 original (R, G|B)
    db  0,   0,   0          ;  0: Black           (0, 0x00)
    db  0,  27,   0          ;  1: Dark Green       (0, 0x30)
    db  0,   0,  54          ;  2: Blue             (0, 0x06)
    db  0,  45,  54          ;  3: Cyan             (0, 0x56)
    db 36,   0,   0          ;  4: Dark Red         (4, 0x00)
    db 36,  36,  36          ;  5: Dark Grey        (4, 0x44)
    db 36,   0,  36          ;  6: Magenta          (4, 0x04)
    db 18,  18,  63          ;  7: Light Blue       (2, 0x27)
    db 36,  18,   0          ;  8: Brown            (4, 0x20)
    db  9,  63,   9          ;  9: Bright Green     (1, 0x71)
    db 18,  18,  18          ; 10: Grey             (2, 0x22)
    db 18,  63,  63          ; 11: Aqua             (2, 0x77)
    db 63,  18,  45          ; 12: Pink             (7, 0x25)
    db 63,  63,   0          ; 13: Yellow           (7, 0x70)
    db 63,  18,  18          ; 14: Light Red        (7, 0x22)
    db 63,  63,  63          ; 15: White            (7, 0x77)

; ────────────────────────────────────────────────────────────────────────────
; Palette 1: CURATED — MODE 6 (640x200x2 artifact)
; ────────────────────────────────────────────────────────────────────────────
; Hand-picked for 640x200 composite artifact games. Auto-selected for mode 6.
; Confirmed: Indianapolis 500 /c1, Police Quest 2 CGA composite.
palette_1:
    db  0,   0,   0          ;  0: Black           (0, 0x00)
    db  0,  27,   0          ;  1: Dark Green       (0, 0x30)
    db  0,   0,  54          ;  2: Blue             (0, 0x06)
    db  0,  45,  54          ;  3: Cyan             (0, 0x56)
    db 36,   0,   0          ;  4: Dark Red         (4, 0x00)
    db 36,  36,  36          ;  5: Dark Grey        (4, 0x44)
    db 36,   0,  36          ;  6: Purple           (4, 0x04)
    db 18,  18,  63          ;  7: Light Blue       (2, 0x27)
    db 36,  18,   0          ;  8: Brown            (4, 0x20)
    db  9,  63,   9          ;  9: Bright Green     (1, 0x71)
    db 18,  18,  18          ; 10: Dark Grey        (2, 0x22)
    db 18,  63,  63          ; 11: Aqua             (2, 0x77)
    db 63,  18,   0          ; 12: Orange           (7, 0x20)
    db 63,  63,   0          ; 13: Yellow           (7, 0x70)
    db 63,  27,  54          ; 14: Hot Pink         (7, 0x36)
    db 63,  63,  63          ; 15: White            (7, 0x77)

; ────────────────────────────────────────────────────────────────────────────
; Palette 2: REFERENCE — MODE 4/5 (New CGA model-generated)
; ────────────────────────────────────────────────────────────────────────────
; Generated from reenigne's New CGA composite model. Reference baseline.
palette_2:
    db  0,   0,   0          ;  0: Black            [BB]
    db  0,  18,  63          ;  1: Electric Blue    [BC]
    db  9,   0,  36          ;  2: Deep Violet      [BM]
    db  0,  18,  63          ;  3: Electric Blue    [BW]
    db  9,   9,   0          ;  4: Dark Olive       [CB]
    db  9,  27,  36          ;  5: Steel Cyan       [CC]
    db 18,   9,  18          ;  6: Muted Mauve      [CM]
    db  9,  27,  54          ;  7: Sky Blue         [CW]
    db 27,   0,   0          ;  8: Dark Red         [MB]
    db 27,  18,  54          ;  9: Indigo Blue      [MC]
    db 36,   0,  27          ; 10: Plum             [MM]
    db 27,  18,  63          ; 11: Periwinkle       [MW]
    db 36,  27,   0          ; 12: Ochre            [WB]
    db 36,  36,  27          ; 13: Khaki            [WC]
    db 45,  18,   0          ; 14: Orange Brown     [WM]
    db 45,  45,  45          ; 15: Light Gray       [WW]

; ────────────────────────────────────────────────────────────────────────────
; Palette 3: NERDLY PLEASURES REFERENCE — MODE 6 (640x200x2)
; ────────────────────────────────────────────────────────────────────────────
; Straight reproduction of the 16 NTSC artifact colors from the Nerdly
; Pleasures color palette chart (New CGA). No adjustments.
palette_3:
    db  0,   0,   0          ;  0: Black           (0, 0x00)
    db  0,  27,   0          ;  1: Dark Green       (0, 0x30)
    db  0,   0,  54          ;  2: Blue             (0, 0x06)
    db  0,  45,  54          ;  3: Cyan             (0, 0x56)
    db 45,   0,   9          ;  4: Crimson          (5, 0x01)
    db 27,  18,  18          ;  5: Dark Brown Grey  (3, 0x22)
    db 45,   0,  54          ;  6: Magenta          (5, 0x06)
    db 45,  27,  63          ;  7: Violet           (5, 0x37)
    db 27,  27,  27          ;  8: Dark Grey        (3, 0x33)
    db  9,  63,   9          ;  9: Bright Green     (1, 0x71)
    db 45,  45,  27          ; 10: Light Brown Grey (5, 0x53)
    db 18,  63,  63          ; 11: Bright Cyan      (2, 0x77)
    db 63,  18,   0          ; 12: Scarlet          (7, 0x20)
    db 63,  63,   9          ; 13: Yellow           (7, 0x71)
    db 63,  27,  54          ; 14: Hot Pink         (7, 0x36)
    db 63,  63,  63          ; 15: White            (7, 0x77)

; Palette pointer table
palette_table:
    dw palette_0
    dw palette_1
    dw palette_2
    dw palette_3

; ============================================================================
; LOOKUP TABLE — 256 entries × 4 bytes = 1024 bytes
; ============================================================================
; For each possible CGA byte (0x00-0xFF), stores 4 VGA pixel bytes.
; In modes 4/5: each nibble = pixel-pair color (high nibble = left pair,
;   low nibble = right pair). Each pair color is doubled horizontally:
;   CGA byte → 4 VGA pixels (2 left + 2 right) = 4 bytes.
; In mode 6: identical interpretation — each nibble = artifact color index,
;   doubled to 2 pixels each.
;
; LUT entry format: byte0 byte1 byte2 byte3
;   byte0 = high_nibble (left pixel, first copy)
;   byte1 = high_nibble (left pixel, second copy = pixel doubling)
;   byte2 = low_nibble  (right pixel, first copy)
;   byte3 = low_nibble  (right pixel, second copy = pixel doubling)
;
; The LUT is built at install time by build_lut.

lut:    times 1024 db 0             ; 256 × 4 bytes, zeroed initially

; ============================================================================
; INT 10h HANDLER — Intercept video mode changes
; ============================================================================
tsr_int10:
    cmp ah, 0x00                    ; AH=00h: Set video mode?
    je .set_mode

    ; AH=05h: Set active page — track it
    cmp ah, 0x05
    jne .not_set_page
    cmp byte [cs:is_emulating], 1
    jne .chain
    mov [cs:current_page], al
    iret

.not_set_page:
    ; AH=0Fh: Get current video mode — report the CGA mode, not 13h
    cmp ah, 0x0F
    jne .not_get_mode
    cmp byte [cs:is_emulating], 1
    jne .chain
    mov al, [cs:current_mode]       ; AL = faked CGA mode
    mov ah, 80                      ; AH = columns (CGA standard)
    mov bh, [cs:current_page]       ; BH = active page
    iret

.not_get_mode:
    ; Fall through to original for all other functions

.chain:
    jmp far [cs:orig_int10_ofs]

; ────────────────────────────────────────────────────────────────────────────
; AH=00h: Set video mode
; ────────────────────────────────────────────────────────────────────────────
.set_mode:
    push bx
    mov bl, al
    and bl, 0x7F                    ; Strip "don't clear" bit 7

    cmp bl, CGA_MODE_4
    je .mode_cga
    cmp bl, CGA_MODE_5
    je .mode_cga
    cmp bl, CGA_MODE_6
    je .mode_cga
    pop bx

    ; Non-CGA mode: deactivate emulation, pass through
    mov byte [cs:is_emulating], 0
    jmp far [cs:orig_int10_ofs]

.mode_cga:
    mov [cs:current_mode], bl       ; Save clean mode number
    mov byte [cs:current_page], 0
    pop bx                          ; Restore caller's BX (balances push in .set_mode)

    ; AL still has original mode byte including bit 7 (don't-clear flag).
    ; Save it — palette code below will overwrite AL, and BIOS calls
    ; will clobber most registers. We need bit 7 after all the calls.
    push ax                         ; *** Original AX saved on stack ***

    ; Auto-select palette for this mode
    cmp byte [cs:current_mode], CGA_MODE_6
    je .auto_mode6
    mov al, [cs:mode4_palette_idx]
    jmp short .auto_apply
.auto_mode6:
    mov al, [cs:mode6_palette_idx]
.auto_apply:
    mov [cs:current_palette], al

    ; ── Step 1: Set the actual CGA mode via BIOS FIRST ─────────────────
    ; Critical: DOSBox (and some real BIOSes) won't properly initialize
    ; B800h CGA memory until a CGA mode has been set. Without this,
    ; the game writes to B800h but it isn't wired up, and the TSR's
    ; timer-tick conversion reads garbage or the system hangs.
    mov ah, 0x00
    mov al, [cs:current_mode]       ; The actual CGA mode (4/5/6)
    or al, 0x80                     ; Bit 7 = don't clear (we'll handle clearing)
    pushf
    call far [cs:orig_int10_ofs]    ; BIOS initializes CGA hardware + B800h

    ; ── Step 2: Now switch to VGA Mode 13h for our output ──────────────
    mov ax, VGA_MODE_13H            ; AH=00h, AL=13h
    or al, 0x80                     ; Don't clear A000h (we clear B800h ourselves)
    pushf
    call far [cs:orig_int10_ofs]    ; BIOS sets Mode 13h (display at A000h)

    ; ── Step 3: Patch BIOS data area to report CGA mode ────────────────
    ; Games that read 0040:0049 directly (instead of using INT 10h/0Fh)
    ; would see mode 13h and crash or take a wrong code path.
    push es
    mov ax, 0x0040
    mov es, ax
    mov al, [cs:current_mode]
    mov [es:0x0049], al             ; Current video mode → CGA 4/5/6
    mov word [es:0x004A], 40        ; Screen columns (40 for CGA graphics)
    mov word [es:0x004C], 0x4000    ; Page size (16KB, standard CGA)
    mov word [es:0x0063], 0x03D4    ; CRTC base I/O port (color)
    pop es

    ; ── Step 4: Set up emulation ───────────────────────────────────────
    call load_vga_palette
    call build_lut
    mov byte [cs:is_emulating], 1
    mov byte [cs:in_conversion], 0

    ; ── Step 5: Clear if requested ─────────────────────────────────────
    ; Original mode byte is still on the stack from the push ax above.
    pop ax                          ; *** Restore original AX ***
    test al, 0x80                   ; Was "don't clear" flag set?
    jnz .skip_clear
    call clear_cga_vram             ; Clear B800h (games expect blank screen)
    ; Also clear A000h so first frame isn't stale Mode 13h garbage
    call clear_vga_vram
.skip_clear:
    iret

; ============================================================================
; LOAD VGA DAC PALETTE (entries 0-15)
; ============================================================================
; Programs the VGA DAC with 16 colors from the selected palette.
; VGA DAC: write index to port 3C8h, then 3 bytes (R,G,B 6-bit) to 3C9h.

load_vga_palette:
    push ax
    push bx
    push cx
    push si

    ; Get pointer to selected palette
    xor bx, bx
    mov bl, [cs:current_palette]
    shl bx, 1                      ; Word index
    mov si, [cs:palette_table + bx]

    ; Start writing at DAC index 0
    mov dx, VGA_DAC_WRITE           ; Port 3C8h
    xor al, al
    out dx, al

    ; Write 16 colors × 3 bytes each
    mov dx, VGA_DAC_DATA            ; Port 3C9h
    mov cx, 16
.pal_loop:
    mov al, [cs:si]                 ; Red
    out dx, al
    mov al, [cs:si+1]              ; Green
    out dx, al
    mov al, [cs:si+2]              ; Blue
    out dx, al
    add si, 3
    loop .pal_loop

    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; BUILD LUT — Generate the 256-entry conversion table
; ============================================================================
; For each byte value 0x00-0xFF:
;   high nibble → color index → doubled pixel
;   low nibble  → color index → doubled pixel
; Result: 4 bytes per entry (pixel-doubled pairs)

build_lut:
    push ax
    push bx
    push cx
    push di

    xor bx, bx                     ; BX = byte value 0-255
    xor di, di                     ; DI = LUT offset (bx * 4)
.build_loop:
    ; High nibble → left pixel pair (doubled)
    mov al, bl
    shr al, 4                      ; AL = high nibble (0-15)
    mov [cs:lut + di + 0], al      ; Pixel 0 (left, first)
    mov [cs:lut + di + 1], al      ; Pixel 1 (left, doubled)

    ; Low nibble → right pixel pair (doubled)
    mov al, bl
    and al, 0x0F                   ; AL = low nibble (0-15)
    mov [cs:lut + di + 2], al      ; Pixel 2 (right, first)
    mov [cs:lut + di + 3], al      ; Pixel 3 (right, doubled)

    add di, 4
    inc bx
    cmp bx, 256
    jb .build_loop

    pop di
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; CLEAR CGA VRAM (B800:0000, 16KB)
; ============================================================================
clear_cga_vram:
    push ax
    push cx
    push di
    push es

    mov ax, CGA_SEG
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 8192                    ; 16384 bytes = 8192 words
    cld
    rep stosw

    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; CLEAR VGA VRAM (A000:0000, 64KB)
; ============================================================================
clear_vga_vram:
    push ax
    push cx
    push di
    push es

    mov ax, VGA_SEG
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 32000                   ; 64000 bytes = 32000 words (320×200)
    cld
    rep stosw

    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; INT 1Ch HANDLER — Timer tick: CGA → VGA framebuffer conversion
; ============================================================================
; Called ~18.2 times/sec by the system timer. When emulation is active,
; reads the CGA framebuffer at B800h, converts via LUT, and writes
; to the VGA Mode 13h framebuffer at A000h.
;
; CGA memory layout (interlaced):
;   Even scanlines (0,2,4...198): B800:0000 to B800:1F3F  (100 × 80 bytes)
;   Odd scanlines  (1,3,5...199): B800:2000 to B800:3F3F  (100 × 80 bytes)
;
; VGA Mode 13h layout (linear):
;   Scanline N starts at A000:(N × 320)

tsr_int1c:
    ; Quick check: are we active?
    cmp byte [cs:is_emulating], 1
    jne .timer_chain

    ; Re-entrancy guard: don't nest if previous conversion still running
    cmp byte [cs:in_conversion], 0
    jne .timer_chain

    ; Frame skip: only convert every N ticks
    inc byte [cs:tick_counter]
    mov al, [cs:tick_counter]
    cmp al, [cs:tick_divider]
    jb .timer_chain
    mov byte [cs:tick_counter], 0

    ; Set guard and do the conversion
    mov byte [cs:in_conversion], 1
    sti                             ; Allow other interrupts during conversion

    call convert_frame

    mov byte [cs:in_conversion], 0

.timer_chain:
    jmp far [cs:orig_int1c_ofs]

; ============================================================================
; CONVERT FRAME — The main CGA → VGA conversion engine
; ============================================================================
; Reads 200 scanlines from CGA VRAM (interlaced), converts each byte
; through the LUT, and writes to VGA Mode 13h (linear).
;
; Uses 386 32-bit registers for performance (EAX, ESI, EDI, EBX, ECX).

convert_frame:
    pushad                          ; Save all 32-bit registers
    push ds
    push es

    ; DS = CGA segment (B800h), ES = VGA segment (A000h)
    mov ax, CGA_SEG
    mov ds, ax
    mov ax, VGA_SEG
    mov es, ax

    ; EBX = LUT base address (in CS segment — we'll use CS override)
    ; Actually, LUT is in our code segment. We need CS: overrides for
    ; the LUT reads. For simplicity, copy LUT pointer approach:
    ; We'll keep track of LUT offset in EBX.

    ; Wait for vertical retrace start to reduce tearing.
    ; Uses a timeout counter — if VBlank never arrives (DOSBox quirk,
    ; weird video state), we proceed anyway instead of hanging forever.
    mov dx, CGA_STATUS_PORT         ; 0x3DA
    mov cx, 0                       ; Timeout: 65536 iterations
.wait_no_vblank:
    in al, dx
    test al, 0x08                   ; Bit 3 = vertical retrace
    jz .vblank_ended                ; Not in retrace — good, move on
    dec cx
    jnz .wait_no_vblank
    jmp short .do_convert           ; Timeout — skip sync, convert anyway
.vblank_ended:
    mov cx, 0                       ; Reset timeout for second wait
.wait_vblank:
    in al, dx
    test al, 0x08
    jnz .do_convert                 ; Retrace started — go convert now
    dec cx
    jnz .wait_vblank
    ; Timeout — convert anyway (better torn than frozen)
.do_convert:

    ; ── Convert all 200 scanlines ──────────────────────────────────────
    ; Row counter in BP (0..199)
    xor bp, bp                      ; BP = current row

.row_loop:
    ; Calculate CGA source offset for this row
    ; Even rows: offset = (row / 2) × 80
    ; Odd rows:  offset = 0x2000 + (row / 2) × 80
    mov si, bp
    shr si, 1                       ; SI = row / 2
    imul si, si, 80                 ; SI = (row/2) * 80   [186+ instruction]
    test bp, 1                      ; Odd row?
    jz .even_row
    add si, 0x2000                  ; Odd bank offset
.even_row:

    ; Calculate VGA destination offset: row × 320
    mov di, bp
    imul di, di, 320                ; DI = row * 320   [186+ instruction]

    ; Convert 80 CGA bytes → 320 VGA bytes via LUT
    ; Inner loop: 20 iterations × 4 bytes = 80 bytes per row
    mov cx, 20                      ; 20 iterations of 4 bytes each

.inner_loop:
    ; Byte 0
    xor eax, eax
    mov al, [si]                    ; AL = CGA byte
    mov eax, [cs:lut + eax*4]      ; 4 VGA pixels from LUT
    mov [es:di], eax                ; Write 4 pixels
    ; Byte 1
    xor eax, eax
    mov al, [si+1]
    mov eax, [cs:lut + eax*4]
    mov [es:di+4], eax
    ; Byte 2
    xor eax, eax
    mov al, [si+2]
    mov eax, [cs:lut + eax*4]
    mov [es:di+8], eax
    ; Byte 3
    xor eax, eax
    mov al, [si+3]
    mov eax, [cs:lut + eax*4]
    mov [es:di+12], eax

    add si, 4
    add di, 16
    dec cx
    jnz .inner_loop

    ; Next row
    inc bp
    cmp bp, 200
    jb .row_loop

    pop es
    pop ds
    popad                           ; Restore all 32-bit registers
    ret

; ============================================================================
; INT 09h HANDLER — Keyboard: CTRL+ALT+1..4 palette switching
; ============================================================================
tsr_int09:
    push ax
    push ds

    ; Read scancode
    in al, 0x60

    ; Only care about make codes 0x02-0x05 (keys '1' through '4')
    cmp al, 0x02
    jb .kbd_chain
    cmp al, 0x05
    ja .kbd_chain

    ; Check BIOS keyboard flags at 0040:0017
    ; Bit 2 = Ctrl held, Bit 3 = Alt held
    push bx
    mov bx, 0x0040
    mov ds, bx
    mov ah, [0x0017]
    pop bx

    and ah, 0x0C                    ; Isolate Ctrl+Alt
    cmp ah, 0x0C                    ; Both held?
    jne .kbd_chain

    ; Only switch if emulating
    cmp byte [cs:is_emulating], 1
    jne .kbd_chain

    ; AL = 0x02..0x05 → palette 0..3
    sub al, 0x02
    mov [cs:current_palette], al

    ; Save to mode-specific default
    cmp byte [cs:current_mode], CGA_MODE_6
    jne .save_m4
    mov [cs:mode6_palette_idx], al
    jmp short .do_reload
.save_m4:
    mov [cs:mode4_palette_idx], al
.do_reload:
    ; Reload palette and rebuild LUT
    call load_vga_palette
    call build_lut

    ; Acknowledge keystroke to keyboard controller
    in al, 0x61
    or al, 0x80
    out 0x61, al
    and al, 0x7F
    out 0x61, al

    ; Send EOI to PIC
    mov al, 0x20
    out 0x20, al

    pop ds
    pop ax
    iret                            ; Consume keystroke

.kbd_chain:
    pop ds
    pop ax
    jmp far [cs:orig_int09_ofs]

; ============================================================================
; END OF RESIDENT CODE
; ============================================================================
; Everything below this point is only needed during installation and can
; be discarded after the TSR goes resident.

resident_end:

; ============================================================================
; MAIN ENTRY POINT — Install or Uninstall
; ============================================================================
main:
    ; Print banner
    mov dx, msg_banner
    mov ah, 0x09
    int 0x21

    ; Check for 386+ CPU
    call check_386
    jnc .cpu_ok
    mov dx, msg_need_386
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21

.cpu_ok:
    ; Check for VGA
    call check_vga
    jnc .vga_ok
    mov dx, msg_need_vga
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C01
    int 0x21

.vga_ok:
    ; Parse command line for /U
    mov si, 0x81                    ; Command line starts at PSP:81h
    mov cl, [0x80]                  ; Length
    xor ch, ch
.scan_args:
    jcxz .no_unload
    lodsb
    dec cx
    cmp al, '/'
    je .check_u
    cmp al, '-'
    je .check_u
    jmp .scan_args

.check_u:
    jcxz .no_unload
    lodsb
    dec cx
    or al, 0x20                     ; Lowercase
    cmp al, 'u'
    je .do_unload
    jmp .scan_args

.no_unload:
    ; Check if already installed
    call check_already_installed
    jnc .do_install
    mov dx, msg_already
    mov ah, 0x09
    int 0x21
    mov ax, 0x4C00
    int 0x21

.do_install:
    call install_tsr
    ; (install_tsr does not return — it goes resident)

.do_unload:
    call unload_tsr
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; CHECK 386+ CPU
; ============================================================================
; Sets CF if less than 386.
check_386:
    pushf
    ; Try to set bits 12-15 of FLAGS — only works on 386+
    pushf
    pop ax
    or ax, 0xF000
    push ax
    popf
    pushf
    pop ax
    popf
    test ax, 0xF000
    jz .not_386
    clc
    ret
.not_386:
    stc
    ret

; ============================================================================
; CHECK VGA PRESENT
; ============================================================================
; Uses INT 10h/AX=1A00h (Get Display Combination Code).
; Sets CF if VGA not detected.
check_vga:
    push bx
    mov ax, 0x1A00
    int 0x10
    cmp al, 0x1A                    ; Function supported?
    jne .no_vga
    cmp bl, 7                       ; BL >= 7 means VGA or better
    jb .no_vga
    pop bx
    clc
    ret
.no_vga:
    pop bx
    stc
    ret

; ============================================================================
; CHECK IF ALREADY INSTALLED
; ============================================================================
; Reads INT 10h vector, checks for our signature. Sets CF if found.
check_already_installed:
    push es
    push bx
    push cx
    push si
    push di

    mov ax, 0x3510
    int 0x21                        ; ES:BX = current INT 10h handler

    mov si, tsr_id
    mov di, si                      ; Same offset in both segments
    mov cx, 6
    repe cmpsb

    pop di
    pop si
    pop cx
    pop bx
    pop es
    je .found
    clc
    ret
.found:
    stc
    ret

; ============================================================================
; INSTALL TSR
; ============================================================================
install_tsr:
    ; Save and hook INT 10h
    mov ax, 0x3510
    int 0x21
    mov [orig_int10_seg], es
    mov [orig_int10_ofs], bx
    mov ax, 0x2510
    mov dx, tsr_int10
    int 0x21

    ; Save and hook INT 09h (keyboard)
    mov ax, 0x3509
    int 0x21
    mov [orig_int09_seg], es
    mov [orig_int09_ofs], bx
    mov ax, 0x2509
    mov dx, tsr_int09
    int 0x21

    ; Save and hook INT 1Ch (user timer tick)
    mov ax, 0x351C
    int 0x21
    mov [orig_int1c_seg], es
    mov [orig_int1c_ofs], bx
    mov ax, 0x251C
    mov dx, tsr_int1c
    int 0x21

    ; Pre-build the default LUT (palette 0) so it's ready
    call build_lut

    ; Print success
    mov dx, msg_installed
    mov ah, 0x09
    int 0x21

    ; Terminate and stay resident
    ; Resident size = from PSP (0) to resident_end, in paragraphs
    mov ax, 0x3100                  ; AH=31h, AL=return code 0
    mov dx, (resident_end - $$ + 256 + 15) / 16
    int 0x21

; ============================================================================
; UNLOAD TSR
; ============================================================================
unload_tsr:
    push es

    ; Find the installed TSR via INT 10h vector
    mov ax, 0x3510
    int 0x21                        ; ES:BX = current handler

    ; Verify signature
    push cx
    push si
    push di
    mov si, tsr_id
    mov di, si
    mov cx, 6
    repe cmpsb
    pop di
    pop si
    pop cx
    jne .not_found

    ; Restore INT 10h from TSR's saved values
    mov ax, 0x2510
    mov dx, [es:orig_int10_ofs]
    push ds
    mov bx, [es:orig_int10_seg]
    mov ds, bx
    int 0x21
    pop ds

    ; Restore INT 09h
    mov ax, 0x2509
    mov dx, [es:orig_int09_ofs]
    push ds
    mov bx, [es:orig_int09_seg]
    mov ds, bx
    int 0x21
    pop ds

    ; Restore INT 1Ch
    mov ax, 0x251C
    mov dx, [es:orig_int1c_ofs]
    push ds
    mov bx, [es:orig_int1c_seg]
    mov ds, bx
    int 0x21
    pop ds

    ; Free TSR memory
    mov ah, 0x49
    int 0x21

    ; If a game is still in Mode 13h, restore text mode
    mov ax, 0x0003                  ; Set mode 3 (80x25 text)
    int 0x10

    mov dx, msg_unloaded
    mov ah, 0x09
    int 0x21

    pop es
    ret

.not_found:
    mov dx, msg_not_found
    mov ah, 0x09
    int 0x21
    pop es
    ret

; ============================================================================
; MESSAGES (non-resident — discarded after install)
; ============================================================================
msg_banner:
    db 13, 10
    db "CGA-to-VGA Recolor TSR v0.1 - by Retro Erik 2026", 13, 10
    db "Gives CGA games 16 colors on any VGA system", 13, 10
    db "$"

msg_installed:
    db 13, 10
    db "Installed. Run a CGA game (mode 4/5/6) to see colors.", 13, 10
    db "CTRL+ALT+1: Mode 4/5 curated    (auto for 320x200)", 13, 10
    db "CTRL+ALT+2: Mode 6 curated      (auto for 640x200)", 13, 10
    db "CTRL+ALT+3: Mode 4/5 reference   (reenigne model)", 13, 10
    db "CTRL+ALT+4: Mode 6 reference     (Nerdly Pleasures)", 13, 10
    db 13, 10
    db "CGA2VGA /U to uninstall", 13, 10
    db "$"

msg_already:
    db "Already installed.", 13, 10, "$"

msg_unloaded:
    db "Unloaded.", 13, 10, "$"

msg_not_found:
    db "Error: TSR not found.", 13, 10, "$"

msg_need_386:
    db "Error: Requires 386+ CPU.", 13, 10, "$"

msg_need_vga:
    db "Error: Requires VGA display.", 13, 10, "$"
