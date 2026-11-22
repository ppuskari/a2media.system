; A2MEDIA.SYSTEM P0 - ProDOS 8 Apple IIe 128K / Apple IIgs
; Independent a2fpga MCU MOD jukebox remote; NOT a SenseiPlay derivative.
; Pure 6502, fixed ROMless M1 mailbox: physical slot 3 $C0B0-$C0BF.
; 80-column display uses internal C3 firmware, no direct AUX screen writes.
; M2 FAT browser protocol is NOT available in J2R11 firmware.
;
; Build: ca65 src/a2media.s -o build/a2media.o
;        ld65 -C src/prodos8-system.cfg build/a2media.o -o dist/A2MEDIA.SYSTEM
; Place on ProDOS disk with filetype SYS ($FF), filename A2MEDIA.SYSTEM.
; The raw file is load/entry $2000; .SYSTEM extension alone is not a file type.
;
; NOT verified on physical Apple yet: M1 $C0B0 decode in slot 3 and IIgs.
.setcpu "6502"

COUT    = $FDED
C3ROM   = $C300
MLI     = $BF00
KEY     = $C000
KEYCLR  = $C010
C3INT   = $C00A

MB_SIG0 = $C0B0
MB_SIG1 = $C0B1
MB_VER  = $C0B2
MB_FLAG = $C0B3
MB_CMD  = $C0B4
MB_SEQ  = $C0BA
MB_ACK  = $C0BB
MB_RC   = $C0BC
MB_MARK = $C0BF

PTR     = $06  ; save and restore ProDOS / firmware zero-page on exit
CMD_PING  = $01
CMD_LAST  = $02
CMD_STOP  = $03
CMD_FOLD  = $04
CMD_TREE  = $05
CMD_NEXT  = $06
CMD_PREV  = $07
CMD_ONCE  = $08
CMD_REPT  = $09

.macro SAY str
    lda #<str
    sta PTR
    lda #>str
    sta PTR+1
    jsr PrintZ
.endmacro

.segment "CODE"
Start:
    cld
    lda PTR
    sta Saved06
    lda PTR+1
    sta Saved07
    lda #$00
    sta Online
    sta LastCmd
    sta LastResult
    ; Select built-in slot-3 80-col firmware (not external C300 ROM).
    ; ProDOS 8 normally arranges this already, but force internal C3.
    sta C3INT
    jsr C3ROM
    lda #$92                 ; 80-column firmware Ctrl-R
    jsr COUT
    jsr Detect
    jsr Draw
Main:
    lda KEY
    bpl Main                ; A2 keyboard high bit = key ready
    and #$7f
    sta KeyChar
    lda KEYCLR              ; clear keyboard strobe
    lda KeyChar
    cmp #$1b                ; ESC
    beq ExitProgram
    cmp #'q'
    beq ExitProgram
    cmp #'Q'
    beq ExitProgram
    cmp #'i'
    beq DoPing
    cmp #'I'
    beq DoPing
    cmp #'s'
    beq DoStop
    cmp #'S'
    beq DoStop
    cmp #'n'
    beq DoNext
    cmp #'N'
    beq DoNext
    cmp #'p'
    beq DoPrev
    cmp #'P'
    beq DoPrev
    cmp #'l'
    beq DoLast
    cmp #'L'
    beq DoLast
    cmp #'f'
    beq DoFolder
    cmp #'F'
    beq DoFolder
    cmp #'t'
    beq DoTree
    cmp #'T'
    beq DoTree
    cmp #'o'
    beq DoOnce
    cmp #'O'
    beq DoOnce
    cmp #'r'
    beq DoRepeat
    cmp #'R'
    beq DoRepeat
    jmp Main

DoPing:
    lda #CMD_PING
    jmp Execute
DoStop:
    lda #CMD_STOP
    jmp Execute
DoNext:
    lda #CMD_NEXT
    jmp Execute
DoPrev:
    lda #CMD_PREV
    jmp Execute
DoLast:
    lda #CMD_LAST
    jmp Execute
DoFolder:
    lda #CMD_FOLD
    jmp Execute
DoTree:
    lda #CMD_TREE
    jmp Execute
DoOnce:
    lda #CMD_ONCE
    jmp Execute
DoRepeat:
    lda #CMD_REPT
Execute:
    jsr SendCommand
    jsr Detect
    jsr Draw
    jmp Main

Detect:
    lda #$00
    sta Online
    lda MB_SIG0
    cmp #'M'
    bne DetectDone
    lda MB_SIG1
    cmp #'B'
    bne DetectDone
    lda MB_VER
    cmp #$01
    bne DetectDone
    lda MB_MARK
    cmp #$a5
    bne DetectDone
    lda MB_FLAG
    and #$01                ; MCU READY, not just FPGA signature
    beq DetectDone
    lda #$01
    sta Online
DetectDone:
    rts

; A = existing M1 command ID. No filesystem, no streaming, no 80col redraw
; while awaiting MCU. Bounded wait for next ACK, never touches audio SPI6.
SendCommand:
    sta LastCmd
    lda #$e0               ; not connected
    sta LastResult
    lda Online
    beq CmdDone
    lda MB_FLAG
    and #$05               ; bit0 ready, bit2 command pending
    cmp #$01
    bne CmdBusy
    lda LastCmd
    sta MB_CMD
    lda MB_SEQ
    sta Expected
    ldy #$c8               ; timeout ~0.5 to 1s on stock 1 MHz CPU
    ldx #$ff
