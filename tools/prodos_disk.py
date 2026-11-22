#!/usr/bin/env python3
"""A2MEDIA ProDOS 2.4.3 140K disk assembler and independent image verifier.

No third-party Python dependencies. Input/base must be a ProDOS-ordered .po.
Never rename .po to .dsk: a DOS-order sector permutation is required.

build:
  python tools/prodos_disk.py build --base ProDOS_2_4_3.po
check:
  python tools/prodos_disk.py check

Canonical original disk:
https://github.com/ProDOS-8/ProDOS8-Releases/blob/master/ProDOS_2_4_3.po
Git blob SHA: d464c92578d4ed15dc4acd49eee43e51256808fd

The original user's prior SenseiPlay-modified image may also be used with
--base if it is ProDOS-order: existing root files with names beginning
SENSEI, plus any older A2MEDIA.SYSTEM, are deleted before installation.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

BLOCK = 512
SECTOR = 256
BLOCK_COUNT = 280
SIZE = BLOCK * BLOCK_COUNT
PRODOS_INTERLEAVE = (0, 8, 1, 9, 2, 10, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15)
DOS_INTERLEAVE = (0, 7, 14, 6, 13, 5, 12, 4, 11, 3, 10, 2, 9, 1, 8, 15)
BOOT_FILES = ("PRODOS", "BITSY.BOOT", "QUIT.SYSTEM", "BASIC.SYSTEM")
NAME = "A2MEDIA.SYSTEM"


@dataclass(frozen=True)
class Entry:
    offset: int
    name: str
    storage: int
    file_type: int
    key: int
    blocks: int
    eof: int
    aux: int


def u16(image: bytes | bytearray, n: int) -> int:
    return image[n] | (image[n + 1] << 8)


def write16(image: bytearray, n: int, value: int) -> None:
    image[n:n + 2] = bytes((value & 0xFF, (value >> 8) & 0xFF))


def get_name(image: bytes | bytearray, off: int) -> str:
    return bytes(image[off + 1:off + 1 + (image[off] & 0xF)]).decode("ascii")


def root(image: bytes | bytearray) -> tuple[int, int, int, list[int], list[Entry]]:
    if len(image) != SIZE:
        raise ValueError("Expected exactly 280 x 512 ProDOS-order blocks")
    head = 2 * BLOCK + 4
    if image[head] >> 4 != 0xF or get_name(image, head) != "PRODOS.2.4.3":
        raise ValueError("Not the expected ProDOS 2.4.3 volume, or not .po sector order")
    if image[head + 0x1F] != 39 or image[head + 0x20] != 13:
        raise ValueError("Unexpected ProDOS directory layout")
    bitmap = u16(image, head + 0x23)
    blocks = u16(image, head + 0x25)
    if blocks != BLOCK_COUNT or bitmap >= BLOCK_COUNT:
        raise ValueError("Unexpected ProDOS volume/bitmap geometry")

    chain: list[int] = []
    entries: list[Entry] = []
    current = 2
    while current:
        if current >= BLOCK_COUNT or current in chain:
            raise ValueError("Invalid ProDOS root directory chain")
        chain.append(current)
        for i in range(1 if current == 2 else 0, 13):
            p = current * BLOCK + 4 + i * 39
            st = image[p] >> 4
            if st:
                entries.append(Entry(
                    offset=p, name=get_name(image, p), storage=st,
                    file_type=image[p + 16], key=u16(image, p + 17),
                    blocks=u16(image, p + 19),
                    eof=image[p + 21] | image[p + 22] << 8 | image[p + 23] << 16,
                    aux=u16(image, p + 31),
                ))
        current = u16(image, current * BLOCK + 2)
    count = u16(image, head + 0x21)
    if count != len(entries):
        raise ValueError(f"Directory header count {count} != {len(entries)}")
    return head, bitmap, count, chain, entries


def free_state(image: bytes | bytearray, bitmap: int, index: int) -> bool:
    return bool(image[bitmap * BLOCK + index // 8] & (0x80 >> (index & 7)))


def set_free(image: bytearray, bitmap: int, index: int, free: bool) -> None:
    off = bitmap * BLOCK + index // 8
    mask = 0x80 >> (index & 7)
    if free:
        image[off] |= mask
    else:
        if not free_state(image, bitmap, index):
            raise ValueError(f"Block {index} already allocated")
        image[off] &= ~mask


def file_blocks(image: bytes | bytearray, ent: Entry) -> list[int]:
    """Support seedling and sapling ProDOS files (the previous P0 binaries)."""
    if ent.storage == 1:
        result = [ent.key]
    elif ent.storage == 2:
        num_data = (ent.eof + BLOCK - 1) // BLOCK
        if num_data > 256:
            raise ValueError("Invalid sapling file block count")
        idx = ent.key * BLOCK
        result = [ent.key]
        for i in range(num_data):
            pointer = image[idx + i] | (image[idx + 256 + i] << 8)
            if pointer:
                result.append(pointer)
    else:
        raise ValueError(f"Cannot safely remove {ent.name}, storage type {ent.storage}")
    if any(b < 2 or b >= BLOCK_COUNT for b in result):
        raise ValueError(f"Unsafe block pointer in {ent.name}")
    return result


def extract(image: bytes | bytearray, ent: Entry) -> bytes:
    if ent.storage == 1:
        return bytes(image[ent.key * BLOCK: ent.key * BLOCK + ent.eof])
    if ent.storage != 2:
        raise ValueError("Expected seedling or sapling SYS")
    output = bytearray()
    idx = ent.key * BLOCK
    for i in range((ent.eof + BLOCK - 1) // BLOCK):
        pointer = image[idx + i] | (image[idx + 256 + i] << 8)
        if pointer == 0:
            output.extend(b"\0" * BLOCK)
        else:
            output.extend(image[pointer * BLOCK:pointer * BLOCK + BLOCK])
    return bytes(output[:ent.eof])


def sector_convert(image: bytes, source: tuple[int, ...],
                   dest: tuple[int, ...]) -> bytes:
    if len(image) != SIZE:
        raise ValueError("Unexpected floppy image length")
    out = bytearray(SIZE)
    for track in range(35):
        for logical, physical in enumerate(dest):
            src_logical = source.index(physical)
            start = (track * 16 + src_logical) * SECTOR
            dst = (track * 16 + logical) * SECTOR
            out[dst:dst + SECTOR] = image[start:start + SECTOR]
    return bytes(out)


def build(original: bytes, program: bytes) -> bytes:
    result = bytearray(original)
    head, bitmap, count, chain, entries = root(result)
    if not all(any(e.name == name and e.file_type == 0xFF for e in entries)
               for name in BOOT_FILES):
        raise ValueError("Missing standard ProDOS 2.4.3 boot files")
    # Don't remove any OTHER files. In particular, leave Bitsy and ProDOS
    # root entry ordering untouched so ProDOS boot works as before.
    for ent in entries:
        if ent.name.startswith("SENSEI") or ent.name == NAME:
            for b in file_blocks(result, ent):
                if free_state(result, bitmap, b):
                    raise ValueError(f"Already-free block {b} in {ent.name}")
                set_free(result, bitmap, b, True)
                result[b * BLOCK:(b + 1) * BLOCK] = bytes(BLOCK)
            result[ent.offset:ent.offset + 39] = bytes(39)
            count -= 1

    if not program or len(program) > BLOCK * 256:
        raise ValueError("A2MEDIA SYS must have 1..131072 bytes")
    data_blocks = (len(program) + BLOCK - 1) // BLOCK
    needed = 1 if data_blocks == 1 else data_blocks + 1
    free = [b for b in range(BLOCK_COUNT) if free_state(result, bitmap, b)]
    if len(free) < needed:
        raise ValueError(f"Insufficient free blocks: {len(free)} < {needed}")
    chosen = free[:needed]

    if data_blocks == 1:
        key = chosen[0]
        storage = 1
        result[key * BLOCK:key * BLOCK + len(program)] = program
    else:
        storage = 2
        key = chosen[0]
        for i, b in enumerate(chosen[1:]):
            result[key * BLOCK + i] = b & 0xFF
            result[key * BLOCK + 256 + i] = b >> 8
            result[b * BLOCK:b * BLOCK + len(program[i * BLOCK:(i + 1) * BLOCK])] = (
                program[i * BLOCK:(i + 1) * BLOCK])

    for b in chosen:
        set_free(result, bitmap, b, False)

    empty = next((d * BLOCK + 4 + i * 39
                  for d in chain for i in range(1 if d == 2 else 0, 13)
                  if result[d * BLOCK + 4 + i * 39] == 0), None)
    if empty is None:
        raise ValueError("No free ProDOS root directory entry")
    result[empty:empty + 39] = bytes(39)
    result[empty] = (storage << 4) | len(NAME)
    result[empty + 1:empty + 1 + len(NAME)] = NAME.encode("ascii")
    result[empty + 16] = 0xFF           # SYS
    write16(result, empty + 17, key)
    write16(result, empty + 19, len(chosen))
    result[empty + 21:empty + 24] = len(program).to_bytes(3, "little")
    result[empty + 29] = 0x80
    result[empty + 30] = 0xE3          # ProDOS default read/write access
    write16(result, empty + 31, 0x2000)  # SYS load/entry point
    write16(result, empty + 37, 2)    # volume directory header block
    write16(result, head + 0x21, count + 1)

    verify(bytes(result), program)
    return bytes(result)


def verify(image: bytes, program: bytes) -> None:
    _, bitmap, _, _, entries = root(image)
    names = [ent.name for ent in entries]
    if any(name.startswith("SENSEI") for name in names):
        raise ValueError("Legacy SenseiPlay binary still appears in root catalog")
    if not all(x in names for x in BOOT_FILES):
        raise ValueError("Missing ProDOS/Bitsy boot file")
    found = [e for e in entries if e.name == NAME]
    if len(found) != 1:
        raise ValueError("Expected exactly one A2MEDIA.SYSTEM")
    ent = found[0]
    if ent.file_type != 0xFF or ent.aux != 0x2000:
        raise ValueError("A2MEDIA must be SYS/$FF with auxiliary type $2000")
    if extract(image, ent) != program:
        raise ValueError("A2MEDIA executable bytes do not match source")
    if any(free_state(image, bitmap, b) for b in file_blocks(image, ent)):
        raise ValueError("A2MEDIA data/index block marked free in bitmap")
    print(f"PASS: /PRODOS.2.4.3/{NAME}, SYS $FF, AUX $2000, "
          f"{ent.eof} bytes, {ent.blocks} blocks, "
          f"{len(entries)} total files, no SenseiPlay entries")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=("build", "check"))
    ap.add_argument("--base", type=Path, help="ProDOS-ordered original 140K .po")
    ap.add_argument("--system", type=Path, default=Path("dist/A2MEDIA.SYSTEM"))
    ap.add_argument("--po", type=Path, default=Path("disks/A2MEDIA-ProDOS243.po"))
    ap.add_argument("--dsk", type=Path, default=Path("disks/A2MEDIA-ProDOS243.dsk"))
    opt = ap.parse_args()
    app = opt.system.read_bytes()
    if opt.command == "build":
        if opt.base is None:
            ap.error("build requires --base ProDOS_2_4_3.po")
        result = build(opt.base.read_bytes(), app)
        opt.po.parent.mkdir(parents=True, exist_ok=True)
        opt.po.write_bytes(result)
        opt.dsk.write_bytes(sector_convert(result, PRODOS_INTERLEAVE, DOS_INTERLEAVE))
    stored = opt.po.read_bytes()
    verify(stored, app)
    dos = opt.dsk.read_bytes()
    if sector_convert(dos, DOS_INTERLEAVE, PRODOS_INTERLEAVE) != stored:
        raise ValueError("DOS-order .dsk does not match ProDOS-order .po")
    print("PASS: .dsk is true DOS 3.3 sector order, converts byte-for-byte to .po")


if __name__ == "__main__":
    main()
