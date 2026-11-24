; A2MEDIA.SYSTEM M2 EXPERIMENTAL - Apple IIe 128K + Apple IIgs ProDOS 8.
; Independent 6502 Apple-side controller, no audio DSP or DOC registers.
; Physical ROMless slot3 $C0B0-$C0BF, M1 version1 + negotiated M2 opcodes.
; IMPORTANT: Requires paired M2 FPGA and BL616 Stage2; cannot browse FAT
; using J2R11 golden firmware. M1-only hardware falls back to basic controls.
;
; Directory pages: 12 entries from the MCU's globally sorted folder
; snapshot (directories first, MOD names casefolded like J2R11 playlist).
; Starting at selected file resolves the exact J2R11 sorted index.
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
NOWPLAY=$2A            ; reply [1+n, active, basename ASCII n<=63]
DIR_SEEK=$2B           ; ARM + 2-byte LE offset into completed sorted catalog
DIR_EOF=$D0

.macro SAY str
    lda #<str
    sta PTR
    lda #>str
    sta PTR+1
    jsr PrintZ
.endmacro

.macro LOCATE col, row
    ldx #col
    lda #row
    jsr SetCursor
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
    sta OldSelected
    sta PageNo
    sta PageCount
    sta PageEnd
    sta BrowseError
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
    sta NowName
    sta NowActive
    sta WorkName
    sta ScreenDirty
    sta PollTickLo
    sta PollTickHi
    sta SavedCmd
    sta SavedResult
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
    jsr PollStatusAndTitle
    lda #0
    sta ScreenDirty
    jsr Draw
MainLoop:
    ; Poll off a 16-bit SOFTWARE counter, not RDVBLBAR ($C019). Some
    ; a2fpga/video environments leave $C019 static, so the old VBL-edge
    ; counter never reached 60 and NOW PLAYING only changed after 'I'.
    ; A full 65536 idle iterations is approximately one second at 1 MHz;
    ; faster IIgs CPUs refresh more frequently, with no blocking delay.
    inc PollTickLo
    bne @readKey
    inc PollTickHi
    bne @readKey
    jsr PollStatusAndTitle
    jsr DrawDirtyFields
@readKey:
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
    jmp PreviousPage
@notF:
    cmp #'G'
    bne @notG
    jmp NextPage
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
    jmp CommandChanged

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
; The MCU acknowledges M2 DIR_OPEN immediately, then builds the sorted
; FAT catalog in short work chunks. DIR_NEXT reports $EA (pending) until it
; is complete; transparently retry only DIR_NEXT, with an explicit limit.
; This also covers reopening and skipping to a previous 12-entry page.
SendCommand:
    sta LastCmd
    lda #0
    sta RetryCountLo
    sta RetryCountHi
@send:
    lda #$e0
    sta LastResult
    lda Online
    bne @online
    rts
@online:
    ; IIgs fast-mode race: a preceding ACK may have become visible while
    ; a new C0B3 status read still sees the old pending/ready state.
    ; Never return E5 on a single busy sample. Wait for READY and !PENDING,
    ; with a bounded timeout so a wedged FPGA still reports E5.
    lda #$08
    sta TimeoutHigh
    ldy #$ff
    ldx #$ff
@idleWait:
    lda MB_FLAG
    and #$05
    cmp #$01
    beq @idle
    dex
    bne @idleWait
    dey
    bne @idleWait
    dec TimeoutHigh
    bne @idleWait
    lda #$e5
    sta LastResult
    rts
@idle:
    ; Read the sequence BEFORE posting the new command. On fast IIgs CPUs
    ; C0B4 may be followed by C0BA before the 54MHz FPGA domain accepts
    ; the write. Reading C0BA immediately after the write can return the
    ; OLD sequence; the OLD ACK then appears to acknowledge the new call.
    lda MB_SEQ
    sta PreviousSeq
    lda LastCmd
    sta MB_CMD
    ; The command must cause a NEW sequence, then a matching ACK. Do not
    ; confuse stale ACKs with this command, even at 2.8MHz on a ROM 3 IIgs.
    lda #$08
    sta TimeoutHigh
    ldy #$ff
    ldx #$ff
