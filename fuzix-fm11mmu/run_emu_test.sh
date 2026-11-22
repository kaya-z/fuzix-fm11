#!/bin/sh
# usage: run.sh MEMKB FRAMES [keys...]   (build + disk + emulator)
cd $HOME/FUZIX && export FUZIX_ROOT=$PWD CPU=6809 USERCPU=6809 TARGET=fm11mmu YACC=yacc && export PATH=$HOME/mnt/FM-11/fuzix-port/toolchain/bin:$PWD/Build/tools:$PATH
make TARGET=fm11mmu YACC=yacc kernel 2>&1 | grep -E "rror|undefined|overlap|fuzix.img" | head
W=$HOME/mmu_test
python3 $HOME/mnt/FM-11/fuzix-port/fuzix-fm11/mkfd.py --ipl $HOME/mnt/FM-11/fuzix-port/diskimage/no_mmu/ipl_2hd.bin -k Kernel/platform/platform-fm11mmu/fuzix.img -f $HOME/rootfs.img -b 80 -o $W/fd0.img -o1 $W/fd1.img >/dev/null
MEM=$1; FR=$2; shift; shift
cd $HOME/mnt/FM-11/emulator/Fm11gtk && LD_LIBRARY_PATH=$HOME/stub timeout 160 ./fm11 --headless $FR $W/o.ppm -f0 $W/fd0.img -f1 $W/fd1.img --dipsw 0xBF --mem $MEM --text $W/t.txt --mute "$@" 2>&1 | tail -2
grep -v '^$' $W/t.txt | tail -${LINES_TAIL:-25}
