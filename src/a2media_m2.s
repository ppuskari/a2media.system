; A2MEDIA.SYSTEM M2 EXPERIMENTAL - Apple IIe 128K + Apple IIgs ProDOS 8.
; Independent 6502 Apple-side controller, no audio DSP or DOC registers.
; Physical ROMless slot3 $C0B0-$C0BF, M1 version1 + negotiated M2 opcodes.
; IMPORTANT: Requires paired M2 FPGA and BL616 Stage2; cannot browse FAT
; using J2R11 golden firmware. M1-only hardware falls back to basic controls.
;
; Directory pages: 12 entries, independent MCU FAT DIR handle, unsorted
; directory iteration (NOT MCU playlist sort). Starting at selected file
; resolves the correct sorted index in the J2R11 HxCMOD worker.
.setcpu "6502"

COUT=$FDED
C3ROM=$C300
C3INT=$C00A
KEY=$C000
KEYCLR=$C010
MLI=$BF00
MB_M=$C0B0
MB_B=$C0B1
MB_VER=$C0B2
MB_FLAG=$C0B3
MB_CMD=$C0B4
MB_DATA=$C0B5
MB_SEQ=$C0BA
MB_ACK=$C0BB
MB_RC=$C0BC
MB_MARK=$C0BF

PTR=$06
TMPPTR=$08
PAGE_SIZE=12
NAME_SIZE=64

PING=$01
REPLAY=$02
STOP=$03
NEXT_TRACK=$06
PREV_TRACK=$07
CAPS=$20
ARM=$21
DIR_OPEN=$22
DIR_NEXT=$23
DIR_CLOSE=$24
PLAY_FILE=$25
JUKE_START=$26
RESUME=$27
SOURCE=$28
STATUS=$29
DIR_EOF=$D0

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
    sta Old06
    lda PTR+1
    sta Old07
    lda TMPPTR
    sta Old08
    lda TMPPTR+1
    sta Old09
    lda #0
    sta Online
    sta M2Ready
    sta Selected
    sta PageNo
    sta PageCount
    sta PageEnd
    sta CurrentPath
    sta LastCmd
    sta LastResult
    sta SourceUSB
    sta LastJukeLo
    sta LastJukeHi
    sta TotalLo
    sta TotalHi
    sta PlayerState
    sta RequestCommand
    sta SkipCount
    sta TempIndex
    sta TextIndex
    sta PathLen
    sta FrameLen
    sta FrameIndex
    sta EntryKind
    sta WorkPath
    sta WorkName
    sta UnusedSlot
    sta MBResultSaved
    sta C3INT
    jsr C3ROM
    lda #$92             ; Apple 80-column firmware Ctrl-R
    jsr COUT
    jsr Probe
    lda Online
    beq FirstScreen
    lda #CAPS
    jsr SendCommand
    lda LastResult
    cmp #2
    bne FirstScreen
    lda #1
    sta M2Ready
    jsr QuerySource
    jsr OpenDirectory
FirstScreen:
    jsr Draw
MainLoop:
    lda KEY
    bpl MainLoop
    and #$7f
    sta KeyPressed
    lda KEYCLR
    lda KeyPressed
    cmp #$1b
    bne @notEsc
    jmp ExitProgram
@notEsc:
    cmp #$0d
    bne @notReturn
    jmp ChooseEntry
@notReturn:
    cmp #$0a
    bne @notDown
    jmp SelectDown
@notDown:
    cmp #$0b
    bne @notUp
    jmp SelectUp
@notUp:
    cmp #$08
    bne @notLeft
    jmp ParentFolder
@notLeft:
    and #$df           ; normalize case: alphabetic only from here
    cmp #'Q'
    bne @notQ
    jmp ExitProgram
@notQ:
    cmp #'D'
    bne @notD
    jmp SelectDown
@notD:
    cmp #'U'
    bne @notU
    jmp SelectUp
@notU:
    cmp #'B'
    bne @notB
    jmp ParentFolder
@notB:
    cmp #'F'
    bne @notF
    jmp NextPage
@notF:
    cmp #'G'
    bne @notG
    jmp PreviousPage
@notG:
    cmp #'J'
    bne @notJ
    jmp StartJukebox