@wait:
    lda MB_SEQ
    cmp PreviousSeq
    beq @againWait
    sta Expected
    lda MB_ACK
    cmp Expected
    bne @againWait
    ; ACK and PENDING are updated together in the FPGA. Verify idle
    ; before returning so subsequent ARM/DIR_NEXT commands are safe.
    lda MB_FLAG
    and #$05
    cmp #$01
    beq @acked
@againWait:
    dex
    bne @wait
    dey
    bne @wait
    dec TimeoutHigh
    bne @wait
    lda #$e1
    sta LastResult
    rts
@acked:
    lda MB_RC
    sta LastResult
    cmp #$ea              ; M2 catalog is still being built
    bne @done
    lda LastCmd
    cmp #DIR_NEXT
    bne @done             ; NOWPLAY $EA retains its prior semantics
    inc RetryCountLo
    bne @resend
    inc RetryCountHi
    lda RetryCountHi
    cmp #$80              ; bounded: 32768 pending catalog replies
    bcs @retryTimedOut
@resend:
    jmp @send
@retryTimedOut:
    lda #$eb              ; overall scan wait, not per-command ACK timeout
    sta LastResult
@done:
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
    lda #0
    sta BrowseError
    jsr FetchPage
    rts
@failure:
    sta BrowseError
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
    sta BrowseError
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
    bcc :+
    lda #$ed               ; invalid/missing M2 reply frame
    sta LastResult
    jmp @error
:
    inc PageCount
    jmp @loop
@eof:
    lda #1
    sta PageEnd
    jmp @done
@error:
    lda LastResult
    sta BrowseError
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
    beq @done
    lda Selected
    clc
    adc #1
    cmp PageCount
    bcs @done
    lda Selected
    sta OldSelected
    inc Selected
    jsr DrawSelection
@done:
    jmp MainLoop
SelectUp:
    lda Selected
    beq @done
    sta OldSelected
    dec Selected
    jsr DrawSelection
@done:
    jmp MainLoop

NextPage:
    lda M2Ready
    beq @done
    lda PageEnd
    bne @done
    inc PageNo
    jsr FetchPage
    lda PageCount
    bne @changed
    ; Walking beyond the final full page: restore current page.
    dec PageNo
    jsr ReopenAtPage
@changed:
    jmp PageChanged
@done:
    jmp MainLoop
PreviousPage:
    lda M2Ready
    beq @done
    lda PageNo
    beq @done
    dec PageNo
    jsr ReopenAtPage
    jmp PageChanged
@done:
    jmp MainLoop
ReloadFolder:
    lda #0
    sta PageNo
    jsr OpenDirectory
    jmp PageChanged

; Limited updates: page changes affect only the 12 file rows, a folder
; change affects the folder header plus those rows, and transport commands
; affect only their footer fields. Never issue Ctrl-L again after startup.
PageChanged:
    jsr DrawDirectory
    jsr DrawCommandResult
    jmp MainLoop
FolderChanged:
    jsr DrawFolderHeader
    jsr DrawDirectory
    jsr DrawCommandResult
    jmp MainLoop
CommandChanged:
    jsr DrawCommandResult
    jsr PollStatusAndTitle
    jsr DrawDirtyFields
    jmp MainLoop

; Rewind the MCU directory, skip PageNo*12 entries, then load this page.
; Previous-page access does not disturb FTP or HxCMOD scan iterators.
; Seek directly within the BL616's complete sorted catalog. Older M2
; reopened the FAT directory and sent PAGE_SIZE*PageNo NEXT commands,
; forcing a full 506-file scan for every previous-page navigation.
; The new M2 DIR_SEEK requires ARM, two raw bytes (16-bit LE index), SEEK.
; We retain FetchPage's existing bounded asynchronous READY retry.
ReopenAtPage:
    lda #0
    sta SeekLo
    sta SeekHi
    ldx PageNo
