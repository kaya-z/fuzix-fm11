/* SPDX-License-Identifier: GPL-2.0-only */
/* Copyright (c) 2026 KAYANUMA Shin'ichi */
#include <kernel.h>
#include <kdata.h>
#include <printf.h>
#include <stdbool.h>
#include <tinydisk.h>
#include <device.h>

/*
 *	FM-11 2HD floppy disks (units 0 and 1 = hda, hdb): the MB8877 at $FD30-$FD37, the data by DMA channel 1, polled.
 *	This is fdc.c of MK09 (mk09/bsp/fm11/fdc.c), which has the sequence of the boot ROM ($5516...).
 *
 *	The raw 2HD disk has 77 tracks of 2 sides of 26 sectors.  The sectors of track 0 side 0 are 128 bytes (FM, the IPL: the
 *	boot ROM reads its sectors 1-4); all the others are 256 bytes.  The 256 byte sectors start behind that track:
 *	    lsn 0 = track 0 side 1 sector 1, then 26 sectors per side ... (3978 sectors = 1989 FUZIX blocks)
 *	A FUZIX block is two sectors.  The layout of the disk is the one of sim09: the partition table in the lsn 0-1 (block 0), the
 *	kernel image from the lsn 2 (the IPL reads it from there), the file systems after it (mkfd.py).
 *
 *	The driver is in .common, as the kernel text below $6C00 (the user space) is full.  The DMA address is the physical
 *	address: the MMU is off, the buffers are below $FC00.
 */
#define FDC_CMD		(*(volatile uint8_t *)0xFD30)
#define FDC_TRK		(*(volatile uint8_t *)0xFD31)
#define FDC_SEC		(*(volatile uint8_t *)0xFD32)
#define FDC_DAT		(*(volatile uint8_t *)0xFD33)
#define FDC_SIDE	(*(volatile uint8_t *)0xFD34)
#define FDC_DRV		(*(volatile uint8_t *)0xFD35)
#define FDC_IRQ		(*(volatile uint8_t *)0xFD37)

#define DMA_CH		1
#define DMA_ADR_H	(*(volatile uint8_t *)(0xFD40 + 4 * DMA_CH))
#define DMA_ADR_L	(*(volatile uint8_t *)(0xFD41 + 4 * DMA_CH))
#define DMA_CNT_H	(*(volatile uint8_t *)(0xFD42 + 4 * DMA_CH))
#define DMA_CNT_L	(*(volatile uint8_t *)(0xFD43 + 4 * DMA_CH))
#define DMA_MODE	(*(volatile uint8_t *)(0xFD50 + DMA_CH))
#define DMA_BANK	(*(volatile uint8_t *)(0xFD94 + DMA_CH))
#define DMA_ENA		(*(volatile uint8_t *)0xFD54)
#define DMA_IMSK	(*(volatile uint8_t *)0xFD55)
#define DMA_CFG		(*(volatile uint8_t *)0xFD56)
#define DMA_CLR		(*(volatile uint8_t *)0xFD57)

#define SECTORS		3978		/* 256 byte sectors of a disk */

static uint8_t curtrk[2];		/* the track of each unit's head (the controller has one track register) */
static uint8_t curunit = 0xFF;

/* the command is done when the interrupt flag is set (the controller has no interrupt here) */
static uint8_t __attribute__((section(".common"))) done(void)
{
	uint8_t o, i;
	uint16_t n;

	for (o = 0; o < 6; o++)
		for (i = 0; ; i++) {
			for (n = 0; n < 0x4000; n++)
				if (FDC_IRQ & 0x40)
					return 0;
			if (i == 3)
				break;
		}
	return 1;
}

static uint8_t __attribute__((section(".common"))) seek(uint8_t unit, uint8_t track)
{
	uint8_t r;

	if (track == 0) {
		FDC_CMD = 0x0A;			/* restore */
	} else {
		FDC_DAT = track;
		FDC_CMD = 0x1A;			/* seek */
	}
	r = done();
	if (!r)
		curtrk[unit] = track;
	return r;
}

