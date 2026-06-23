; xep80api.asm - XEP80 80-Column Device API
;
; Low-level routines for driving the XEP80 from 6502 assembler programs.
; No OS handler registration, no CIO, no relocator — pure subroutines.
;
; Supports joystick ports 1-4.  Ports 1 and 2 use PORTA ($D300); ports 3
; and 4 use PORTB ($D301), available on the Atari 400/800 only.  PORTB
; controls memory banking on XL/XE machines; SELDEV and JTOGL refuse ports
; 2 and 3 on those machines (detected automatically via XLCHK).
;
; PUBLIC ENTRY POINTS:
;   XLCHK   - Detect machine type; C=0 = 400/800, C=1 = XL/XE
;   SELDEV  - Select active XEP80 by port number (A=0-3); C=0 ok, C=1 error
;   JINIT   - Reinitialize using current TOGGLE value; C=0 on return
;   JTOGL   - Advance to next port then reinitialize (skips PORTB on XL/XE)
;   DISAB   - Disable NMI + IRQ interrupts
;   ENAB    - Enable NMI + IRQ interrupts (falls through to EXIT)
;   EXIT    - Return Y=1
;   ERTS    - Bare RTS
;   CMD     - Send command byte (A = command)
;   OUTPUT  - Send data/character byte (A = char)
;   CINP    - Send command in A, then receive one response byte
;   INPUT   - Receive one byte; updates VCP/HCP and shadows VCS/HCS
;   CURCK   - Re-fetch real cursor if HCP >= $50
;   READ    - Disable IRQ, request+receive char, re-enable IRQ; A = char
;   ALIGN   - Sync OS cursor (VCP/HCP) and margins (LMARGN/RMARGN) to XEP80
;   PUTCHR  - Send one character (A) to the active XEP80
;   PUTS    - Send EOL-terminated string (A=low, Y=high); EOL advances the line
;   GRPH    - Switch XEP80 to graphics mode (SGR80)
;   TEXT    - Switch XEP80 to normal text mode (SCR80)
;   SETPX   - Set one pixel (A=col 0-79, X=row 0-24, Y=bitmask $80..$01)
;   GETPX   - Read one pixel; C=0 clear, C=1 set (same calling convention)

BASE=$6000

;
; XEP80 COMMAND BYTES
;
XCH80=$50   ; set cursor column, high nibble (col >= $50)
LMG80=$60   ; set left margin, low nibble
LMH80=$70   ; set left margin, high nibble
YCR80=$80   ; set cursor row
SGR80=$99   ; set graphics mode
PAG80=$9A   ; set page / 50 Hz PAL mode
RMG80=$A0   ; set right margin, low nibble
RMH80=$B0   ; set right margin, high nibble
GET80=$C0   ; request character at cursor
CUR80=$C1   ; request cursor position
RST80=$C2   ; reset XEP80
PST80=$C3   ; request device status
CLR80=$C4   ; clear screen
LIS80=$D0   ; set list/printer flag
SCR80=$D2   ; normal screen mode
SCB80=$D3   ; burst screen mode
GRF80=$D4   ; graphics character set
ICM80=$D5   ; international character set
PAL80=$D7   ; 50 Hz PAL timing
CRS80=$D9   ; cursor on/off
MCF80=$DB   ; move cursor to first column
PNT80=$DD   ; printer pass-through mode
;
; USEFUL CHARACTER CODES
;
LF=$0A
CR=$0D
ESC=$1B
SPACE=$20
EOL=$9B
;
; OS MEMORY LOCATIONS USED BY THIS API
;
LMARGN=$52   ; left margin
RMARGN=$53   ; right margin
VCP=$54      ; vertical cursor position
HCP=$55      ; horizontal cursor position
PAL=$D014    ; PAL/NTSC flag (bits 1-3 = 0 on NTSC)
PORTA=$D300  ; PIA port A (joystick ports 1 and 2)
PORTB=$D301  ; PIA port B (joystick ports 3 and 4; Atari 400/800 only)
PACTL=$D302  ; PIA port A control
PBCTL=$D303  ; PIA port B control
NMIEN=$D40E  ; NMI enable
STRPTR=$CB   ; 2-byte zero-page string pointer used by PUTS ($CB/$CC)
SPBMSK=$CD   ; 1-byte zero-page scratch used by SETPX (pixel bitmask)

 *=BASE

