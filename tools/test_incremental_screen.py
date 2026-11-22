#!/usr/bin/env python3
"""Static M2 Apple II 80-column incremental-UI regression guard.

The full ca65/ld65 SYS build tests syntax/linking; this complements it by
keeping the one-time full clear and region-local refresh contract intact.
The real IIe/IIgs 80-column firmware path still needs hardware testing.
"""
from pathlib import Path

src = (Path(__file__).resolve().parents[1] / "src/a2media_m2.s").read_text()

def region(start: str, end: str) -> str:
    assert src.count(start + ":\n") == 1, start
    assert src.count(end + ":\n") == 1, end
    return src.split(start + ":\n", 1)[1].split(end + ":\n", 1)[0]

# Ctrl-L and full Draw() must occur only at startup.
assert src.count("    lda #$8c") == 1, "Unexpected 80-col screen clear"
assert src.count("    jsr Draw\n") == 1, "Full-screen Draw called after startup"
assert "jmp Redraw" not in src

arrows = region("SelectDown", "NextPage")
assert arrows.count("jsr DrawSelection") == 2
assert "DrawDirectory" not in arrows and "Draw\n" not in arrows

pages = region("PageChanged", "ReopenAtPage")
assert "jsr DrawDirectory" in pages
assert "jsr DrawFolderHeader" in pages
assert "jsr DrawCommandResult" in pages
assert "jsr DrawDirtyFields" in pages
assert "jsr Draw\n" not in pages

timer = region("MainLoop", "DirectCommand")
assert "jsr PollStatusAndTitle" in timer
assert "jsr DrawDirtyFields" in timer
assert "jsr Draw\n" not in timer

paint = region("DrawSelection", "DrawNowPlaying")
assert "    lda #$a0" in paint and "    lda #$be" in paint
assert paint.count("jsr SetCursor") == 2

# $FDED uses BASICOUT, not Pascal PWRITE. Ctrl-^ GOTOXY is not handled
# by this path: it prints the two coordinate bytes and destroys layout.
# Home without clear, LF, and forward-space are safe BASICOUT controls.
cursor = region("SetCursor", "ClearToEol")
assert "    lda #$9e" not in cursor
assert "    lda #$99" in cursor  # Ctrl-Y: home without clear
assert "    lda #$8a" in cursor  # Ctrl-J: move down
assert "    lda #$9c" in cursor  # Ctrl-backslash: move right
assert "    dec CursorRow" in cursor and "    dec CursorCol" in cursor
assert "    lda #$9d" in region("ClearToEol", "DrawFolderHeader")
assert "LOCATE 13,22" in src
assert "LOCATE 5,23" in src
assert "LOCATE 27,23" in src
assert "LOCATE 42,23" in src
assert "LOCATE 54,23" in src
assert "LOCATE 62,23" in src
assert "PrintDecimal16:" in src and "PrintDecimalDigit:" in src
assert '.asciiz "JUKE: "' in src
assert '.asciiz " / "' in src

# Fixed-width state replacement must not slide subsequent status columns.
# Failed OPEN/DIR_NEXT must be rendered as an error, not a false empty folder.
assert "BrowseError:" in src
assert "DirectoryError:" in src
assert "SAY DirectoryError" in src
assert "sta BrowseError" in region("OpenDirectory", "FetchPage")
assert "sta BrowseError" in region("FetchPage", "ReadEntry")
assert "sta BrowseError" in region("ReopenAtPage", "BuildSelectedPath")

# Asynchronous FAT listing: OPEN ACKs promptly; only DIR_NEXT ($23) is
# retried on the MCU's $EA not-ready result, with an explicit finite cap.
command = region("SendCommand", "SendWithPath")
assert "cmp #$ea" in command and "cmp #DIR_NEXT" in command
assert "inc RetryCountLo" in command and "inc RetryCountHi" in command
assert "cmp #$20" in command and "lda #$e1" in command

# Backward navigation uses an absolute 16-bit index into the MCU's cached
# alphabetized folder. It never reopens or rescans the FAT directory.
seek = region("ReopenAtPage", "BuildSelectedPath")
assert "lda #DIR_SEEK" in seek
assert "lda #ARM" in seek
assert "sta MB_DATA" in seek
assert "jsr FetchPage" in seek
assert "lda #DIR_OPEN" not in seek
assert "lda #DIR_NEXT" not in seek
assert "SeekLo:" in src and "SeekHi:" in src

assert 'PlayingPadded:.asciiz "PLAYING       "' in src
assert 'Stopped:     .asciiz "IDLE / STOPPED"' in src
assert len("PLAYING       ") == len("IDLE / STOPPED") == 14

print("PASS incremental M2 UI: one startup clear, selection markers only, "
      "directory rectangle and independent status fields")
