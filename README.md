# A2MEDIA.SYSTEM

Independent **ProDOS 8 / 80-column a2fpga MCU media remote** for the 128K Apple IIe and Apple IIgs. This is **not a SenseiPlay derivative**. The J2R11 HxCMOD player and the existing FPGA/MCU beta binaries remain unchanged.

## First executable: P0

The initial 6502 application, A2MEDIA.SYSTEM, is a raw ProDOS 8 **SYS ($FF)** binary with load/entry address **$2000**. It activates internal 80-column firmware, detects the existing ROMless M1 physical-slot-3 mailbox ($C0B0–$C0BF), and operates the commands already present in J2R11.

| Key | M1 operation | Command |
|---|---|---|
| I | Ping / probe | $01 |
| S | Stop | $03 |
| N / P | Next / Previous | $06 / $07 |
| L | Replay last MCU-selected MOD | $02 |
| F | Jukebox from last folder | $04 |
| T | Jukebox from last folder plus subfolders | $05 |
| O / R | Single MOD play once / repeat | $08 / $09 |
| Q / ESC | Return through ProDOS MLI QUIT | $65 |

The program shows MCU mailbox readiness, FPGA-reported PLAYING state and last command/result bytes. It does **not** fabricate filenames or directories: M1 has an Apple-to-MCU FIFO, not a reply channel.

**Important:** M1 RTL hard-codes physical Apple slot 3 ($C0B0), although earlier audio development often used slot 4. Neither IIe nor IIgs physical mailbox access has been proven by the audio tests. From BASIC, the non-destructive signature check is:

    PRINT PEEK(49328),PEEK(49329),PEEK(49330)

Expected: **77 66 1** only when the installed FPGA and physical bus respond. Without M1, the app displays NOT DETECTED, sends no commands and supports Q/ESC exit. **P0 has not yet been tested on physical Apple hardware.**

## Build / distribution

Install cc65 (ca65, ld65), Python 3 and Make:

    make
    make check

Generated raw binary: **dist/A2MEDIA.SYSTEM**, with no load header. When copying to a ProDOS disk, explicitly set **SYS filetype $FF**; the filename extension alone does not set ProDOS metadata. For booting, pair the SYS program with ProDOS 8 and configure it as the startup application.

GitHub Actions compiles and validates the binary, uploads a workflow artifact, and attempts to commit it to dist/A2MEDIA.SYSTEM on main. Check the workflow log and SHA-256 for the exact build.

## Bootable ProDOS 2.4.3 floppy disk images

Two **140 KB (143,360-byte)** images are committed under `disks/`:

- **[A2MEDIA-ProDOS243.po](disks/A2MEDIA-ProDOS243.po)** — ProDOS block/sector order; recommended for ProDOS-aware tools, Cadius, and most modern emulators
- **[A2MEDIA-ProDOS243.dsk](disks/A2MEDIA-ProDOS243.dsk)** — genuine DOS 3.3 sector ordering, converted from the same `.po`, suitable for software expecting DOS-order `.dsk`

Disk volume is **/PRODOS.2.4.3**. The file `A2MEDIA.SYSTEM` is installed in its root directory with ProDOS file type **SYS ($FF)**, auxiliary type **$2000**, **1,572 bytes**, and **five storage blocks** (sapling index plus four data blocks).

The original `PRODOS`, `BITSY.BOOT`, `QUIT.SYSTEM`, `BASIC.SYSTEM` and all other official distribution files remain in place, in their original catalog order. **Bitsy Bye remains the boot launcher**, and you can choose A2MEDIA.SYSTEM there; the disk does not automatically replace the launcher. No SenseiPlay8 files appear in the catalog.

**Source provenance:** This disk was generated from the official [ProDOS 2.4.3 release image](https://github.com/ProDOS-8/ProDOS8-Releases/blob/master/ProDOS_2_4_3.po), Git blob `d464c92578d4ed15dc4acd49eee43e51256808fd`. The specific earlier SenseiPlay8-modified conversation image was no longer available to edit byte-for-byte; the *official* release was used as the clean source instead. Only root directory metadata, allocation bitmap, and five newly allocated blocks changed. Boot sectors and existing file content are unchanged.

Validate the included images locally:

~~~powershell
py -3 tools/prodos_disk.py check
~~~

To regenerate both images from the original ProDOS 2.4.3 ProDOS-order `.po` file and the current A2MEDIA executable:

~~~powershell
py -3 tools/prodos_disk.py build --base ProDOS_2_4_3.po
~~~

The builder also removes any root-level files whose names start with `SENSEI` if you later supply a prior SenseiPlay-modified ProDOS-order image. Both images are **disk-structure verified**, not yet hardware-booted on Apple IIe/IIgs.

## Roadmap

1. P0: 80-column ProDOS 8 M1 controls; physical IIe/IIgs tests.
2. M2: a separate a2fpga development branch adds MCU-to-Apple reply FIFO and safe disk-thread FAT directory enumeration. Then A2MEDIA gets an 80x24 SD/USB file browser, selected MOD playback, and start-at-file.
3. Internet radio streams, presets, audio sources other than MOD, and other a2fpga media services.

Original J2R11 beta FPGA/MCU binaries remain untouched.

## Source

- src/a2media.s: original 6502 application; no SenseiPlay playback code.
- src/prodos8-system.cfg: ProDOS 8 load/entry $2000.
- tools/check_sys.py: compiled binary contract verification.
- .github/workflows/build.yml: automated build and binary publication.

Copyright (c) 2026 Petar Puskarich / contributors. No public redistribution license selected.