;
; XLCHK - Detect machine type (Atari 400/800 vs XL/XE)
; Reads the PORTB data direction register (DDRB).  On XL/XE the OS
; configures PORTB output bits for memory banking (DDRB != 0); on the
; 400/800 PORTB is a plain joystick port and DDRB remains 0 after boot.
; Result is cached in MACHTYPE after the first call.  Must be called
; before any code has configured PORTB direction on a 400/800 — which
; is always true at normal program startup.
; Returns: C=0 = Atari 400/800 (PORTB safe)
;          C=1 = Atari XL/XE   (PORTB is memory banking register)
; Clobbers: A
;
; JTOGL - Advance to next port and reinitialize
; On Atari 400/800: cycles 0->1->2->3->0 across all four joystick ports.
; On Atari XL/XE:  cycles 0->1->0, skipping ports 2 and 3 (PORTB).
; Clobbers: A, X, Y
;
; SELDEV - Select active XEP80 by port number
; A = port number: 0=port 1, 1=port 2, 2=port 3, 3=port 4
; Ports 2 and 3 (PORTB) are refused on XL/XE machines; returns C=1
; without changing TOGGLE or calling JINIT.
; Returns C=0 on success (falls through to JINIT).
; Clobbers: A, X, Y
;
; JINIT - Reinitialize using the current TOGGLE value
; Sets input/output bit masks and patches the port register address into
; the timing-critical SEND and INPUT routines (self-modifying code).
; Must be called at startup and after every successful SELDEV or JTOGL.
; Returns C=0.  Clobbers: A, X, Y
;
JTOGL LDA TOGGLE
 CLC
 ADC #01
 AND #03                 ; advance 0->1->2->3->0
 CMP #02
 BCC SELDEV              ; 0 or 1: safe on any machine
 JSR XLCHK              ; 2 or 3: check machine type
 BCC SELDEV              ; C=0: 400/800, PORTB ok
 LDA #00                 ; C=1: XL/XE, wrap back to port 1
SELDEV CMP #02
 BCC SDOK                ; 0 or 1: no machine check needed
 JSR XLCHK              ; 2 or 3: verify machine type
 BCC SDOK                ; C=0: 400/800, ok
 SEC                     ; C=1: XL/XE, PORTB forbidden
 RTS
SDOK STA TOGGLE
JINIT LDX TOGGLE
 LDA INMST,X
 STA INMSK
 LDA OUTMT,X
 STA OUTMS
 TAY                     ; Y = output mask, saved for STY below
 LDA PORTLO,X            ; 0 for PORTA, 1 for PORTB
 STA SEND+1              ; patch STY [port] in SEND (self-modifying)
 STA IN0+1               ; patch LDA [port] in start-bit detect (self-modifying)
 STA INRD+1              ; patch LDA [port] in bit-clock loop  (self-modifying)
 TAX                     ; X = PIA offset: 0=PORTA, 1=PORTB
 LDA #$FF
 STA PORTA,X             ; set data direction to output
 LDA #$38
 STA PACTL,X             ; configure CTL register
 TYA                     ; restore output mask (STY has no abs,X mode)
 STA PORTA,X             ; assert output line (idle high = output mask)
 LDA #$3C
 STA PACTL,X
 CLC                     ; success
 RTS
;
; DISAB - Disable NMI and IRQ interrupts
;
DISAB LDY #00
 STY NMIEN
 SEI
 RTS
;
; ENAB - Re-enable NMI and IRQ interrupts
; Falls through to EXIT (returns Y=1).
;
ENAB LDY #$C0
 STY NMIEN
 CLI
EXIT LDY #01
ERTS RTS
;
; CMD    - Send command byte (A = command byte)
; OUTPUT - Send data byte   (A = character)
; Carry set by CMD, clear by OUTPUT; used as command/data flag.
; TIMING: CMD through the RTS of OUT3 must not cross a page boundary.
; Clobbers: A, X, Y
;
CMD SEC     ;CMD FLAG
 BCS OUT
OUTPUT CLC  ;DATA FLAG
OUT LDY #00
 JSR SEND   ;SEND START BIT
 LDX #08    ;SETUP BIT COUNT OF 9
 NOP
 NOP
 NOP        ;2+2+2+2=8
OUT0 ROR A  ;PUT BIT INTO CARRY
 BCS HI
 BCC LO     ;2+3=5 CYCLES TO LO
LO LDY #00  ;5+2 CYCLES TO JSR
 JSR SEND   ;SEND A 0
 BCC OUT1   ;3 CYCLES
HI LDY OUTMS ;3+4 CYCLES TO JSR
 JSR SEND   ;SEND A 1
 BCS OUT1   ;3 CYCLES
