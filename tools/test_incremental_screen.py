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

# Apple 80-column firmware go-to-XY (Ctrl-^), clear-to-EOL (Ctrl-]).
assert "    lda #$9e" in region("SetCursor", "ClearToEol")
assert "    lda #$9d" in region("ClearToEol", "DrawFolderHeader")
assert "LOCATE 13,22" in src
assert "LOCATE 5,23" in src
assert "LOCATE 27,23" in src
assert "LOCATE 42,23" in src
assert "LOCATE 55,23" in src
assert "LOCATE 63,23" in src

# Fixed-width state replacement must not slide subsequent status columns.
assert 'PlayingPadded:.asciiz "PLAYING       "' in src
assert 'Stopped:     .asciiz "IDLE / STOPPED"' in src
assert len("PLAYING       ") == len("IDLE / STOPPED") == 14

print("PASS incremental M2 UI: one startup clear, selection markers only, "
      "directory rectangle and independent status fields")