@mul:
    cpx #0
    beq @send
    clc
    lda SeekLo
    adc #PAGE_SIZE
    sta SeekLo
    lda SeekHi
    adc #0
    sta SeekHi
    dex
    jmp @mul
@send:
    lda #ARM
    jsr SendCommand
    lda LastResult
    bne @error
    lda SeekLo
    sta MB_DATA
    lda SeekHi
    sta MB_DATA
    lda #DIR_SEEK
    jsr SendCommand
    lda LastResult
    bne @error
    jsr FetchPage
    rts
@error:
    lda LastResult
    sta BrowseError
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
    jmp MainLoop
:
    lda PageCount
    bne :+
    jmp MainLoop
:
    jsr BuildSelectedPath
    bcc :+
    jmp MainLoop
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
    jmp FolderChanged
@play:
    jsr SetWorkPointer
    lda #PLAY_FILE
    jsr SendWithPath
    jmp CommandChanged

StartJukebox:
    lda M2Ready
    bne :+
    jmp MainLoop
:
    lda PageCount
    bne :+
    jmp MainLoop
:
    ldx Selected
    lda Kinds,x
    beq :+
    jmp MainLoop
:
    jsr BuildSelectedPath
    bcc :+
    jmp MainLoop
:
    jsr SetWorkPointer
    lda #JUKE_START
    jsr SendWithPath
    jmp CommandChanged

ParentFolder:
    lda M2Ready
    bne :+
    jmp MainLoop
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
    jmp FolderChanged

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
    jsr PollStatusAndTitle
    jsr DrawDirtyFields
    jmp MainLoop

; Get live status and NOW PLAYING from the same generation-stable snapshot
; shown in the MCU console. Polling does not change the Apple command/result
; diagnostic and causes a full 80-column redraw only on a real state change.
PollStatusAndTitle:
    lda M2Ready
    bne :+
    rts
:
    lda LastCmd
    sta SavedCmd
    lda LastResult
    sta SavedResult
    lda #STATUS
    jsr SendCommand
    lda LastResult
    beq :+
    jmp @title
:
    lda MB_FLAG
    and #$80
    bne :+
    jmp @title
:
    lda MB_DATA               ; status payload [5,state,lastLO,lastHI,totalLO,totalHI]
    cmp #5
    beq :+
    jmp @title
:
    lda MB_DATA
    cmp PlayerState
    beq :+
    sta PlayerState
    lda ScreenDirty
    ora #2
    sta ScreenDirty
:
    lda MB_DATA
    cmp LastJukeLo
    beq :+
    sta LastJukeLo
    lda ScreenDirty
    ora #4
    sta ScreenDirty
:
    lda MB_DATA
    cmp LastJukeHi
    beq :+
    sta LastJukeHi
    lda ScreenDirty
    ora #4
    sta ScreenDirty
:
    lda MB_DATA
    cmp TotalLo
    beq :+
    sta TotalLo
    lda ScreenDirty
    ora #4
    sta ScreenDirty
:
    lda MB_DATA
    cmp TotalHi
    beq :+
    sta TotalHi
    lda ScreenDirty
    ora #4
    sta ScreenDirty
:
@title:
    lda #NOWPLAY
    jsr SendCommand
    lda LastResult
    beq :+
    jmp @restore
:
    lda MB_FLAG
    and #$80
    bne :+
    jmp @restore
:
    lda MB_DATA               ; length=1+name bytes
    cmp #1
    bcs :+
    jmp @restore
:
    cmp #65
    bcc :+
    jmp @restore
:
    sec
    sbc #1
    sta FrameLen              ; 0..63 bytes
    lda MB_DATA               ; active bit
    cmp NowActive
    beq :+
    sta NowActive
    lda ScreenDirty
    ora #1
    sta ScreenDirty
:
    ldy #0
@readName:
    cpy FrameLen
    beq @endName
    lda MB_DATA
    sta WorkName,y
    iny
    bne @readName
@endName:
    lda #0
    sta WorkName,y
    ldy #0
@copyName:
    lda WorkName,y
    cmp NowName,y
    beq :+
    lda ScreenDirty
    ora #1
    sta ScreenDirty