@notJ:
    cmp #'S'
    bne @notS
    lda #STOP
    jmp DirectCommand
@notS:
    cmp #'N'
    bne @notN
    lda #NEXT_TRACK
    jmp DirectCommand
@notN:
    cmp #'P'
    bne @notP
    lda #PREV_TRACK
    jmp DirectCommand
@notP:
    cmp #'R'
    bne @notR
    lda #RESUME
    jmp DirectCommand
@notR:
    cmp #'I'
    bne @notI
    jmp RefreshStatus
@notI:
    cmp #'L'
    bne @notL
    jmp ReloadFolder
@notL:
    jmp MainLoop

DirectCommand:
    jsr SendCommand
    jmp Redraw

Probe:
    lda #0
    sta Online
    lda MB_M
    cmp #'M'
    bne @done
    lda MB_B
    cmp #'B'
    bne @done
    lda MB_VER
    cmp #1
    bne @done
    lda MB_MARK
    cmp #$a5
    bne @done
    lda MB_FLAG
    and #1
    beq @done
    lda #1
    sta Online
@done:
    rts

; A=command. Return after M1 ACK and store result, never wait indefinitely.
; This doesn't repaint the FPGA diagnostic console or touch SPI6 PCM.
SendCommand:
    sta LastCmd
    lda #$e0
    sta LastResult
    lda Online
    beq @done
    lda MB_FLAG
    and #5
    cmp #1
    bne @busy
    lda LastCmd
    sta MB_CMD
    lda MB_SEQ
    sta Expected
    ldy #$ff
    ldx #$ff
@wait:
    lda MB_ACK
    cmp Expected
    beq @acked
    dex
    bne @wait
    dey
    bne @wait
    lda #$e1
    sta LastResult
    rts
@acked:
    lda MB_RC
    sta LastResult
@done:
    rts
@busy:
    lda #$e5
    sta LastResult
    rts

; SendWithPath: A=M2 request code, TMPPTR=zero-terminated path pointer.
; Old M1 C0B5 writes unchanged; ARM makes MCU collect bytes across polls.
SendWithPath:
    sta RequestCommand
    lda #ARM
    jsr SendCommand
    lda LastResult
    bne @done
    ldy #0
@push:
    lda (TMPPTR),y
    sta MB_DATA
    beq @after
    iny
    cpy #127
    bcc @push
    lda #$e6
    sta LastResult
    rts
@after:
    lda RequestCommand
    jsr SendCommand
@done:
    rts

SetCurrentPointer:
    lda #<CurrentPath
    sta TMPPTR
    lda #>CurrentPath
    sta TMPPTR+1
    rts
SetWorkPointer:
    lda #<WorkPath
    sta TMPPTR
    lda #>WorkPath
    sta TMPPTR+1
    rts

; OpenDirectory resets the MCU's exclusive Apple FAT directory iterator.
OpenDirectory:
    lda M2Ready
    beq @done
    jsr SetCurrentPointer
    lda #DIR_OPEN
    jsr SendWithPath
    lda LastResult
    bne @failure
    jsr FetchPage
    rts
@failure:
    lda #0
    sta PageCount
    lda #1
    sta PageEnd
@done:
    rts

; Fetch 12 FatFS entries into page RAM. The MCU filters directories/.MOD,
; returning [length][type][ASCII name] from separate reply FIFO.
FetchPage:
    lda #0
    sta PageCount
    sta Selected
    sta PageEnd
@loop:
    lda PageCount
    cmp #PAGE_SIZE
    bcs @done
    lda PageCount
    sta TempIndex
    lda #DIR_NEXT
    jsr SendCommand
    lda LastResult
    cmp #DIR_EOF
    beq @eof
    cmp #0
    bne @error
    jsr ReadEntry
    bcs @error
    inc PageCount
    jmp @loop
@eof:
    lda #1
    sta PageEnd
    jmp @done
@error:
    lda #1
    sta PageEnd
@done:
    rts

; Decode one M2 record into Names[index] (64 bytes) and Kinds[index].
; Carry set on missing/invalid reply, no unsafe write beyond 64-byte slot.
ReadEntry:
    lda MB_FLAG
    and #$80
    beq @bad
    lda MB_DATA
    sta FrameLen
    cmp #2
    bcc @bad
    cmp #65
    bcs @bad
    lda MB_DATA
    ldx TempIndex
    sta Kinds,x
    jsr EntryPointer
    lda FrameLen
    sec
    sbc #1
    sta FrameLen
    ldy #0
