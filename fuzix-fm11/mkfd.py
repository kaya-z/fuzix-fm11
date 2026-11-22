#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 KAYANUMA Shin'ichi
"""mkfd.py - build the raw 2HD floppy disk images of FUZIX for the FM-11 (the FDD_2HD_256 layout of the FM-11
emulators / MK09's mk2hd.py, 1021696 bytes).

    mkfd.py --ipl ipl_2hd.bin -k fuzix.img -f rootfs.img -o fuzix_fd0.img [-b KERNELBLOCKS]
            [-S SWAP0BLOCKS] [-s SWAPBLOCKS -o1 fuzix_fd1.img [-u usrfs.img]]

Drive 0 (boot disk), in 256 byte sectors after the 128 byte sectors of track 0 side 0:
    track 0 side 0   26 x 128 bytes: the IPL in the first 512 bytes (the boot ROM reads its sectors 1-4)
    block 0          (lsn 0-1) the partition table (PC style): partition 1 = root file system (type 0x7E)
    lsn 2..          the kernel in the format of the boot ROM / IPL (mkimage.py), at most KERNELBLOCKS - 1 blocks
    block KB..       partition 1: the file system image (build-filesystem / build-mini-filesystem, big endian)
    after it         partition 2 = swap (type 0x7F) when -S is given: a machine with one drive can swap too
Drive 1 (optional), the same raw layout without an IPL: partition 1 = swap (type 0x7F, found by the kernel by its type),
    partition 2 = a file system (type 0x7E, e.g. /usr) when -u is given.
FUZIX blocks are 512 bytes = 2 sectors; a disk has 3978 sectors = 1989 blocks.
"""
import argparse, struct, sys

SECTORS = 3978
BLOCKS = SECTORS // 2
TRACK0 = 26 * 128

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('--ipl', required=True, help='the IPL (boot/ipl_fm11_2hd.s assembled with lwasm --format=raw), at most 512 bytes')
ap.add_argument('-k', '--kernel', required=True, help='kernel image for the IPL (fuzix.img of mkimage.py)')
ap.add_argument('-f', '--fs', required=True, help='root file system image')
ap.add_argument('-b', '--kblocks', type=int, default=80, help='blocks reserved for MBR + kernel image (default 80 = 40 KB)')
ap.add_argument('-s', '--swap', type=int, default=480, help='size of the swap partition on drive 1 in blocks (default 480 = 8 processes of 59)')
ap.add_argument('-S', '--swap0', type=int, default=0, help='swap partition on drive 0 after the root file system, in blocks (120 per process)')
ap.add_argument('-u', '--usr', help='file system image for partition 2 of drive 1')
ap.add_argument('-o', '--output', required=True, help='image of drive 0')
ap.add_argument('-o1', '--output1', help='image of drive 1')
a = ap.parse_args()


def part(mbr, i, typ, first, count):
    mbr[446 + 16 * i:446 + 16 * i + 16] = bytes([0, 0, 0, 0, typ, 0, 0, 0]) + struct.pack('<II', first, count)


def pad(b, blocks):
    return b + bytes(blocks * 512 - len(b))


ipl = open(a.ipl, 'rb').read()
kern = open(a.kernel, 'rb').read()
fs = open(a.fs, 'rb').read()
if len(ipl) > 512:
    sys.exit('the IPL (%d bytes) does not fit in the 4 sectors that the boot ROM reads' % len(ipl))
if len(kern) + 512 > a.kblocks * 512:
    sys.exit('kernel image (%d bytes) does not fit in %d blocks: use -b' % (len(kern), a.kblocks))
fs_blocks = (len(fs) + 511) // 512
if a.kblocks + fs_blocks + a.swap0 > BLOCKS:
    sys.exit('root file system (%d blocks) + swap (%d) do not fit: %d blocks are left' % (fs_blocks, a.swap0, BLOCKS - a.kblocks))
mbr = bytearray(512)
part(mbr, 0, 0x7E, a.kblocks, fs_blocks)
if a.swap0:
    part(mbr, 1, 0x7F, a.kblocks + fs_blocks, a.swap0)
mbr[510], mbr[511] = 0x55, 0xAA
d0 = pad(bytes(mbr) + kern, a.kblocks) + pad(fs, fs_blocks)
d0 = d0 + bytes(BLOCKS * 512 - len(d0))
open(a.output, 'wb').write(ipl.ljust(TRACK0, b'\0') + d0)
print('%s: kernel %d sectors, root %d blocks at block %d%s' % (a.output, len(kern) // 256, fs_blocks, a.kblocks,
      ', swap %d blocks at block %d' % (a.swap0, a.kblocks + fs_blocks) if a.swap0 else ''))

if a.output1:
    mbr = bytearray(512)
    mbr[510], mbr[511] = 0x55, 0xAA
    part(mbr, 0, 0x7F, 1, a.swap)
    d1 = bytes(mbr) + bytes(a.swap * 512)
    if a.usr:
        usr = open(a.usr, 'rb').read()
        ub = (len(usr) + 511) // 512
        if 1 + a.swap + ub > BLOCKS:
            sys.exit('/usr file system (%d blocks) does not fit: %d blocks are left' % (ub, BLOCKS - 1 - a.swap))
        part(mbr, 1, 0x7E, 1 + a.swap, ub)
        d1 = bytes(mbr) + bytes(a.swap * 512) + pad(usr, ub)
    d1 = d1 + bytes(BLOCKS * 512 - len(d1))
    open(a.output1, 'wb').write(bytes(TRACK0) + d1)
    print('%s: swap %d blocks' % (a.output1, a.swap))
