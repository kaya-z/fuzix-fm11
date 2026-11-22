# FUZIX for the FM-11 — stage 1 (MMU off, swap only)

Port of `fuzix/platform-sim09` (the sim09 FUZIX: MC6809, 64KB, swap-only, tinydisk) to the FM-11, with the hardware code taken
from the MK09 FM-11 port (`mk09/bsp/fm11`, `mk09/arch/m6809/kernel.s`, `mk09/boot/ipl_fm11_2hd.s`).

**Status (2026-11-21): builds, and boots in the Fm11gtk emulator (headless, 2HD, DIPSW 0xBF) to the login prompt;
`root` (empty password) gets a shell; `ls /bin`, `echo hi > /t.txt`, `cat`, `ps`, `df` work.  Not tried on the real FM-11 yet.**

    out/fuzix_fd0.img  boot disk: IPL, kernel, root file system (raw 2HD, 1021696 bytes)   -> drive 0
    out/fuzix_fd1.img  swap disk (partition 1, type 0x7F, 480 blocks)                      -> drive 1
    out/*.hfe          the same for FlashFloppy / Gotek (mk09-port/dist/img2hfe_2hd.py)
    out/fuzix.map      link map          out/fuzix_kernel.img  the kernel in the boot image format

Emulator: `fm11 --headless FRAMES s.ppm -f0 fuzix_fd0.img -f1 fuzix_fd1.img --dipsw 0xBF --text t.txt --mute`
(`--keyat 20000 --keygap 250 --keys "||root||ls /|"`: the first two Enter answer the date and time questions of init).
Real machine: DIPSW as for the MK09 2HD boot disk; FF.CFG of the Gotek as for MK09 (shugart, pin02 nc, pin34 rdy).

## Memory map (64KB flat, MMU off)

| range | use |
|---|---|
| `0000-00FF` | interrupt stack |
| `0100-0111` | JMP table, the RAM vectors `FFF2-FFFD` point to it (written by `init_hardware`) |
| `0200-05FF` | sector buffer and code of the IPL: free after the boot, not used by the kernel (the probe sector of `devhd_init` is at `0200`) |
| `0600-6EFF` | kernel text (ends at `6E97`, 105 bytes spare) |
| `6F00-E2FF` | user space, 29KB (`PROGBASE`/`PROGTOP`); `.discard` code at `A000` is overwritten after the boot |
| `E300-F9FF` | kernel data: bss, data, common (the driver code is in `.common`; ends at `F9BD`, 67 bytes spare) |
| `FA00-FBFF` | udata (+ kernel stack) |
| `FC00-FC7F` | RAM, IPL stack; `FC80-FCFF` shared memory with the display sub CPU; `FD00-FDFF` I/O |
| `FE00-FEE7` | tty buffers (`.bssio`: kernel data is full, this RAM is free); `FFF2-FFFD` vectors (RAM) |

Why the numbers: `ls` needs 28.4KB (text+data 25834, bss 1520, 1024 for the stack, and the kernel keeps 512 bytes below the stack
for brk): that is why the user space is 29KB and the tables are small (`ITABSIZE 13`, `OFTSIZE 12`, `NBUFS 3`, `MAX_SWAPS 10`).
The swap partition holds `SWAP_SIZE` = 59 blocks per process: 480 blocks = 8 slots.

| file | from | change |
|---|---|---|
| `platform-fm11/fm11.s` | sim09.s | RAM vectors, PTM timer (50 Hz), keyboard drain, reboot through the boot ROM (`$5003`), `outchar` to the sub CPU |
| `platform-fm11/devhd.c` | devhd.c + mk09 fdc.c | MB8877 + DMA ch.1, polled; 2 sectors of 256 B = 1 block; units 0 and 1 (`hda`, `hdb`) |
| `platform-fm11/devtty.c` | devtty.c + mk09 console.c | PUT STRING console with ANSI translation, keyboard `FD00`, PTM tick |
| `platform-fm11/tricks.s` | same | `_ramtop` = `PROGTOP` (exec takes the top of the process from it) |
| `platform-fm11/fuzix.link`, `kernel.def`, `config.h`, `map.info` | same | the memory map above |
| `mkfd.py` | fuzix/mkdisk.py | raw 2HD images: IPL + MBR + kernel from lsn 2 + root fs; drive 1 = swap |
| `boot/ipl_fm11_2hd.s` | mk09 | unchanged (it reads the sim09-format boot image from lsn 2) |

## Build (maki, 2026-11-20)

Tool chain in `toolchain/` (lwtools 4.25, gcc 4.6.4 for m6809 with `gcc6809lw-4.6.4-11.patch`, byacc as `yacc`, m4); sources of FUZIX
at revision 776bfc9 (the one of the sim09 port).  `build_fm11.sh WORKDIR` does the whole build; the steps by hand:
`make TARGET=fm11 YACC=yacc ltools libs stand kernel`, `make -C Applications util cmd sh`, `build-mini-filesystem -X rootfs.img 32 1800`,
`lwasm --format=raw ipl_fm11_2hd.s`, `mkfd.py`.

## Not done / to check
* real FM-11: the FDC sequence is the one of MK09 (verified in the emulator only); the emulator does not model the swap time:
  every process switch writes and reads 29KB (116 sectors) on drive 1
* `/usr` on drive 1 (`mkfd.py -u`), `/dev/rtc` (no clock the main CPU can read), `fsck` at boot asks for date and time (just press Enter)
* stage 2: the MMU (4KB pages, 16 maps, `FD90`) for several processes in RAM: `CONFIG_MULTI`