@read:
    cpy FrameLen
    beq @finish
    lda MB_DATA
    sta (PTR),y
    iny
    jmp @read
@finish:
    lda #0
    sta (PTR),y
    clc
    rts
@bad:
    sec
    rts

; A=entry index 0..11; pointer for name slot in PTR.
; Computed by repeated +64 to avoid 6502 partial-page carry errors.
EntryPointer:
    lda #<Names
    sta PTR
    lda #>Names
    sta PTR+1
    ldx TempIndex
    beq @done
@advance:
    clc
    lda PTR
    adc #NAME_SIZE
    sta PTR
    lda PTR+1
    adc #0
    sta PTR+1
    dex
    bne @advance
@done:
    rts

SelectDown:
    lda M2Ready
    bne :+
    jmp Redraw
:
    lda Selected
    clc
    adc #1
    cmp PageCount
    bcc :+
    jmp Redraw
:
    sta Selected
    jmp Redraw
SelectUp:
    lda Selected
    bne :+
    jmp Redraw
:
    dec Selected
    jmp Redraw
NextPage:
    lda M2Ready
    bne :+
    jmp Redraw
:
    lda PageEnd
    beq :+
    jmp Redraw
:
    inc PageNo
    jsr FetchPage
    lda PageCount
    beq :+
    jmp Redraw
:
    dec PageNo
    jsr ReopenAtPage
    jmp Redraw
PreviousPage:
    lda M2Ready
    bne :+
    jmp Redraw
:
    lda PageNo
    bne :+
    jmp Redraw
:
    dec PageNo
    jsr ReopenAtPage
    jmp Redraw
ReloadFolder:
    lda #0
    sta PageNo
    jsr OpenDirectory
    jmp Redraw

; Rewind the MCU directory, skip PageNo*12 entries, then load this page.
; Previous-page access does not disturb FTP or HxCMOD scan iterators.
ReopenAtPage:
    jsr SetCurrentPointer
    lda #DIR_OPEN
    jsr SendWithPath
    lda LastResult
    bne @error
    lda PageNo
    sta SkipCount
@skipPage:
    lda SkipCount
    beq @readPage
    ldx #PAGE_SIZE
@skipEntry:
    stx TextIndex
    lda #DIR_NEXT
    jsr SendCommand
    lda LastResult
    bne @error
    ldx TextIndex
    dex
    bne @skipEntry
    dec SkipCount
    jmp @skipPage
@readPage:
    jsr FetchPage
    rts
@error:
    lda #0
    sta PageCount
    lda #1
    sta PageEnd
    rts

; Selected entry -> WorkPath. Refuse to exceed the MCU 127-byte cap.
BuildSelectedPath:
    ldx #0
@current:
    lda CurrentPath,x
    beq @endCurrent
    cpx #120
    bcs @bad
    sta WorkPath,x
    inx
    jmp @current
@endCurrent:
    cpx #0
    beq @noSlash
    lda #'/'
    sta WorkPath,x
    inx
@noSlash:
    stx PathLen
    lda Selected
    sta TempIndex
    jsr EntryPointer
    ldy #0
    ldx PathLen
@copyName:
    lda (PTR),y
    beq @finish
    cpx #126
    bcs @bad
    sta WorkPath,x
    iny
    inx
    jmp @copyName
@finish:
    lda #0
    sta WorkPath,x
    clc
    rts
@bad:
    lda #$e6
    sta LastResult
    sec
    rts

ChooseEntry:
    lda M2Ready
    bne :+
    jmp Redraw
:
    lda PageCount
    bne :+
    jmp Redraw
:
    jsr BuildSelectedPath
    bcc :+
    jmp Redraw
:
    ldx Selected
    lda Kinds,x
    beq @play
    ; Selected folder -> new current path and first page.
    ldx #0
@copy:
    lda WorkPath,x
    sta CurrentPath,x
    beq @newDir
    inx
    bne @copy
@newDir:
    lda #0
    sta PageNo
    jsr OpenDirectory
    jmp Redraw
