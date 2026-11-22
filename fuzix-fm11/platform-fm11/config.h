/* SPDX-License-Identifier: GPL-2.0-only */
/* Copyright (c) 2026 KAYANUMA Shin'ichi */
/* Enable to make ^Z dump the inode table for debug */
#undef CONFIG_IDUMP
/* Enable to make ^A drop back into the monitor */
#undef CONFIG_MONITOR
/* Profil syscall support (not yet complete) */
#undef CONFIG_PROFIL
/* Multiple processes in memory at once */
#undef CONFIG_MULTI
/* Pure swap: one process in memory, the others are on the swap partition */
#define CONFIG_SWAP_ONLY
#define CONFIG_SPLIT_UDATA
#define UDATA_BLKS 1
#define CONFIG_USERMEM_DIRECT

#define CONFIG_LEVEL_0		/* Minimal system */

#define CONFIG_BANKS	1
/* And swapping: the swap partition is found by its type in the partition table */
#define CONFIG_DYNAMIC_SWAP

extern uint16_t swap_dev;

#define SWAPDEV     swap_dev    /* From partiton */
#define SWAP_SIZE   0x3B	/* 512 byte blocks: 58 for 6F00-E2FF and the udata block */
#define SWAPBASE    0x6F00	/* We swap the lot, including stashed uarea */
#define SWAPTOP     0xE300	/* so it is a round number of 512 byte sectors */
#define UDATA_SIZE  0x0200	/* one block */
#define MAX_SWAPS   10

#define PTABSIZE	8

/* Permit large I/O requests to bypass cache and go direct to userspace */
#define CONFIG_LARGE_IO_DIRECT(x)	1

/* Allow for our swap heavy nature */
#define MAXTICKS 25
#define CONFIG_PARENT_FIRST	/* For pure swap this is far faster */

/* Console: the display sub system of the FM-11 (PUT STRING), keyboard $FD00 */

#define TICKSPERSEC 50   /* Ticks per second: MC6840 PTM timer 2, 40000 counts of E (2MHz) */
#define PROGBASE    0x6F00  /* also data base */
#define PROGLOAD    0x6F00  /* also data base */
#define PROGTOP     0xE300  /* Top of program: kernel data from here */

/* The root file system is the first partition of the first disk (2HD, partition table in LSN 0-1,
   the kernel image from LSN 2: the same layout as sim09, see mkfd.py) */
#define BOOTDEVICENAMES "hd#"
#define CMDLINE	"hda1"	  /* Location of root dev name */

/* Device parameters */
#define NUM_DEV_TTY 1
#define TTYDEV   513	 /* Device used by kernel for messages, panics */
#define NBUFS    3       /* Number of block buffers (3: the user space gets 512 bytes more) */
#define NMOUNTS	 2	  /* Number of mounts at a time */
#define swap_map(x)	((uint8_t *)(x))

#define CONFIG_TD_NUM	2

#define plt_copyright(x)

/* the FM-11 has no clock that the main CPU can read: no /dev/rtc */

#define CONFIG_SMALL


/* The data of the kernel must end below the udata at $FA00 and the user space wants every 512 bytes: small tables
   (inodes 75 bytes each, open files 8 bytes each; the default of CONFIG_SMALL is 20 and 15) */
#define ITABSIZE	13
#define OFTSIZE		12
