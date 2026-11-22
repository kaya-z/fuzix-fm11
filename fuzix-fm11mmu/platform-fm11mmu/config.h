/* SPDX-License-Identifier: GPL-2.0-only */
/* Copyright (c) 2026 KAYANUMA Shin'ichi */
/* FUZIX for the FUJITSU FM-11, stage 2: the MMU is used (see DESIGN_MMU.md) */

/* Enable to make ^Z dump the inode table for debug */
#undef CONFIG_IDUMP
/* Enable to make ^A drop back into the monitor */
#undef CONFIG_MONITOR
/* Profil syscall support (not yet complete) */
#undef CONFIG_PROFIL
/* Multiple processes in memory at once */
#define CONFIG_MULTI
/* The pages of 4K of the FM-11 MMU (bank4k.c next to this file) */
#define CONFIG_BANK4K

/* The kernel runs in map set 0, the process in map set 1 (fm11.s); udata is the top of the page of
   logical $E000 of every process: $EE00-$EFFF, with the kernel stack in it */
#define UDATA_SIZE  0x0200
#define CONFIG_BANKS	1
#define MAX_MAPS	240		/* physical pages $00-$EF: the pages above are ROM */
#define PAGE_INVALID	0xFF
#define PAGE_UDATA	14		/* the logical page of udata */

#define PTABSIZE	10

/* Everything goes through the buffers: the DMA of the FDC cannot reach into a process directly */
#define CONFIG_LARGE_IO_DIRECT(x)	0

#define MAXTICKS 25
#define CONFIG_PARENT_FIRST

/* Console: the display sub system of the FM-11 (PUT STRING), keyboard $FD00 */

#define TICKSPERSEC 50   /* Ticks per second: MC6840 PTM timer 2, 40000 counts of E (2MHz) */
#define PROGBASE    0x0100  /* also data base */
#define PROGLOAD    0x0100  /* also data base */
#define PROC_SLACK  0x0800  /* room for stack and heap for a program with no size set (128K machine: the pool is 80K) */
#define PROC_SLACK_MIN 0x0800
#define PROC_RESERVE 2
#define PROC_SLACK_BIG 0x4000 /* the same when there is memory (the pool is PROC_BIGMEM K or more) */
#define PROC_BIGMEM 160
#define PROGTOP     0xEE00  /* Top of program: udata from $EE00 */

/* The root file system is the first partition of the first disk (2HD, partition table in LSN 0-1,
   the kernel image from LSN 2: the same layout as sim09, see mkfd.py) */
#define BOOTDEVICENAMES "hd#"
#define CMDLINE	"hda1"	  /* Location of root dev name */

/* Device parameters */
#define NUM_DEV_TTY 1
#define TTYDEV   513	 /* Device used by kernel for messages, panics */
#define NBUFS    4       /* Number of block buffers */
#define NMOUNTS	 2	  /* Number of mounts at a time */

#define CONFIG_TD_NUM	2

/* Swap: the partition of type 0x7F (the second disk) is found at boot; a process is swapped out as a whole (the 4K pages that it
   has, at most 15 = 120 blocks of 512 bytes) when fork, exec or a swap in needs pages and there are none */
#define CONFIG_DYNAMIC_SWAP
extern uint16_t swap_dev;
#define SWAPDEV     swap_dev
#define SWAP_SIZE   0x78		/* blocks per process: 15 pages of 8 blocks */
#define MAX_SWAPS   16
#define swap_map(x)	((uint8_t *)(x))

#define plt_copyright(x)

/* the FM-11 has no clock that the main CPU can read: no /dev/rtc */

#define CONFIG_SMALL
