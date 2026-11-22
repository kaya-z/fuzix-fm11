/* SPDX-License-Identifier: GPL-2.0-only */
/* Copyright (c) 2026 KAYANUMA Shin'ichi */
#include <kernel.h>
#include <timer.h>
#include <kdata.h>
#include <printf.h>
#include <device.h>
#include <devtty.h>

extern uint8_t memgrp;

void map_init(void)
{
}

/*
 *	The pages for the processes: the physical pages 10-13 (the kernel does not use $A000-$DFFF; the page 9 holds the end of the
 *	discard area, it is added by plt_discard) and everything from
 *	page 16 up (the memory that fm11.s found, 32 pages in every step of 128K, the pages $F0 and above are ROM).
 *	The page 14 is the udata page of the first process, 15 the common page, 0-8 the kernel.
 */
void pagemap_init(void)
{
	uint16_t pg;
	uint16_t top = (uint16_t) memgrp << 5;

	if (top > MAX_MAPS)
		top = MAX_MAPS;
	for (pg = 10; pg < 14; pg++)
		pagemap_add(pg);
	for (pg = 16; pg < top; pg++)
		pagemap_add(pg);
	procmem = (4 + top - 16) << 2;
	kprintf("FM-11: MC6809, %dK RAM (MMU on), %dK for processes\n", ramsize, procmem);
}