OUT1 DEX    ;NEXT BIT 2 CYC
 BPL OUT0   ;MORE 3 OR 2 CYC
 BMI OUT2   ;SEND STOP BIT 3 CYC
OUT2 LDY OUTMS ;SEND A 1
 BNE OUT3
OUT3 JSR SEND  ;2+3+4+3=12
 RTS
;
; SEND - Transmit one bit on PORTA/PORTB (internal, do not call directly)
; Y=0 sends a zero bit; Y=OUTMS sends a one bit.
; JINIT patches SEND+1 with the low byte of the active port register.
;
SEND STY PORTA  ;OUTPUT BIT  <-- SEND+1 patched by JINIT
 LDY #12        ;TIMER FOR 15.7KB
S1 DEY
 BNE S1         ;5*Y-1 CYCLES
 BEQ S2         ;3
S2 NOP
 NOP
 NOP
 NOP            ;2+2+2+2=8
S3 RTS          ;6 CYCLES
;
; CINP - Send command in A then receive one response byte
; Falls through to INPUT after sending.
; Returns: A = received byte, C=0 success, C=1 timeout
;
; INPUT - Receive one byte from XEP80
; TIMING: INPUT through I5 must not cross a page boundary.
; Cursor position packets are decoded and stored in VCP/HCP and VCS/HCS.
; Returns: A = received byte, C=0 success, C=1 timeout
; Clobbers: A, X, Y
; JINIT patches IN0+1 and INRD+1 with the low byte of the active port register.
;
CINP JSR CMD
INPUT LDA #00  ;TIME CRITICAL CODE
 TAX           ;MUST NOT CROSS A
 LDY #31       ;PAGE BOUNDARY
 STA DATIN
IN0 LDA PORTA  ;4          <-- IN0+1 patched by JINIT
 AND INMSK     ;4
 BEQ IN01      ;3 IF A 0, 2 IF NOT
 DEX
 BNE IN0
 DEY           ;TIMEOUT LOOPS
 BNE IN0
 SEC           ;NO RESPONSE
 RTS
IN01 LDX #08
 LDY #12       ;2
IN1 DEY
 BNE IN1       ;5*Y-1
 NOP           ;2
IN10 LDY #15   ;2 MAIN DLY COUNT
IN2 DEY
 BNE IN2       ;5*Y-1
INRD LDA PORTA ;4 GET BYTE  <-- INRD+1 patched by JINIT
 AND INMSK     ;4 GET BIT
 CLC           ;2
 BEQ IN25      ;0=3,1=2
 SEC           ;1=2
IN25 BCC IN26  ;0=3,1=2
IN26 DEX       ;2 DEC COUNT
 BMI IN3       ;2 (3 DONE)
 ROR DATIN     ;6 SHIFT IN BIT
 BCC IN10      ;3 ALWAYS
IN3 LDY #15    ;DELAY 1/2 BIT
IN33 DEY
 BNE IN33
 LDA DATIN     ;GET CHAR (Y=0)
 BCC I5        ;RETURN IF CHAR
 BPL I0        ;HORIZ WITH NO VERT
 AND #$7F      ;CLEAR UPPER FLAG
 CMP #$51      ;TEST HORIZ/VERT
 BCC I00       ;HORIZONTAL
 AND #$1F      ;CLEAR MID FLAG
 BCS I01       ;SAVE VERT
I00 JSR I0     ;SAVE HORIZ
 BCC INPUT     ;GET VERT
I0 INY         ;OFFSET FOR HORIZ
I01 STA VCP,Y  ;CURS POSITION
 STA VCS,Y     ;CURS SHADOW
 CLC           ;INDICATE RESPONSE
I5 RTS
;
; CURCK - Validate horizontal cursor position
; If HCP >= $50 the XEP80 uses an extended encoding; re-fetches real value.
; Call after INPUT when cursor accuracy matters.
; Clobbers: A, X, Y
;
CURCK LDA HCP  ;CHECK HORIZ CURSOR
 CMP #$50      ;FOR >$4F
 BCC I5        ;IF NOT
 LDA #CUR80    ;GO GET REAL VALUE
 JSR CINP
 JMP I0        ;AND STORE IT (Y=0)
;
; READ - Request and receive one character from XEP80
; Disables interrupts for the transfer, re-enables on return.
; Returns: A = character, C=0 success, C=1 timeout; Y=1
; Clobbers: A, X, Y
;
READ JSR DISAB
 LDA #GET80
 JSR CINP      ;REQUEST, GET CHAR
 PHA
 JSR INPUT     ;GET CURS
 JSR CURCK     ;CHECK FOR X>$4F
 PLA
 JMP ENAB