CmdWait:
    lda MB_ACK
    cmp Expected
    beq CmdAcked
    dex
    bne CmdWait
    dey
    bne CmdWait
    lda #$e1
    sta LastResult
    rts
CmdAcked:
    lda MB_RC
    sta LastResult
CmdDone:
    rts
CmdBusy:
    lda #$e5
    sta LastResult
    rts

; Nonblocking, static 80x24 screen; no repeated whole-screen redraw in loop.
Draw:
    lda #$8c                ; 80-column Ctrl-L = home + clear
    jsr COUT
    SAY Banner
    jsr CR
    SAY Byline
    jsr CR
    SAY Line
    jsr CR
    SAY SourceInfo
    jsr CR
    SAY MailboxInfo
    lda Online
    beq DrawOffline
    SAY OnlineInfo
    jmp DrawAfterState
DrawOffline:
    SAY OfflineInfo
DrawAfterState:
    jsr CR
    SAY Line
    jsr CR
    SAY Notice1
    jsr CR
    SAY Notice2
    jsr CR
    jsr CR
    SAY Keys1
    jsr CR
    SAY Keys2
    jsr CR
    SAY Keys3
    jsr CR
    SAY Keys4
    jsr CR
    SAY Line
    jsr CR
    SAY PlayingPrefix
    lda Online
    beq NotPlaying
    lda MB_FLAG
    and #$10
    beq NotPlaying
    SAY PlayingYes
    jmp AfterPlaying
NotPlaying:
    SAY PlayingNo
AfterPlaying:
    jsr CR
    SAY LastPrefix
    lda LastCmd
    jsr PrintHex
    SAY ResultPrefix
    lda LastResult
    jsr PrintHex
    jsr CR
    SAY Footer
    jsr CR
    rts

; Input PTR points to NUL-terminated ASCII. ROM COUT requires bit 7 set.
PrintZ:
    ldy #$00
NextChar:
    lda (PTR),y
    beq EndText
    ora #$80
    jsr COUT
    inc PTR
    bne NextChar
    inc PTR+1
    jmp NextChar
EndText:
    rts
CR:
    lda #$8d
    jmp COUT

PrintHex:
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    tax
    lda HexTab,x
    ora #$80
    jsr COUT
    pla
    and #$0f
    tax
    lda HexTab,x
    ora #$80
    jmp COUT

ExitProgram:
    ; Deactivate C3 80-column video firmware cleanly before QUIT.
    lda #$95                ; 80-column Ctrl-U
    jsr COUT
    lda Saved06
    sta PTR
    lda Saved07
    sta PTR+1
    inc $03f4               ; invalidate monitor warm-start vector
    jsr MLI
    .byte $65               ; ProDOS 8 QUIT
    .word QuitParams
QuitParams:
    .byte $04,0,0,0,0,0,0
QuitTrap:
    jmp QuitTrap

.segment "RODATA"
Banner:        .asciiz "A2MEDIA - A2FPGA MCU MEDIA PLAYER                             P0 / 80-COLUMN"
Byline:        .asciiz "ProDOS 8  |  Apple IIe 128K / Apple IIgs  |  6502"
Line:          .asciiz "-------------------------------------------------------------------------------"
SourceInfo:    .asciiz "SOURCE: MCU ACTIVE FAT (SD / USB)                PCM: HDMI 44.1KHZ STEREO"
MailboxInfo:   .asciiz "M1 MAILBOX $C0B0-$C0BF: "
OnlineInfo:    .asciiz "ONLINE / READY"
OfflineInfo:   .asciiz "NOT DETECTED (slot3 bus / firmware)"
Notice1:       .asciiz "FAT directory browsing and filenames need future M2 MCU-to-Apple replies."
Notice2:       .asciiz "J2R11 audio engine is untouched; this screen is a remote control only."
Keys1:        .asciiz "[I] Probe/Ping   [S] Stop   [N] Next   [P] Previous"
Keys2:        .asciiz "[L] Replay last MCU file   [F] Jukebox last folder"
Keys3:        .asciiz "[T] Jukebox last folder+subdirs   [O] Once   [R] Repeat"
Keys4:        .asciiz "[Q] Quit / ESC                   No firmware updates required for P0"
PlayingPrefix: .asciiz "MCU PLAYER: "
PlayingYes:    .asciiz "PLAYING"
PlayingNo:     .asciiz "IDLE / STOPPED / LINK OFFLINE"
LastPrefix:    .asciiz "LAST CMD: $"
ResultPrefix:  .asciiz "    RESULT: $"
Footer:        .asciiz "M1 result $00 = OK, $A5 = PONG, $E2 = NO SONG, $E1 = TIMEOUT."

HexTab:        .byte "0123456789ABCDEF"

.segment "BSS"
Saved06:       .res 1
Saved07:       .res 1
Online:        .res 1
LastCmd:       .res 1
LastResult:    .res 1
Expected:      .res 1
KeyChar:       .res 1
