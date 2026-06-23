; xep80hello.asm - XEP80 multi-port probe and status reporter
;
; Probes joystick ports 1-4 (1-2 on XL/XE) for attached XEP80 devices.
; On XL/XE machines, ports 3 and 4 are silently skipped because PORTB
; controls memory banking on those models (detected automatically via XLCHK).
;
; For each XEP80 found, clears its screen and prints:
;   XEP80 ON PORT X
;   STATUS:  $XX        (raw PST80 status byte)
;   VIDEO:   NTSC/PAL   (from Atari hardware register $D014)
;
; Build:  atasm xep80hello.asm
; Run:    binary load xep80hello.65o from Atari DOS

 .INCLUDE "xep80api.asm"   ; API assembled at BASE ($6000)

 *= $6300

;
; HEXC - convert low nibble of A (0-15) to an ASCII hex character
; Returns the character in A; does not print.
;
HEXC
 CMP #$0A
 BCC HEXC1
 ADC #$06       ; carry=1 from CMP, so +6+1=+7 maps 10-15 to 'A'-'F'
HEXC1
 ADC #$30       ; '0' = $30; carry=0 in both paths
 RTS

;
; START - probe all four joystick ports and report each XEP80 found
;
START
 LDA #00
 STA CURPRT

NXTPRT
 LDA CURPRT
 JSR SELDEV        ; C=0 success, C=1 if XL/XE refuses port
 BCC TRYDEV

ADVANCE
 LDA CURPRT
 CLC
 ADC #01
 CMP #04
 BCS DONE
 STA CURPRT
 JMP NXTPRT

DONE
 RTS

TRYDEV
 JSR DISAB
 LDA #RST80
 JSR CINP
 JSR ENAB
 BCC FOUND
 JMP ADVANCE

FOUND
 JSR DISAB
 LDA #CLR80
 JSR CINP
 JSR ENAB

 ;------------------------------------------------------------------
 ; Line 1: "XEP80 ON PORT X" - look up complete EOL-terminated string
 ;------------------------------------------------------------------
 LDA TOGGLE
 ASL A          ; TOGGLE*2 = byte offset into word table
 TAX
 LDA MHDRT+1,X  ; high byte -> Y
 TAY
 LDA MHDRT,X    ; low byte -> A
 JSR PUTS

 ;------------------------------------------------------------------
 ; Line 2: "STATUS:  $XX" - patch hex digits into template then print
 ;------------------------------------------------------------------
 JSR DISAB
 LDA #PST80
 JSR CINP           ; A = status byte; C=1 on timeout
 PHP
 JSR ENAB
 PLP
 BCS PSTUNK

 PHA                ; save status byte
 LSR A
 LSR A
 LSR A
 LSR A              ; high nibble
 JSR HEXC
 STA MSTAT+10       ; patch template at "STATUS:  $XX" offset 10
 PLA
 AND #$0F           ; low nibble
 JSR HEXC
 STA MSTAT+11       ; patch template at "STATUS:  $XX" offset 11
 JMP PSTGOT

PSTUNK
 LDA #$3F           ; '?'
 STA MSTAT+10
 STA MSTAT+11

PSTGOT
 LDA #<MSTAT
 LDY #>MSTAT
 JSR PUTS

 ;------------------------------------------------------------------
 ; Line 3: "VIDEO:   NTSC" or "VIDEO:   PAL"
 ;------------------------------------------------------------------
 LDA PAL
 AND #$0E
 BNE VIPAL
 LDA #<MNTSC
 LDY #>MNTSC
 JMP VIPRT
VIPAL
 LDA #<MPAL
 LDY #>MPAL
VIPRT
 JSR PUTS

 JMP ADVANCE

;----------------------------------------------------------------------
; String constants
;----------------------------------------------------------------------
MHDR1 .BYTE "XEP80 ON PORT 1",$9B
MHDR2 .BYTE "XEP80 ON PORT 2",$9B
MHDR3 .BYTE "XEP80 ON PORT 3",$9B
MHDR4 .BYTE "XEP80 ON PORT 4",$9B
MHDRT .WORD MHDR1,MHDR2,MHDR3,MHDR4  ; indexed by TOGGLE*2

MSTAT .BYTE "STATUS:  $",0,0,$9B      ; bytes 10+11 patched at runtime

MNTSC .BYTE "VIDEO:   NTSC",$9B
MPAL  .BYTE "VIDEO:   PAL",$9B

CURPRT .BYTE 0

 *= $02E0
 .WORD START

 .END
