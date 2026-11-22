#!/usr/bin/env python3
"""Sanity-check the ProDOS 8 A2MEDIA raw SYS binary."""
from __future__ import annotations
import hashlib
from pathlib import Path
import sys

def check(path: Path) -> dict:
    blob = path.read_bytes()
    if len(blob) < 256 or len(blob) > 0x7000:
        raise ValueError(f"unexpected SYS size: {len(blob)}")
    if not blob.startswith(b"\xd8"):
        raise ValueError("entry $2000 does not begin with CLD")
    required = {
        "built-in C3 80-column firmware": bytes.fromhex("20 00 C3"),
        "ROM COUT": bytes.fromhex("20 ED FD"),
        "M1 signature read": bytes.fromhex("AD B0 C0"),
        "M1 command write": bytes.fromhex("8D B4 C0"),
        "M1 ACK read": bytes.fromhex("AD BB C0"),
        "ProDOS 8 QUIT": bytes.fromhex("20 00 BF 65"),
        "80-column exit": bytes.fromhex("A9 95 20 ED FD"),
    }
    for label, sig in required.items():
        if sig not in blob:
            raise ValueError(f"missing {label}: {sig.hex()}")
    for text in (
        b"A2MEDIA - A2FPGA MCU MEDIA PLAYER",
        b"NOT DETECTED", b"FAT directory browsing and filenames",
        b"MCU PLAYER:", b"Jukebox last folder",
    ):
        if text not in blob:
            raise ValueError(f"UI text missing: {text!r}")
    return {
        "bytes": len(blob),
        "load": "$2000",
        "file_type": "SYS ($FF)",
        "sha256": hashlib.sha256(blob).hexdigest(),
    }

if __name__ == "__main__":
    p = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("dist/A2MEDIA.SYSTEM")
    print("PASS A2MEDIA P0 SYS:", check(p))