;
; ALIGN - Synchronize OS cursor and margins to XEP80
; Reads VCP, HCP, LMARGN, RMARGN; sends any changed values as XEP80 commands.
; Maintains local shadow copies (VCS, HCS, LMARGS, RMARGS) to detect changes.
; Call before OUTPUT/CMD when the cursor or margins may have changed.
; Clobbers: A, X, Y; updates VCS, HCS, LMARGS, RMARGS
;
ALIGN LDY HCP  ;GET HCURS
 CPY HCS       ;COMPARE TO SHADOW
 BEQ A1        ;NO CHANGE
 STY HCS       ;SAVE NEW VALUE
 PHA           ;SAVE CHAR
 TYA
 CMP #$50
 BCC A00
 LSR A
 LSR A
 LSR A
 LSR A
 ORA #XCH80
 PHA
 TYA
 AND #$0F
 JSR CMD
 PLA
A00 JSR CMD    ;SEND NEW CURSOR
 PLA
A1 LDY VCP    ;GET VCURS
 CPY #25      ;CHECK UPPER LIMIT
 BCC A15
 LDY #24      ;STATUS LINE
A15 CPY VCS   ;COMPARE TO SHADOW
 BEQ A2       ;NO CHANGE
 STY VCS      ;SAVE NEW VALUE
 PHA          ;SAVE CHAR
 TYA
 ORA #YCR80   ;SET CMD BIT
 JSR CMD      ;SEND NEW CURSOR
 PLA
A2 LDY LMARGN
 CPY RMARGN
 BCC A24
 LDY #00
 STY LMARGN
A24 CPY LMARGS
 BEQ A3
 STY LMARGS
 PHA
 TYA
 AND #$0F
 ORA #LMG80
 JSR CMD
 LDA LMARGN
 LSR A
 LSR A
 LSR A
 LSR A
 BEQ A25
 ORA #LMH80
 JSR CMD
A25 PLA
A3 LDY RMARGN
 CPY RMARGS
 BEQ A4
 STY RMARGS
 PHA
 TYA
 AND #$0F
 ORA #RMG80
 JSR CMD
 LDA RMARGN
 LSR A
 LSR A
 LSR A
 LSR A
 CMP #04
 BEQ A35
 ORA #RMH80
 JSR CMD
A35 PLA
A4 RTS
;
; PUTCHR - Output one character to the active XEP80
; A = character to send.  Clobbers A, X, Y.
;
PUTCHR
 JSR DISAB
 JSR OUTPUT
 JSR INPUT
 JSR CURCK
 JMP ENAB      ; tail-call: ENAB's RTS returns to PUTCHR's caller
;
; PUTS - Print an ATASCII EOL-terminated string to the active XEP80
; A = low byte of string address, Y = high byte.
; The terminating EOL ($9B) is sent to the XEP80, advancing the cursor
; to the next line.  Clobbers A, X, Y.
;
PUTS
 STA STRPTR
 STY STRPTR+1
PTSL
 LDY #00
 LDA (STRPTR),Y   ; Y=0 always; advance STRPTR instead
 CMP #EOL
 BEQ PTSEOL
 JSR PUTCHR        ; ENAB/EXIT leaves Y=1; reset at PTSL top
 INC STRPTR
 BNE PTSL
 INC STRPTR+1
 JMP PTSL
PTSEOL
 LDA #EOL
 JMP PUTCHR        ; tail-call: sends EOL and returns to PUTS caller
;
; GRPH - Switch the active XEP80 to graphics mode
; Sends the SGR80 command ($99).  Clobbers A, X, Y.
;
GRPH
 JSR DISAB
 LDA #SGR80
 JSR CMD
 JMP ENAB
;
; TEXT - Switch the active XEP80 to normal text mode
; Sends the SCR80 command ($D2).  Clobbers A, X, Y.
;
TEXT
 JSR DISAB
 LDA #SCR80
 JSR CMD
 JMP ENAB