@play:
    jsr SetWorkPointer
    lda #PLAY_FILE
    jsr SendWithPath
    jmp Redraw

StartJukebox:
    lda M2Ready
    bne :+
    jmp Redraw
:
    lda PageCount
    bne :+
    jmp Redraw
:
    ldx Selected
    lda Kinds,x
    beq :+
    jmp Redraw
:
    jsr BuildSelectedPath
    bcc :+
    jmp Redraw
:
    jsr SetWorkPointer
    lda #JUKE_START
    jsr SendWithPath
    jmp Redraw

ParentFolder:
    lda M2Ready
    bne :+
    jmp Redraw
:
    ldx #0
@len:
    lda CurrentPath,x
    beq @back
    inx
    cpx #127
    bcc @len
    lda #0
    sta CurrentPath
    jmp @open
@back:
    cpx #0
    beq @open
@scan:
    dex
    lda CurrentPath,x
    cmp #'/'
    bne @continue
    lda #0
    sta CurrentPath,x
    jmp @open
@continue:
    cpx #0
    bne @scan
    lda #0
    sta CurrentPath
@open:
    lda #0
    sta PageNo
    jsr OpenDirectory
    jmp Redraw

QuerySource:
    lda #SOURCE
    jsr SendCommand
    lda LastResult
    bne @done
    lda MB_DATA  ; record length=1
    cmp #1
    bne @done
    lda MB_DATA
    sta SourceUSB
@done:
    rts

RefreshStatus:
    lda M2Ready
    bne :+
    jmp Redraw
:
    lda #STATUS
    jsr SendCommand
    lda LastResult
    beq :+
    jmp Redraw
:
    lda MB_DATA             ; length=5
    cmp #5
    beq :+
    jmp Redraw
:
    lda MB_DATA
    sta PlayerState
    lda MB_DATA
    sta LastJukeLo
    lda MB_DATA
    sta LastJukeHi
    lda MB_DATA
    sta TotalLo
    lda MB_DATA
    sta TotalHi
    jmp Redraw

Redraw:
    jsr Draw
    jmp MainLoop

Draw:
    lda #$8c              ; Ctrl-L: clear screen through 80-col firmware
    jsr COUT
    SAY Title
    jsr CR
    SAY SubTitle
    jsr CR
    SAY Rule
    jsr CR
    SAY FolderLabel
    lda #<CurrentPath
    sta PTR
    lda #>CurrentPath
    sta PTR+1
    jsr PrintZ
    SAY SourceLabel
    lda SourceUSB
    beq @sd
    SAY USBName
    jmp @srcDone
@sd:
    SAY SDName
@srcDone:
    jsr CR
    SAY Rule
    jsr CR
    lda M2Ready
    bne @displayEntries
    SAY M2Missing
    jsr CR
    jmp @footer
@displayEntries:
    lda PageCount
    bne @notEmpty
    SAY EmptyFolder
    jsr CR
    jmp @footer
@notEmpty:
    lda #0
    sta TextIndex
@nextRow:
    lda TextIndex
    cmp PageCount
    bcs @footer
    cmp Selected
    bne @notSelected
    SAY Marked
    jmp @prefixDone
@notSelected:
    SAY Unmarked
@prefixDone:
    ldx TextIndex
    lda Kinds,x
    beq @file
    SAY DirMark
    jmp @typeDone
@file:
    SAY FileMark
@typeDone:
    lda TextIndex
    sta TempIndex
    jsr EntryPointer
    jsr PrintZ
    jsr CR
    inc TextIndex
    jmp @nextRow
@footer:
    SAY Rule
    jsr CR
    SAY HelpLine1
    jsr CR
    SAY HelpLine2
    jsr CR
    SAY HelpLine3
    jsr CR
    SAY MsgStatus
    lda Online
    bne @online
    SAY OfflineText
    jmp @afterStatus
@online:
    lda M2Ready
    bne @m2online
    SAY NeedM2
    jmp @afterStatus
@m2online:
    SAY M2Online
@afterStatus:
    jsr CR
    SAY PlayerText
    lda Online
    beq @notPlaying
    lda MB_FLAG
    and #$10
    beq @notPlaying
    SAY Playing
    jmp @afterPlaying
@notPlaying:
    SAY Stopped
