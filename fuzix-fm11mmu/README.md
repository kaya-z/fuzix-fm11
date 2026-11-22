# FUZIX for the FM-11 — stage 2 (MMU on, 4KB pages, memory size detected)

Second stage of the FM-11 port: the FM-11 MMU (16 maps of 16 x 4KB pages, `FD80-FD93`) with several processes in RAM
(`CONFIG_MULTI`, a 4KB page manager `bank4k.c` derived from `mm/bank8k.c`), and the installed memory (128KB..1MB) is found at boot and
all of it is used.  Design memo: `../docs/DESIGN_MMU.md`.

**Status (2026-11-21): boots in the Fm11gtk emulator to the login prompt with `--mem 128/256/384/640/1024`; `root` gets a shell, `ls`, `ps`,
`cat` work with 256KB and more.  With 128KB login, shell, `ls`, `ps` work too.
Not tried on the real FM-11.**

    ../out_mmu/fuzix_mmu_fd0.img   boot disk: IPL, kernel, root file system (raw 2HD)   -> drive 0
    ../out_mmu/fuzix_mmu_fd1.img   second disk (same layout as stage 1, the kernel does not swap yet)  -> drive 1
    ../out_mmu/*.hfe               the same for FlashFloppy / Gotek
    ../out_mmu/fuzix.map           link map

Emulator: `fm11 --headless FRAMES s.ppm -f0 fuzix_mmu_fd0.img -f1 fuzix_mmu_fd1.img --dipsw 0xBF --mem 256 --text t.txt --mute`
(`--keyat 16000 --keygap 60 --keys $'\r\r\r\r\rroot\r\rls /\r'`; the machine is slower with less memory, wait longer).
`run_emu_test.sh MEMKB FRAMES [emulator options]` is the script used for the tests (paths of the build machine).

## How it works

* **Memory detection** (`memprobe` in `fm11.s`, after MK09): through the MMU window (`$7C00`, `FD91/FD92`) the first words of the
  128KB steps are saved, `$A55A` is written to step g, read back, and compared with the steps below (an echo = not installed); the
  words are always put back.  `_ramsize`, the pool of pages and the banner (`256KiB total RAM, 208KiB available to processes`) follow from it.
* **Maps**: set 0 = kernel (identity, pages 0..15 of physical memory; `$A000`/`$B000` are windows A/B onto any physical page for copies),
  set 1 = process (`$0000-$EDFF` own pages, page 14 = udata + kernel stack of the process, page 15 = common `$F000-$FFFF`).
  Interrupts and system calls enter on the common page, switch to set 0 (`map_kernel`), and back (`map_proc_always`, set 1 is reloaded
  lazily from the 16-byte page table of the process when `set1_dirty`).
* **Pool**: physical pages 10-13, 16..(top); 9 after the boot (`.discard`).  Kernel = pages 0..9, 40KB.
* **Process size**: `a_size` of the binary if set; if 0 the process gets text+data+bss rounded up to whole 4KB pages, with 2KB (`PROC_SLACK_MIN`)
  for stack and heap at least (16KB, `PROC_SLACK_BIG`, when the pool is 160KB or more).  `chmem` gives a program more room.
* **The page of udata**: only `$EE00-$EFFF` of it is udata and kernel stack.  The top of a process is set `$200` below a page boundary so that
  the last page of the program IS the page of udata (logical pages k and 14 are the same physical page): a process costs one page less.
* **Text sharing**: `fork` does not copy the pages 1..n-1 that hold only program text (n from `a_text` at exec): the child uses the same
  physical pages (`pgref` counts the holders, `pshare` the number of pages per process; `copy_pages` skips equal pages).  `exec` replaces
  shared pages by private ones before it loads the new program, `pagemap_free` frees a page with the last holder.  Page 0 (vectors,
  zero page) is always private.  Nothing protects the text on this MMU (no write protection): it relies on programs not writing it.
* `fork` copies the other pages (4KB each).

## Limits / next

* **128KB**: the pool is 80KB (21 pages) and a shell + one command is all that fits (init 6 pages, sh 7+, the command 7+).  Bigger programs
  than `ls`/`ps` (more heap than 2KB, more pages) will not fit: swap (idle processes such as init out to the disk) is the next step.
  With 256KB (208KB pool) everything fits.
* Hardware behaviour not verified on a real machine: reads of unmapped pages, the `FD57` parity NMI of the expansion memory.
* The kernel text is tight: `.text2` ends at `$7106`, `.bss` starts at `$7200` (`fuzix.link`).  Header changes do not trigger a rebuild
  (touch the .c files).

## Build

`build_fm11mmu.sh WORKDIR` (same tool chain as stage 1, in `../toolchain`).  The platform is `platform-fm11mmu/` (copy of `platform-fm11`
plus `bank4k.c`, `um_fm11.s`, and rewritten `fm11.s`, `tricks.s`, `discard.c`).  By hand: `make TARGET=fm11mmu YACC=yacc kernel`.