;
; SETPX - Set one pixel in XEP80 graphics mode (read-modify-write)
; A = column (0-79), X = row (0-24), Y = bitmask ($80=leftmost .. $01=rightmost)
; Positions the cursor, reads the current byte with GET80, ORs in the bitmask,
; then writes the modified byte back.  Must call GRPH before using SETPX.
; Clobbers A, X, Y.
;
SETPX
 STY SPBMSK    ; save bitmask across subsequent calls
 STA HCP
 STX VCP
 JSR DISAB
 JSR ALIGN     ; position XEP80 cursor to (VCP, HCP)
 LDA #GET80
 JSR CINP      ; A = current byte at cursor; cursor packet still pending
 PHA           ; save current byte while we consume the cursor packet
 JSR INPUT     ; consume GET80 cursor packet (same pattern as READ)
 JSR CURCK
 PLA           ; restore current byte
 ORA SPBMSK    ; set the pixel bit
 JSR OUTPUT    ; write modified byte; XEP80 cursor advances to next column
 JSR INPUT     ; consume OUTPUT cursor packet
 JSR CURCK
 JMP ENAB
;
; GETPX - Read one pixel in XEP80 graphics mode
; Same calling convention as SETPX:
; A = column (0-79), X = row (0-24), Y = pixel bitmask ($80=leftmost .. $01=rightmost)
; Returns C=0 if the pixel is clear, C=1 if it is set.
; ENAB does not modify carry, so the result survives the tail-call.
; Clobbers A, X, Y.
;
GETPX
 STY SPBMSK
 STA HCP
 STX VCP
 JSR DISAB
 JSR ALIGN     ; position XEP80 cursor to (VCP, HCP)
 LDA #GET80
 JSR CINP      ; A = current byte at cursor; cursor packet still pending
 PHA           ; save current byte
 JSR INPUT     ; consume GET80 cursor packet
 JSR CURCK
 PLA           ; restore current byte
 AND SPBMSK    ; isolate the pixel bit
 CMP #01       ; C=0 if pixel clear (A=0), C=1 if pixel set (A>=1)
 JMP ENAB      ; tail-call; carry preserved through ENAB
;
; XLCHK - Detect machine type (Atari 400/800 vs XL/XE)
; Reads the PORTB data direction register (DDRB).  On XL/XE the OS
; configures PORTB output bits for memory banking (DDRB != 0); on the
; 400/800 PORTB is a plain joystick port and DDRB remains 0 after boot.
; Result is cached in MACHTYPE after the first call.  Must be called
; before any code has configured PORTB direction on a 400/800 — which
; is always true at normal program startup.
; Returns: C=0 = Atari 400/800 (PORTB safe)
;          C=1 = Atari XL/XE   (PORTB is memory banking register)
; Clobbers: A
;
XLCHK LDA MACHTYPE       ; $FF = not yet determined (bit 7 set)
 BMI XCDET
 LSR A                   ; bit 0 into carry (0=400/800, 1=XL/XE)
 RTS
XCDET PHP                ; save I flag
 SEI                     ; no interrupts while PBCTL is in DDR mode
 LDA PBCTL               ; save current PBCTL
 PHA
 LDA #$38                ; bit 2 = 0: select DDR register at $D301
 STA PBCTL
 LDA PORTB               ; read DDRB (0 on 400/800, non-zero on XL/XE)
 TAX
 PLA
 STA PBCTL               ; restore PBCTL
 PLP                     ; restore I flag
 LDA #01                 ; assume XL/XE
 CPX #00
 BNE XCOK                ; DDRB != 0: XL/XE confirmed
 LDA #00                 ; DDRB = 0: 400/800
XCOK STA MACHTYPE
 LSR A                   ; bit 0 into carry
 RTS
;
; VARIABLES (zero at assembly time; must be initialised before use)
;
VCS .BYTE 0    ; vertical cursor shadow  (VCS+1 = HCS, used as VCS,Y)
HCS .BYTE 0    ; horizontal cursor shadow
LMARGS .BYTE 0 ; left margin shadow
RMARGS .BYTE 0 ; right margin shadow
DATIN .BYTE 0  ; received byte shift register
INMSK .BYTE 0  ; input bit mask  (set by JINIT)
OUTMS .BYTE 0  ; output bit mask (set by JINIT)
TOGGLE .BYTE 0  ; active port: 0=port 1, 1=port 2, 2=port 3, 3=port 4
MACHTYPE .BYTE $FF ; machine type: $FF=unknown, 0=Atari 400/800, 1=XL/XE
;
; PORT CONFIGURATION TABLES (indexed by TOGGLE, 0-3)
;
PORTLO .BYTE 00,00,01,01    ; low byte of PIA address: 0=PORTA ($D300), 1=PORTB ($D301)
INMST .BYTE $02,$20,$02,$20 ; input  masks for ports 1, 2, 3, 4
OUTMT .BYTE $01,$10,$01,$10 ; output masks for ports 1, 2, 3, 4