:
    lda WorkName,y
    sta NowName,y
    beq @restore
    iny
    cpy #64
    bcc @copyName
@restore:
    lda SavedCmd
    sta LastCmd
    lda SavedResult
    sta LastResult
    rts

; One full clear at launch. Later updates position the 80-col BASIC
; firmware cursor using home, LF and forward-space without clearing the
; screen or switching AUX RAM banks.
Draw:
    lda #$8c              ; Ctrl-L: the ONLY full-screen clear
    jsr COUT
    LOCATE 0,0
    SAY Title
    LOCATE 0,1
    SAY SubTitle
    LOCATE 0,2
    SAY Rule
    LOCATE 0,4
    SAY Rule
    LOCATE 0,17
    SAY Rule
    LOCATE 0,18
    SAY HelpLine1
    LOCATE 0,19
    SAY HelpLine2
    LOCATE 0,20
    SAY HelpLine3
    LOCATE 0,21
    SAY MsgStatus
    lda Online
    bne @online
    SAY OfflineText
    jmp @linkDone
@online:
    lda M2Ready
    bne @m2online
    SAY NeedM2
    jmp @linkDone
@m2online:
    SAY M2Online
@linkDone:
    LOCATE 0,22
    SAY NowText
    LOCATE 0,23
    SAY PlayerText
    LOCATE 21,23
    SAY CmdLabel
    LOCATE 33,23
    SAY ResultLabel
    LOCATE 48,23
    SAY JukeLabel
    LOCATE 59,23
    SAY OfText
    jsr DrawFolderHeader
    jsr DrawDirectory
    jsr DrawNowPlaying
    jsr DrawPlayerState
    jsr DrawCommandResult
    jsr DrawJukeValue
    rts

; Portable 80-column BASIC/monitor output cursor placement.
; Input: X=0..79 column, A=0..23 row. JSR $FDED goes through BASICOUT,
; NOT the Pascal PWRITE path. Ctrl-^/$9E GOTOXY is only understood by
; PWRITE; BASICOUT ignores it and prints the following two coordinates!
; Use BASICOUT-supported controls: Ctrl-Y home (WITHOUT clearing),
; Ctrl-J linefeed and Ctrl-\\ forward-space. No direct AUX RAM writes or
; reliance on model-specific 80-col card cursor variables.
SetCursor:
    sta CursorRow
    stx CursorCol
    lda #$99              ; Ctrl-Y home, does NOT clear the display
    jsr COUT
    lda CursorRow
    beq @columns
@rows:
    lda #$8a              ; Ctrl-J: down one physical row
    jsr COUT
    dec CursorRow
    bne @rows
@columns:
    lda CursorCol
    beq @done
@cols:
    lda #$9c              ; Ctrl-\\: right one column, no character write
    jsr COUT
    dec CursorCol
    bne @cols
@done:
    rts

; Clear only from the current cursor to the right edge, preserving the row.
ClearToEol:
    lda #$9d              ; Ctrl-] in 80-column firmware
    jmp COUT

DrawFolderHeader:
    LOCATE 0,3
    jsr ClearToEol
    SAY FolderLabel
    lda #<CurrentPath
    sta PTR
    lda #>CurrentPath
    sta PTR+1
    jsr PrintPathLimited
    LOCATE 64,3
    SAY SourceFixed
    lda SourceUSB
    beq @sd
    SAY USBName
    rts
@sd:
    SAY SDName
    rts

; Physical 80-column row is bounded even for 127-byte FAT folder paths.
; Truncated paths get "..." instead of wrapping into the fixed file table.
PrintPathLimited:
    lda #49
    sta DisplayRemain
@loop:
    ldy #0
    lda (PTR),y
    beq @done
    lda DisplayRemain
    beq @more
    dec DisplayRemain
    lda (PTR),y
    ora #$80
    jsr COUT
    inc PTR
    bne @loop
    inc PTR+1
    jmp @loop
@more:
    SAY Ellipsis
@done:
    rts