static void __attribute__((section(".common"))) select(uint8_t unit)
{
	if (unit != curunit) {
		FDC_DRV = (FDC_DRV & 0x80) | unit;	/* the boot ROM writes the unit number only (bit 7 as it was) */
		FDC_TRK = curtrk[unit];			/* the track register of that unit */
		curunit = unit;
	}
}

extern uint8_t td_page, td_raw;

/* a = the address in the kernel map, or the offset in the physical page td_page for the swap (td_raw 2): the DMA uses physical addresses */
static void __attribute__((section(".common"))) dma(uint16_t a, uint16_t n, uint8_t mode)
{
	uint8_t bank = 0;

	if (td_raw == 2) {
		uint32_t phys = ((uint32_t)td_page << 12) + a;
		a = (uint16_t)phys;
		bank = (uint8_t)(phys >> 16);
	}
	DMA_CLR = 0;
	DMA_ADR_H = (uint8_t)(a >> 8);
	DMA_ADR_L = (uint8_t)a;
	DMA_CNT_H = (uint8_t)(n >> 8);
	DMA_CNT_L = (uint8_t)n;
	DMA_BANK = bank;			/* physical address bits 19-16 */
	DMA_MODE = mode;
}

/* one 256 byte sector: 1 = good */
static int __attribute__((section(".common"))) fd_sector(uint8_t unit, bool is_read, uint16_t lsn, uint8_t *dptr)
{
	uint8_t track, side, sec, tries, st;
	uint16_t ts;

	if (lsn >= SECTORS)
		return 0;
	/* ts = lsn / 26 + 1 (track side, 0 is the 128 byte track), sec = lsn % 26 + 1: no division helper in the kernel */
	ts = 1;
	while (lsn >= 26) {
		lsn -= 26;
		ts++;
	}
	sec = (uint8_t)lsn + 1;
	track = (uint8_t)(ts >> 1);
	side = (uint8_t)(ts & 1);
	select(unit);
	for (tries = 0; tries < 4; tries++) {
		if (tries == 2)
			seek(unit, 0);		/* recalibrate, then seek again */
		if (curtrk[unit] != track && seek(unit, track))
			continue;
		FDC_SIDE = side | 0x40;		/* bit 6 = density (1 for the MFM tracks), bit 4 = 0 */
		FDC_SEC = sec;
		dma((uint16_t)dptr, 256, is_read ? 0x04 : 0x05);
		FDC_CMD = is_read ? 0x80 : 0xA0;
		if (done())
			continue;
		st = FDC_CMD;			/* status: not ready, (write protect), record type / write fault, not found, CRC, lost data */
		if (!(st & (is_read ? 0x9C : 0xFC)))
			return 1;
	}
	return 0;
}

static int __attribute__((section(".common"))) fd_xfer(uint_fast8_t unit, bool is_read, uint32_t block, uint8_t *dptr)
{
	uint16_t lsn;

	if (block >= SECTORS / 2)
		return 0;
	lsn = (uint16_t)block << 1;
	if (!fd_sector(unit, is_read, lsn, dptr))
		return 0;
	return fd_sector(unit, is_read, lsn + 1, dptr + 256);
}

__attribute__((section(".discard")))
void devhd_init(void)
{
	/* DMA channel 1 on, no interrupt of it; restore unit 0 */
	DMA_ENA |= 1 << DMA_CH;
	DMA_IMSK &= ~(1 << DMA_CH);
	DMA_CFG = 0x08;
	FDC_DRV = FDC_DRV & 0x80;
	curunit = 0;
	seek(0, 0);

	/* Both drives, with a partition table; a drive without a disk is skipped (it takes a few seconds to give up).
	   Page 2 (0200-02FF) is free at this point: it was the sector buffer of the IPL, it is the scratch sector of the probe. */
	{
		uint8_t unit;
		for (unit = 0; unit < 2; unit++)
			if (fd_sector(unit, true, 0, (uint8_t *)0x0200))
				td_register(unit, fd_xfer, td_ioctl_none, 1);
	}
}
