# XEP80 API

A low-level 6502 assembler API for the XEP80 80-column video device on Atari 8-bit computers. Provides direct subroutine access to the XEP80 without going through CIO or installing an OS handler.

Multiple XEP80 devices can be attached simultaneously (one per joystick port). `SELDEV` switches the active device at any time.

## Files

| File | Description |
|---|---|
| `xep80api.asm` | The API — include this in your program |
| `xep80hello.asm` | Demo: probe all ports, print status info on each XEP80 found |

## Requirements

- [ATasm](https://atasm.sourceforge.net/) 1.30 or later (MAC/65 compatible cross-assembler)

## Hardware

The XEP80 connects to a **joystick port** via the PIA. It uses a serial bit-bang protocol at approximately 15.7 kbps — 1 start bit, 8 data bits LSB-first, 1 stop bit.

| Port | TOGGLE | PIA register | Input mask | Output mask |
|---|---|---|---|---|
| Joystick port 1 | 0 | PORTA ($D300) | $02 | $01 |
| Joystick port 2 | 1 | PORTA ($D300) | $20 | $10 |
| Joystick port 3 | 2 | PORTB ($D301) | $02 | $01 |
| Joystick port 4 | 3 | PORTB ($D301) | $20 | $10 |

Ports 3 and 4 (PORTB) are **only available on the Atari 400/800**. On the 800XL, 600XL, and 130XE, PORTB controls memory banking — do not use `TOGGLE` values 2 or 3 on those machines.

---

## Using the API

### 1. Set the load address

Open `xep80api.asm` and change the `BASE` equate to where you want the API to live in memory. The default is `$6000`.

```asm
BASE=$6000
```

> **Page boundary constraint:** The first 256 bytes from `BASE` contain all timing-critical serial I/O loops. Choose `BASE` so that the API starts at the beginning of a 256-byte page (e.g. `$6000`, `$6100`, `$7000`). A misaligned `BASE` will cause branch timing errors in the serial code.

### 2. Include the API in your program

Place `.INCLUDE "xep80api.asm"` at the top of your source file. The API assembles to its own block starting at `BASE`; your code follows at whatever address you set afterward.

```asm
 .INCLUDE "xep80api.asm"   ; assembled at BASE ($6000)

 *= $6300                  ; your program starts here (after the API block)

START
 JSR JINIT
 ...
 .END
```

### 3. Build

```
atasm yourprogram.asm
```

---

## Initialization

### Single XEP80

Call `JINIT` once before using any other routine. It configures the PIA for the port selected by `TOGGLE` (default 0 = port 1) and patches the port register address into the timing-critical serial routines.

After `JINIT`, reset the XEP80 with `RST80`. The standard detection loop probes each port in turn until the device responds:

```asm
 JSR JINIT        ; configure port 1

DETECT
 JSR DISAB
 LDA #RST80
 JSR CINP         ; send reset, wait for response
 JSR ENAB         ; restores interrupts (carry from CINP preserved)
 BCC READY        ; C=0: XEP80 responded
 JSR JTOGL        ; C=1: timeout — advance to next port
 JMP DETECT

READY
 ...
```

`ENAB` does not modify the carry flag, so the `BCC` correctly tests the result of `CINP`. `JTOGL` detects the machine type automatically: on a 400/800 it cycles all four ports (0→1→2→3→0); on XL/XE it cycles only ports 0 and 1 (0→1→0), skipping PORTB.

### Multiple XEP80 devices

Use `SELDEV` to switch the active XEP80. Pass the port number (0–3) in A. On success (C=0), `SELDEV` stores it in `TOGGLE` and calls `JINIT`. On XL/XE machines, requesting ports 2 or 3 (PORTB) returns C=1 with `TOGGLE` unchanged.

```asm
 ; Switch to the XEP80 on port 3 and send a character (400/800 only)
 LDA #02          ; port 3 = TOGGLE value 2
 JSR SELDEV       ; configure port 3 as active device
 BCS NOTAVAIL     ; C=1: XL/XE machine, PORTB forbidden
 JSR DISAB
 LDA #'A'
 JSR OUTPUT
 JSR INPUT
 JSR CURCK
 JSR ENAB
NOTAVAIL
```

You can switch between devices as often as needed; each successful `SELDEV` or `JINIT` call fully reconfigures the serial layer for the selected port.

---

## Interrupt discipline

All serial transfers are time-critical. Interrupts **must be disabled** across every send/receive sequence and **re-enabled** immediately after.

```asm
 JSR DISAB    ; disable NMI + IRQ
 ...          ; CMD / OUTPUT / CINP / INPUT calls here
 JSR ENAB     ; re-enable NMI + IRQ
```

`DISAB`, `CMD`, `OUTPUT`, `CINP`, and `INPUT` may all be called with interrupts already disabled — just ensure `ENAB` is called once for every `DISAB`.

---

## Sending a character

Use `PUTCHR` (A = character) to send a single character with all interrupt discipline handled internally:

```asm
 LDA #'A'
 JSR PUTCHR
```

`PUTCHR` disables interrupts, sends the character via `OUTPUT`, reads the cursor update via `INPUT` and `CURCK`, then re-enables interrupts with a tail-call to `ENAB`. `ENAB`'s `RTS` returns directly to your caller.

## Printing a string

`PUTS` prints an ATASCII EOL-terminated (`$9B`) string. Pass the string address as A (low byte) and Y (high byte). The terminating EOL is sent to the XEP80, advancing the cursor to the next line:

```asm
 LDA #<MESSAGE
 LDY #>MESSAGE
 JSR PUTS

MESSAGE .BYTE "HELLO, WORLD",$9B
```

`PUTS` uses the two-byte zero-page pointer `STRPTR` ($CB/$CC) internally. Reserve these two bytes in your own program. The pointer is updated as characters are sent, so `STRPTR` points past the EOL on return.

---

## Sending a command

Use `CMD` when you need to send an XEP80 control byte without a following character. Wrap it in `DISAB`/`ENAB`:

```asm
 JSR DISAB
 LDA #CLR80       ; clear screen command
 JSR CMD
 JSR ENAB
```

## Sending a command and receiving a response

Some XEP80 commands return a response byte (e.g. `GET80`, `RST80`, `CLR80`, `CUR80`). Use `CINP` for these — it sends the command and then waits for the response in one call:

```asm
 JSR DISAB
 LDA #CLR80
 JSR CINP         ; sends CLR80, blocks until XEP80 replies
 JSR ENAB         ; A = response byte, C=0 success / C=1 timeout
```

---

## Cursor positioning

The XEP80 maintains its own cursor position. The API tracks it locally in `VCP` (row) and `HCP` (column), which are standard Atari OS zero-page locations. After any `INPUT` or `CINP` call, `VCP` and `HCP` are updated automatically from the cursor packets the XEP80 sends back.

### Moving the cursor

Write the desired position to `VCP` and `HCP`, then call `ALIGN`. `ALIGN` compares each value against its shadow copy (`VCS`, `HCS`) and only sends cursor commands to the XEP80 when a value has actually changed — so it is safe to call before every character if needed.

```asm
 LDA #05
 STA VCP          ; row 5
 LDA #20
 STA HCP          ; column 20
 JSR DISAB
 JSR ALIGN        ; sends YCR80 and column commands to XEP80
 JSR ENAB
```

### Setting margins

`ALIGN` also handles `LMARGN` (left margin) and `RMARGN` (right margin). Write the margin values as column numbers (0–79) and call `ALIGN`:

```asm
 LDA #00
 STA LMARGN
 LDA #79
 STA RMARGN
 JSR DISAB
 JSR ALIGN
 JSR ENAB
```

### Reading the cursor

`READ` requests the character at the current cursor position from the XEP80 and handles all interrupt discipline internally:

```asm
 JSR READ         ; returns A = char, C=0 ok / C=1 timeout, Y=1
```

---

## Graphics mode

`GRPH` switches the active XEP80 to graphics mode and `TEXT` returns it to normal text mode:

```asm
 JSR GRPH    ; enter graphics mode
 ...
 JSR TEXT    ; return to text mode
```

### Display layout in graphics mode

The display is organised as **80 columns × 25 rows** of cells, identical to text mode. Each cell stores one byte representing **eight horizontal pixels**: bit 7 is the leftmost pixel, bit 0 is the rightmost. The effective horizontal resolution is 640 pixels. Vertical resolution depends on the XEP80's video timing (typically 8 or 9 scan lines per cell row).

### Setting and reading pixels

`SETPX` sets one pixel; `GETPX` reads one pixel. Both take the same inputs:

- **A** = column (0–79) — which group of 8 pixels across
- **X** = row (0–24) — which cell row down
- **Y** = bitmask — which pixel within the column:

| Y value | Pixel position in column |
|---|---|
| $80 | leftmost (pixel 0) |
| $40 | pixel 1 |
| $20 | pixel 2 |
| $10 | pixel 3 |
| $08 | pixel 4 |
| $04 | pixel 5 |
| $02 | pixel 6 |
| $01 | rightmost (pixel 7) |

`SETPX` does a read-modify-write so it never disturbs the other seven pixels in the same cell. `GETPX` returns C=0 if the pixel is clear, C=1 if it is set; carry survives the return because `ENAB` does not modify it.

### Converting pixel coordinates

For a pixel at screen position (px\_x, px\_y) assuming 8 scan lines per row:

```asm
; column = px_x / 8        (0-79)
; row    = px_y / 8        (0-24)
; mask   = $80 >> (px_x & 7)

 LDA #(PX_X/8)
 LDX #(PX_Y/8)
 LDY #($80>>(PX_X&7))
 JSR SETPX
```

ATasm evaluates constant expressions at assemble time, so this works for literal coordinates. For runtime-computed coordinates, shift $80 right by the low three bits of x in a small loop, or keep a precomputed bitmask table.

---

## API Reference

### Subroutines

#### `XLCHK` — Detect machine type
Reads the PORTB data direction register (DDRB) to distinguish Atari 400/800 from XL/XE. On XL/XE the OS configures PORTB output bits for memory banking (DDRB ≠ 0); on 400/800 DDRB stays 0 after boot. The result is cached in `MACHTYPE` after the first call, so subsequent calls are cheap. Must be called before any code has configured PORTB direction on a 400/800 — which is guaranteed when called through `SELDEV` or `JTOGL` at program startup.
- Returns: C=0 = Atari 400/800 (PORTB safe); C=1 = Atari XL/XE (PORTB is memory banking)
- Clobbers: A

#### `SELDEV` — Select active XEP80
Sets `TOGGLE` to the port number in A (0–3) and calls `JINIT`. On XL/XE machines, ports 2 and 3 (which use PORTB) are refused: returns C=1 without changing `TOGGLE` or calling `JINIT`.
- Input: A = port number (0=port 1, 1=port 2, 2=port 3, 3=port 4)
- Returns: C=0 success; C=1 = XL/XE machine, PORTB forbidden (TOGGLE unchanged)
- Clobbers: A, X, Y

#### `JINIT` — Initialize port
Configures the PIA for the port selected by `TOGGLE`. Sets `INMSK` and `OUTMS` from the mask tables and patches the port register address (`$D300` or `$D301`) into the `SEND` and `INPUT` routines using self-modifying code. Must be called once before any other routine, and after every successful `SELDEV` or `JTOGL` call.
- Returns: C=0
- Clobbers: A, X, Y

#### `JTOGL` — Advance to next port and reinitialize
On Atari 400/800: increments `TOGGLE` modulo 4 (0→1→2→3→0). On Atari XL/XE: toggles between 0 and 1 only, skipping ports 2 and 3 (PORTB). Machine type is detected automatically via `XLCHK`. Falls through to `SELDEV`/`JINIT`.
- Clobbers: A, X, Y

#### `DISAB` — Disable interrupts
Clears NMIEN and sets the IRQ inhibit flag (SEI). Call before any serial I/O sequence.
Returns: Y = 0.

#### `ENAB` — Enable interrupts
Restores NMIEN ($C0) and clears the IRQ inhibit flag (CLI). Falls through to `EXIT`.
Does **not** modify the carry flag.
Returns: Y = 1.

#### `EXIT` — Return with Y=1
Sets Y=1 and returns. Entry point for routines that need to signal normal completion.

#### `ERTS` — Bare return
A plain `RTS`. Shared return point used by several routines.

#### `CMD` — Send command byte
Sends the byte in A to the XEP80 as a **command** (sets carry before transmitting so the XEP80 distinguishes it from data). Must be called with interrupts disabled.
- Input: A = command byte
- Clobbers: A, X, Y

#### `OUTPUT` — Send data byte
Sends the byte in A to the XEP80 as a **character**. Must be called with interrupts disabled.
- Input: A = character
- Clobbers: A, X, Y

#### `CINP` — Send command, receive response
Calls `CMD` with the byte in A, then immediately calls `INPUT` to wait for the XEP80's response. Cursor packets in the response are decoded and stored in VCP/HCP automatically. Must be called with interrupts disabled.
- Input: A = command byte
- Returns: A = received byte; C=0 success, C=1 timeout
- Clobbers: A, X, Y

#### `INPUT` — Receive one byte
Waits for the XEP80 to assert its data line, then clocks in 8 bits at 15.7 kbps. Cursor position packets are automatically decoded and written to `VCP`/`HCP` and their shadows `VCS`/`HCS`; a second `INPUT` call is made automatically if vertical and horizontal cursor data arrive as separate packets. Must be called with interrupts disabled.
- Returns: A = received byte; C=0 success, C=1 timeout
- Clobbers: A, X, Y

#### `CURCK` — Validate horizontal cursor
If `HCP` is $50 or greater the XEP80 uses an extended column encoding. `CURCK` detects this and re-requests the actual cursor position with `CUR80`, updating `HCP` and `HCS` with the correct value. Call after `INPUT` or `CINP` whenever cursor accuracy matters.
- Clobbers: A, X, Y

#### `READ` — Request and receive a character
Convenience wrapper: disables interrupts, sends `GET80`, calls `CINP` for the character, calls `INPUT` for the cursor update, calls `CURCK`, then re-enables interrupts.
- Returns: A = character at cursor; C=0 success, C=1 timeout; Y=1
- Clobbers: A, X, Y

#### `ALIGN` — Synchronize cursor and margins
Reads `VCP`, `HCP`, `LMARGN`, and `RMARGN`; compares each against its shadow variable; and sends the appropriate XEP80 cursor/margin command only when a value has changed. Handles the extended column encoding (XCH80 + low nibble) for columns $50–$7F. Must be called with interrupts disabled.
- Clobbers: A, X, Y; updates VCS, HCS, LMARGS, RMARGS

#### `PUTCHR` — Send one character
Sends the byte in A to the active XEP80. Manages interrupt discipline internally (calls `DISAB`, `OUTPUT`, `INPUT`, `CURCK`, then tail-calls `ENAB`). Safe to call with interrupts already enabled.
- Input: A = character
- Clobbers: A, X, Y

#### `PUTS` — Print EOL-terminated string
Prints characters from the string whose address is given in A (low byte) and Y (high byte) until and including the ATASCII EOL terminator ($9B). The EOL is sent to the XEP80, advancing the cursor to the next line. Uses `STRPTR` ($CB/$CC) as an internal zero-page work pointer.
- Input: A = low byte of string address, Y = high byte
- Clobbers: A, X, Y; STRPTR points past the terminator on return

#### `GRPH` — Switch to graphics mode
Sends the `SGR80` command ($99) to the active XEP80, switching it to graphics mode. In graphics mode each byte written via `OUTPUT` represents eight horizontal pixels (MSB = leftmost). Safe to call with interrupts enabled.
- Clobbers: A, X, Y

#### `TEXT` — Switch to text mode
Sends the `SCR80` command ($D2) to the active XEP80, switching it back to normal text mode. Safe to call with interrupts enabled.
- Clobbers: A, X, Y

#### `SETPX` — Set one pixel in graphics mode
Sets a single pixel using a read-modify-write cycle: positions the cursor to the target column/row, reads the current eight-pixel byte with `GET80`, ORs in the bitmask, and writes the result back with `OUTPUT`. Must be called after `GRPH`. Uses `SPBMSK` ($CD) as a one-byte zero-page scratch register.
- Input: A = column (0–79), X = row (0–24), Y = pixel bitmask ($80 = leftmost pixel, $01 = rightmost)
- Clobbers: A, X, Y

#### `GETPX` — Read one pixel in graphics mode
Reads the eight-pixel byte at the given column/row using `GET80` and tests the specified bit. `ENAB` does not modify carry, so the result survives the tail-call return. Same calling convention as `SETPX`. Uses `SPBMSK` ($CD).
- Input: A = column (0–79), X = row (0–24), Y = pixel bitmask ($80 = leftmost pixel, $01 = rightmost)
- Returns: C=0 if pixel is clear, C=1 if pixel is set
- Clobbers: A, X, Y

---

### RAM variables

These are assembled into the API block and initialized to zero. `JINIT` writes `INMSK` and `OUTMS` from the mask tables; cursor shadows are managed automatically by `INPUT`; margin shadows are managed by `ALIGN`. Only `TOGGLE` needs to be set explicitly before calling `JINIT` (it defaults to 0 = port 1).

| Label | Description |
|---|---|
| `VCS` | Shadow of OS `VCP` (vertical cursor). VCS+1 = HCS |
| `HCS` | Shadow of OS `HCP` (horizontal cursor) |
| `LMARGS` | Shadow of OS `LMARGN` (left margin) |
| `RMARGS` | Shadow of OS `RMARGN` (right margin) |
| `DATIN` | Shift register for the byte being received |
| `INMSK` | Input bit mask on PORTA/PORTB (set by JINIT) |
| `OUTMS` | Output bit mask on PORTA/PORTB (set by JINIT) |
| `TOGGLE` | Active port: 0=port 1, 1=port 2, 2=port 3, 3=port 4 |
| `MACHTYPE` | Machine type: $FF=unknown, 0=Atari 400/800, 1=XL/XE (set by XLCHK) |

`PUTS` also reserves two zero-page bytes as a work pointer:

| Equate | Address | Description |
|---|---|---|
| `STRPTR` | $CB–$CC | 2-byte ZP string pointer used by `PUTS` |
| `SPBMSK` | $CD | 1-byte ZP scratch used by `SETPX` (pixel bitmask) |

Reserve $CB–$CD in your program. Do not use $CB/$CC while `PUTS` is active; do not use $CD while `SETPX` or `GETPX` is active.

> `VCS` and `HCS` are adjacent bytes in memory. The `INPUT` routine writes both using `STA VCS,Y` with Y=0 (vertical) and Y=1 (horizontal), so their relative order in the binary must not change.

---

### XEP80 command bytes

| Equate | Value | Description |
|---|---|---|
| `XCH80` | $50 | Set cursor column, high nibble (columns $50–$7F) |
| `LMG80` | $60 | Set left margin, low nibble |
| `LMH80` | $70 | Set left margin, high nibble |
| `YCR80` | $80 | Set cursor row (OR the row number with this value) |
| `SGR80` | $99 | Set graphics mode |
| `PAG80` | $9A | Set page / 50 Hz PAL timing |
| `RMG80` | $A0 | Set right margin, low nibble |
| `RMH80` | $B0 | Set right margin, high nibble |
| `GET80` | $C0 | Request character at cursor (use with CINP) |
| `CUR80` | $C1 | Request cursor position (use with CINP) |
| `RST80` | $C2 | Reset XEP80 (use with CINP) |
| `PST80` | $C3 | Request device status (use with CINP) |
| `CLR80` | $C4 | Clear screen (use with CINP) |
| `LIS80` | $D0 | Set list/printer flag |
| `SCR80` | $D2 | Normal screen mode |
| `SCB80` | $D3 | Burst screen mode |
| `GRF80` | $D4 | Graphics character set |
| `ICM80` | $D5 | International character set |
| `PAL80` | $D7 | 50 Hz PAL timing |
| `CRS80` | $D9 | Cursor on ($D9) / off ($D8) |
| `MCF80` | $DB | Move cursor to first column |
| `PNT80` | $DD | Printer pass-through mode |

---

### Character code equates

| Equate | Value |
|---|---|
| `LF` | $0A |
| `CR` | $0D |
| `ESC` | $1B |
| `SPACE` | $20 |
| `EOL` | $9B (Atari end-of-line) |

---

## Common patterns

### Print an EOL-terminated string

```asm
 LDA #<STRING
 LDY #>STRING
 JSR PUTS

STRING .BYTE "HELLO",$9B
```

### Patch variable data into a string template

When only part of a string is known at assemble time, embed placeholder bytes in the string and patch them at runtime before calling `PUTS`. For a byte value printed as two hex digits, use `HEXC` (nibble → ASCII, returns in A) and write the results directly into the template:

```asm
TEMPLATE .BYTE "VALUE: $",0,0,$9B  ; offsets 8 and 9 are placeholders

 PHA            ; save byte to print
 LSR A
 LSR A
 LSR A
 LSR A          ; high nibble
 JSR HEXC       ; A = ASCII hex char
 STA TEMPLATE+8
 PLA
 AND #$0F       ; low nibble
 JSR HEXC
 STA TEMPLATE+9
 LDA #<TEMPLATE
 LDY #>TEMPLATE
 JSR PUTS

HEXC
 CMP #$0A
 BCC HEXC1
 ADC #$06
HEXC1
 ADC #$30
 RTS
```

### Move cursor to row/column

```asm
 LDA #ROW
 STA VCP
 LDA #COL
 STA HCP
 JSR DISAB
 JSR ALIGN
 JSR ENAB
```

### Set margins

```asm
 LDA #LEFT_COL
 STA LMARGN
 LDA #RIGHT_COL
 STA RMARGN
 JSR DISAB
 JSR ALIGN
 JSR ENAB
```

### Switch between two XEP80 devices

```asm
 ; Write to XEP80 on port 1
 LDA #00
 JSR SELDEV
 JSR DISAB
 LDA #'A'
 JSR OUTPUT
 JSR INPUT
 JSR CURCK
 JSR ENAB

 ; Write to XEP80 on port 2
 LDA #01
 JSR SELDEV
 JSR DISAB
 LDA #'B'
 JSR OUTPUT
 JSR INPUT
 JSR CURCK
 JSR ENAB
```

### Draw pixels in graphics mode

```asm
 JSR GRPH           ; switch to graphics mode

 ; Set pixel at column 5, row 3, leftmost position in column
 LDA #05
 LDX #03
 LDY #$80
 JSR SETPX

 ; Read it back — C=1 if set
 LDA #05
 LDX #03
 LDY #$80
 JSR GETPX
 BCC NOT_SET

 JSR TEXT           ; return to text mode
```

For a runtime bitmask from a pixel x-coordinate in A (0–7 within its column):

```asm
; On entry: A = pixel position within column (0=left, 7=right)
; On exit:  A = bitmask for SETPX/GETPX
 TAX
 LDA #$80
MASKLP
 CPX #00
 BEQ MASKDONE
 LSR A
 DEX
 JMP MASKLP
MASKDONE
```

### PAL / NTSC detection after reset

The XEP80 defaults to NTSC (60 Hz) timing. On a PAL machine, send `PAL80` after reset to switch to 50 Hz:

```asm
 LDA PAL        ; $D014
 AND #$0E       ; bits 1-3 are 0 on NTSC
 BNE NTSC
 JSR DISAB
 LDA #PAL80
 JSR CMD
 JSR ENAB
NTSC
```

---

## Demo program

`xep80hello.asm` probes all joystick ports for attached XEP80 devices and prints a status report on each one found.

```
atasm xep80hello.asm
```

Load `xep80hello.65o` from Atari DOS. The program probes ports 1–4 in order (1–2 on XL/XE machines, where ports 3 and 4 use PORTB and are skipped automatically). For each port where an XEP80 responds it clears that device's screen and prints:

```
XEP80 ON PORT 1
STATUS:  $3C
VIDEO:   NTSC
```

- **Port** — joystick port the device is attached to (1–4).
- **Status** — raw byte returned by `PST80` ($C3), as two uppercase hex digits. `??` if the command times out.
- **Video** — `NTSC` or `PAL`, from Atari hardware register `$D014` (bits 1–3 are zero on NTSC). This reflects the Atari's own video standard, not an XEP80 setting.

After all ports are probed the program returns to DOS.

### Port probe loop

The demo iterates ports explicitly using a `CURPRT` counter rather than `JTOGL`, calling `SELDEV` once per port:

```asm
START
 LDA #00
 STA CURPRT

NXTPRT
 LDA CURPRT
 JSR SELDEV       ; C=0: port ok; C=1: XL/XE refuses ports 2/3
 BCC TRYDEV

ADVANCE
 LDA CURPRT
 CLC
 ADC #01
 CMP #04
 BCS DONE         ; all ports tried
 STA CURPRT
 JMP NXTPRT

DONE
 RTS

TRYDEV
 JSR DISAB
 LDA #RST80
 JSR CINP
 JSR ENAB
 BCC FOUND        ; C=0: XEP80 responded
 JMP ADVANCE      ; C=1: timeout, no device here
```

`SELDEV` calls `XLCHK` internally and returns C=1 for ports 2 and 3 on XL/XE machines, so no machine-type check is needed in the caller.

`ADVANCE` is placed immediately after `NXTPRT` so the short forward branch `BCC TRYDEV` reaches it without a long jump. `JMP ADVANCE` at the end of `TRYDEV` (and at the end of `FOUND`) uses an absolute jump because `ADVANCE` is more than 127 bytes away from those sites.

### Output: PUTS for every line

All three lines are printed with the API `PUTS` (A=low, Y=high of an EOL-terminated string). No partial-line prefix strings are needed.

**Line 1** — the port number is fixed at assemble time, so four complete strings are pre-built and selected at runtime by indexing a word table with `TOGGLE*2`:

```asm
MHDR1 .BYTE "XEP80 ON PORT 1",$9B
MHDR2 .BYTE "XEP80 ON PORT 2",$9B
MHDR3 .BYTE "XEP80 ON PORT 3",$9B
MHDR4 .BYTE "XEP80 ON PORT 4",$9B
MHDRT .WORD MHDR1,MHDR2,MHDR3,MHDR4

 LDA TOGGLE
 ASL A          ; TOGGLE * 2 = byte offset into word table
 TAX
 LDA MHDRT+1,X  ; high byte -> Y
 TAY
 LDA MHDRT,X    ; low byte -> A
 JSR PUTS
```

**Line 2** — the status byte is only known at runtime, so a mutable template holds two placeholder bytes that are patched before the `PUTS` call. `HEXC` converts one nibble to an ASCII hex character without printing it:

```asm
MSTAT .BYTE "STATUS:  $",0,0,$9B   ; offsets 10+11 patched at runtime

HEXC
 CMP #$0A
 BCC HEXC1
 ADC #$06       ; carry=1 from CMP, so +6+1=+7 maps 10-15 to 'A'-'F'
HEXC1
 ADC #$30       ; '0'; carry=0 in both paths
 RTS
```

`PST80` is called with interrupts disabled. `PHP`/`PLP` preserves its carry result across the `ENAB` call. On success the two nibbles are converted and written into the template; on timeout `?` ($3F) is written to both positions:

```asm
 JSR DISAB
 LDA #PST80
 JSR CINP           ; A = status byte; C=1 on timeout
 PHP
 JSR ENAB
 PLP
 BCS PSTUNK

 PHA
 LSR A
 LSR A
 LSR A
 LSR A
 JSR HEXC
 STA MSTAT+10
 PLA
 AND #$0F
 JSR HEXC
 STA MSTAT+11
 JMP PSTGOT

PSTUNK
 LDA #$3F
 STA MSTAT+10
 STA MSTAT+11

PSTGOT
 LDA #<MSTAT
 LDY #>MSTAT
 JSR PUTS
```

`ENAB` does not modify carry, so `PHP`/`PLP` is conservative here — but the pattern is correct in general and makes the intent explicit.

**Line 3** — `PUTS` with `MNTSC` or `MPAL` chosen from the Atari `$D014` register:

```asm
MNTSC .BYTE "VIDEO:   NTSC",$9B
MPAL  .BYTE "VIDEO:   PAL",$9B

 LDA PAL        ; $D014
 AND #$0E       ; bits 1-3 non-zero on PAL
 BNE VIPAL
 LDA #<MNTSC
 LDY #>MNTSC
 JMP VIPRT
VIPAL
 LDA #<MPAL
 LDY #>MPAL
VIPRT
 JSR PUTS
```

> **ATasm note:** ATasm warns about character literals (e.g. `#'0'`) in immediate arithmetic instructions. Use numeric equivalents (`#$30` for `'0'`, `#$3F` for `'?'`) to keep the build warning-free.

---

## Implementation notes

### Self-modifying code in JINIT

`JINIT` patches three instruction operands at runtime to point at the correct PIA register (`PORTA` = $D300 for ports 1–2, `PORTB` = $D301 for ports 3–4):

| Patch site | Instruction | Patched operand byte |
|---|---|---|
| `SEND+1` | `STY PORTA` in `SEND` | low byte of port address |
| `IN0+1` | `LDA PORTA` in `INPUT` (start-bit detect) | low byte of port address |
| `INRD+1` | `LDA PORTA` in `INPUT` (bit-clock loop) | low byte of port address |

Only the low byte needs changing because PORTA ($D300) and PORTB ($D301) share the same high byte ($D3). `JINIT` uses indexed absolute addressing (`STA PORTA,X` with X=0 or 1) for the non-timing-critical PIA setup, where an extra cycle has no effect.

### Page boundary constraint

The timing-critical serial routines (`CMD`/`OUTPUT`/`SEND` and `CINP`/`INPUT`) must each fit entirely within one 256-byte page. If a branch inside these loops crosses a page boundary it takes one extra cycle, which corrupts the bit timing. At the default `BASE=$6000` the entire API fits within page $60. If you relocate the API, verify that no critical loop spans a page boundary.