; Directory rows have permanent screen addresses, rows 5..16. Repaint
; ONLY this rectangle on folder/page changes (not arrows, transport or
; now-playing polls). Ctrl-] trims old long filenames from shorter rows.
DrawDirectory:
    lda #0
    sta TextIndex
@row:
    lda TextIndex
    clc
    adc #5
    ldx #0
    jsr SetCursor
    lda M2Ready
    bne @ready
    lda TextIndex
    beq :+
    jmp @clear          ; long jump: @clear is > 127 bytes away
:
    SAY M2Missing
    jmp @clear
@ready:
    lda PageCount
    bne @hasItems
    lda TextIndex
    bne @clear
    lda BrowseError
    beq @empty
    SAY DirectoryError
    lda BrowseError
    jsr PrintHex
    jmp @clear
@empty:
    SAY EmptyFolder
    jmp @clear
@hasItems:
    lda TextIndex
    cmp PageCount
    bcs @clear
    cmp Selected
    bne @unselected
    SAY Marked
    jmp @prefixDone
@unselected:
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
@clear:
    jsr ClearToEol
    inc TextIndex
    lda TextIndex
    cmp #PAGE_SIZE
    bcs @done
    jmp @row
@done:
    rts

; Arrow keys change precisely two characters in video RAM: erase the old
; '>' marker and paint the new one. The actual filename rows are untouched.
DrawSelection:
    lda OldSelected
    clc
    adc #5
    ldx #0
    jsr SetCursor
    lda #$a0              ; space, with high bit set
    jsr COUT
    lda Selected
    clc
    adc #5
    ldx #0
    jsr SetCursor
    lda #$be              ; '>'
    jmp COUT

DrawNowPlaying:
    LOCATE 13,22           ; after static "NOW PLAYING: "
    lda NowActive
    beq @none
    lda #<NowName
    sta PTR
    lda #>NowName
    sta PTR+1
    jsr PrintZ
    jmp ClearToEol
@none:
    SAY NoNowPlaying
    jmp ClearToEol

DrawPlayerState:
    LOCATE 5,23
    lda PlayerState
    cmp #3                ; MOD_PCM_PLAYING
    bne @stopped
    SAY PlayingPadded     ; exactly 14 chars
    rts
@stopped:
    SAY Stopped           ; exactly 14 chars
    rts

DrawCommandResult:
    LOCATE 27,23
    lda LastCmd
    jsr PrintHex
    LOCATE 42,23
    lda LastResult
    jmp PrintHex

DrawJukeValue:
    ; Display 16-bit track index / total in decimal, five fixed columns each.
    LOCATE 54,23
    lda LastJukeLo
    ldx LastJukeHi
    jsr PrintDecimal16
    LOCATE 62,23
    lda TotalLo
    ldx TotalHi
    jmp PrintDecimal16

; A=lo, X=hi. Unsigned 16-bit decimal, always exactly five characters.
; Five subtract/divisor passes are bounded (no CPU-specific math routines).
PrintDecimal16:
    sta DecimalLo
    stx DecimalHi
    lda #<10000
    sta DecimalDivLo
    lda #>10000
    sta DecimalDivHi
    jsr PrintDecimalDigit
    lda #<1000
    sta DecimalDivLo
    lda #>1000
    sta DecimalDivHi
    jsr PrintDecimalDigit
    lda #100
    sta DecimalDivLo
    lda #0
    sta DecimalDivHi
    jsr PrintDecimalDigit
    lda #10
    sta DecimalDivLo
    lda #0
    sta DecimalDivHi
    jsr PrintDecimalDigit
    lda #1
    sta DecimalDivLo
    lda #0
    sta DecimalDivHi
    jmp PrintDecimalDigit

PrintDecimalDigit:
    lda #0
    sta DecimalDigit
@compare:
    lda DecimalHi
    cmp DecimalDivHi
    bcc @emit
    bne @subtract
    lda DecimalLo
    cmp DecimalDivLo
    bcc @emit
