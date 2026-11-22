#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Build FUZIX for the FM-11 (6809, MMU off, 2HD floppies): the kernel, libraries, a minimal set of commands, the root file system and
# the raw 2HD disk images.  Derived from fuzix/build.sh of the sim09 port.  Run on maki 2026-11-20/21 (boots to a login in the Fm11gtk emulator).
#
#   build_fm11.sh WORKDIR
#
# Needs on PATH (the tool chain of this port is in ../toolchain: export PATH=$PWD/../toolchain/bin:$PATH): the m6809 gcc 4.6.4 (tools/build_gcc6809.sh) and lwtools (tools/install_cmoc.sh),
# perl, python3, gcc, make, yacc (bison -y), git and network access to GitHub for the FUZIX sources.
# Results: WORKDIR/fuzix_fd0.img (boot disk: IPL, kernel, root fs) and WORKDIR/fuzix_fd1.img (swap), raw 2HD, 1021696 bytes each:
#   ./fm11 -f0 fuzix_fd0.img -f1 fuzix_fd1.img --dipsw 0xBF
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${1:?usage: build_fm11.sh WORKDIR}
FUZIX_URL=https://github.com/EtchedPixels/FUZIX.git
FUZIX_REV=776bfc942c0ce3f5b86e4c48848d154a60ff1cb6       # the version the sim09 port was made with
ISIZE=${ISIZE:-32}                                       # inodes (in units of 16 per block): 512 inodes on a floppy
BSIZE=${BSIZE:-1800}                                     # blocks of the root file system (900 KB: a disk has 1989 blocks)
KBLOCKS=${KBLOCKS:-80}                                   # blocks for the partition table and the kernel image
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
for t in m6809-unknown-gcc lwasm lwlink perl python3 yacc git; do
    command -v $t >/dev/null || { echo "missing: $t"; exit 1; }
done

if [ ! -d "$WORK/FUZIX/.git" ]; then
    mkdir -p "$WORK/FUZIX" && cd "$WORK/FUZIX"
    git init -q . && git remote add origin "$FUZIX_URL"
    git fetch -q --depth 1 origin "$FUZIX_REV" && git checkout -q FETCH_HEAD
fi
cd "$WORK/FUZIX"
[ "$(git rev-parse HEAD)" = "$FUZIX_REV" ] || { echo "$WORK/FUZIX is not at $FUZIX_REV"; exit 1; }

# the platform
rm -rf Kernel/platform/platform-fm11
cp -r "$HERE/platform-fm11" Kernel/platform/platform-fm11

export FUZIX_ROOT=$PWD CPU=6809 USERCPU=6809 TARGET=fm11 YACC=yacc
export PATH="$PWD/Build/tools:$PATH"
J=${JOBS:-4}
make TARGET=fm11 YACC=yacc kclean >/dev/null 2>&1 || true
make -j$J TARGET=fm11 YACC=yacc ltools libs stand kernel
(cd Applications && make -k util cmd sh)

# root file system (big endian, 512 byte blocks)
(cd Standalone/filesystem-src && ./build-mini-filesystem -X "$WORK/rootfs.img" "$ISIZE" "$BSIZE")

# the IPL of the FM-11 (the one of MK09) and the disks
lwasm --format=raw -o "$WORK/ipl_2hd.bin" "$HERE/boot/ipl_fm11_2hd.s"
python3 "$HERE/mkfd.py" --ipl "$WORK/ipl_2hd.bin" -k Kernel/platform/platform-fm11/fuzix.img -f "$WORK/rootfs.img" \
    -b "$KBLOCKS" -o "$WORK/fuzix_fd0.img" -o1 "$WORK/fuzix_fd1.img"
echo "done: $WORK/fuzix_fd0.img $WORK/fuzix_fd1.img"