@afterPlaying:
    SAY LastText
    lda LastCmd
    jsr PrintHex
    SAY ResultText
    lda LastResult
    jsr PrintHex
    jsr CR
    SAY JukeText
    lda LastJukeHi
    jsr PrintHex
    lda LastJukeLo
    jsr PrintHex
    SAY OfText
    lda TotalHi
    jsr PrintHex
    lda TotalLo
    jsr PrintHex
    ; 24th text row: don't CR here, which would scroll the title away.
    rts

PrintZ:
@loop:
    ldy #0
    lda (PTR),y
    beq @done
    ora #$80
    jsr COUT
    inc PTR
    bne @loop
    inc PTR+1
    jmp @loop
@done:
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
    lda M2Ready
    beq @finish
    lda #DIR_CLOSE
    jsr SendCommand
@finish:
    lda #$95
    jsr COUT
    lda Old06
    sta PTR
    lda Old07
    sta PTR+1
    lda Old08
    sta TMPPTR
    lda Old09
    sta TMPPTR+1
    inc $03f4
    jsr MLI
    .byte $65
    .word QuitParams
QuitParams:
    .byte $04,0,0,0,0,0,0
@trap:
    jmp @trap

.segment "RODATA"
Title:       .asciiz "A2MEDIA / a2fpga M2 MEDIA BROWSER                             ProDOS 8"
SubTitle:    .asciiz "IIe / IIgs  |  80-column FAT file picker  |  44.1 kHz MCU HDMI audio"
Rule:        .asciiz "-------------------------------------------------------------------------------"
FolderLabel: .asciiz "FOLDER: /"
SourceLabel: .asciiz "      SOURCE: "
USBName:     .asciiz "USB"
SDName:      .asciiz "SD"
Marked:      .asciiz "> "
Unmarked:    .asciiz "  "
DirMark:     .asciiz "[DIR] "
FileMark:    .asciiz " MOD  "
EmptyFolder: .asciiz "No .MOD files or folders in this directory."
M2Missing:   .asciiz "M2 extension not detected. Install matching FPGA + BL616 M2 test builds."
HelpLine1:   .asciiz "UP/DOWN or U/D: select   RETURN: enter directory / play selected MOD"
HelpLine2:   .asciiz "J: JUKEBOX START AT FILE   F/G: next/previous page   B: parent folder"
HelpLine3:   .asciiz "S: stop  R: resume  N/P: next/prev track  I: status  L: reload  Q: quit"
MsgStatus:   .asciiz "LINK: "
OfflineText: .asciiz "OFFLINE (slot-3 $C0B0 not found)"
NeedM2:      .asciiz "M1 only; M2 required for directory reading"
M2Online:    .asciiz "M2 READY"
PlayerText:  .asciiz "MCU: "
Playing:     .asciiz "PLAYING"
Stopped:     .asciiz "IDLE / STOPPED"
LastText:    .asciiz "    CMD: $"
ResultText:  .asciiz "  RESULT: $"
JukeText:    .asciiz "JUKE POSITION (hex): $"
OfText:      .asciiz " / $"
HexTab:      .byte "0123456789ABCDEF"

.segment "BSS"
Old06:          .res 1
Old07:          .res 1
Old08:          .res 1
Old09:          .res 1
Online:         .res 1
M2Ready:        .res 1
Selected:       .res 1
PageNo:         .res 1
PageCount:      .res 1
PageEnd:        .res 1
KeyPressed:     .res 1
LastCmd:        .res 1
LastResult:     .res 1
Expected:       .res 1
SourceUSB:      .res 1
LastJukeLo:     .res 1
LastJukeHi:     .res 1
TotalLo:        .res 1
TotalHi:        .res 1
PlayerState:    .res 1
RequestCommand: .res 1
SkipCount:      .res 1
TempIndex:      .res 1
TextIndex:      .res 1
PathLen:        .res 1
FrameLen:       .res 1
FrameIndex:     .res 1
EntryKind:      .res 1
UnusedSlot:     .res 1
MBResultSaved:  .res 1
CurrentPath:    .res 128
WorkPath:       .res 128
WorkName:       .res 64
Kinds:          .res PAGE_SIZE
Names:          .res PAGE_SIZE*NAME_SIZE