@subtract:
    sec
    lda DecimalLo
    sbc DecimalDivLo
    sta DecimalLo
    lda DecimalHi
    sbc DecimalDivHi
    sta DecimalHi
    inc DecimalDigit
    jmp @compare
@emit:
    lda DecimalDigit
    ora #$b0
    jmp COUT

; Bitmask: 1=filename, 2=player state, 4=jukebox position/count.
; Unlike a whole-screen refresh, each change touches just its own field.
DrawDirtyFields:
    lda ScreenDirty
    and #1
    beq @state
    jsr DrawNowPlaying
@state:
    lda ScreenDirty
    and #2
    beq @juke
    jsr DrawPlayerState
@juke:
    lda ScreenDirty
    and #4
    beq @done
    jsr DrawJukeValue
@done:
    lda #0
    sta ScreenDirty
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
SourceFixed: .asciiz "SOURCE: "
Ellipsis:    .asciiz "..."
USBName:     .asciiz "USB"
SDName:      .asciiz "SD"
Marked:      .asciiz "> "
Unmarked:    .asciiz "  "
DirMark:     .asciiz "[DIR] "
FileMark:    .asciiz " MOD  "
EmptyFolder: .asciiz "No .MOD files or folders in this directory."
DirectoryError:.asciiz "DIRECTORY READ FAILED - MCU RC: $"
M2Missing:   .asciiz "M2 extension not detected. Install matching FPGA + BL616 M2 test builds."
HelpLine1:   .asciiz "UP/DOWN or U/D: select   RETURN: enter directory / play selected MOD"
HelpLine2:   .asciiz "J: JUKEBOX START AT FILE   F: prev page  G: next page  B: parent"
HelpLine3:   .asciiz "S: stop  R: resume  N/P: next/prev track  I: status  L: reload  Q: quit"
MsgStatus:   .asciiz "LINK: "
OfflineText: .asciiz "OFFLINE (slot-3 $C0B0 not found)"
NeedM2:      .asciiz "M1 only; M2 required for directory reading"
M2Online:    .asciiz "M2 READY"
NowText:     .asciiz "NOW PLAYING: "
NoNowPlaying:.asciiz "(none)"
PlayerText:  .asciiz "MCU: "
Playing:     .asciiz "PLAYING"
PlayingPadded:.asciiz "PLAYING       "
Stopped:     .asciiz "IDLE / STOPPED"
LastText:    .asciiz "    CMD: $"
CmdLabel:    .asciiz "CMD: $"
ResultLabel: .asciiz "RESULT: $"
JukeLabel:   .asciiz "JUKE: "
ResultText:  .asciiz "  RESULT: $"
JukeText:    .asciiz "  JUKE: $"
OfText:      .asciiz " / "
HexTab:      .byte "0123456789ABCDEF"

.segment "BSS"
Old06:          .res 1
Old07:          .res 1
Old08:          .res 1
Old09:          .res 1
OldSelected:    .res 1
Online:         .res 1
M2Ready:        .res 1
Selected:       .res 1
PageNo:         .res 1
PageCount:      .res 1
PageEnd:        .res 1
BrowseError:    .res 1
KeyPressed:     .res 1
LastCmd:        .res 1
LastResult:     .res 1
Expected:       .res 1
PreviousSeq:    .res 1
TimeoutHigh:    .res 1
RetryCountLo:   .res 1
RetryCountHi:   .res 1
SeekLo:         .res 1
SeekHi:         .res 1
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
PollTickLo:     .res 1
PollTickHi:     .res 1
ScreenDirty:    .res 1
DisplayRemain:  .res 1
CursorRow:      .res 1
CursorCol:      .res 1
DecimalLo:      .res 1
DecimalHi:      .res 1
DecimalDivLo:   .res 1
DecimalDivHi:   .res 1
DecimalDigit:   .res 1
SavedCmd:       .res 1
SavedResult:    .res 1
NowActive:      .res 1
NowName:        .res 64
CurrentPath:    .res 128
WorkPath:       .res 128
WorkName:       .res 64
Kinds:          .res PAGE_SIZE
Names:          .res PAGE_SIZE*NAME_SIZE
