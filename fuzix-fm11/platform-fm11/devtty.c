/* SPDX-License-Identifier: GPL-2.0-only */
/* Copyright (c) 2026 KAYANUMA Shin'ichi */
#include <kernel.h>
#include <kdata.h>
#include <printf.h>
#include <stdbool.h>
#include <devtty.h>
#include <device.h>
#include <tty.h>
#include <timer.h>

/*
 *	FM-11 console.
 *
 *	Output: the display sub system.  The text is collected in a buffer and sent with one PUT STRING command ($03) in the
 *	shared memory $FC80 (HALT the sub CPU through $FD05, write the command, release).  ANSI sequences are translated to the
 *	orders of the sub system (the same code as mk09/bsp/fm11/console.c).  The buffer is sent when it is full, at a newline
 *	and before the CPU idles.  Only the tty output code touches it (never an interrupt), so no locking is needed.
 *
 *	Input: the keyboard ($FD00/$FD01, interrupt flag $FD03 bit 6), as MK09's rxdrain: $FD01 is the ASCII code when the
 *	high byte has bit 0 clear, the BREAK key ($0201) is ^C.  The tick is the PTM timer 2 (status $FD39 bit 7).
 *	The IRQ line is shared: plt_interrupt looks at both.
 */
#define FM_KEYH		(*(volatile uint8_t *)0xFD00)
#define FM_KEYL		(*(volatile uint8_t *)0xFD01)
#define FM_IFLG		(*(volatile uint8_t *)0xFD03)
#define FM_SUBST	(*(volatile uint8_t *)0xFD05)
#define FM_PTMST	(*(volatile uint8_t *)0xFD39)
#define FM_PTM2H	(*(volatile uint8_t *)0xFD3C)
#define FM_IO(a)	(*(volatile uint8_t *)(a))
#define SHARED		((volatile uint8_t *)0xFC80)

#define CON_MAX 100			/* the command has room for 124 bytes of string */

/* the tty buffers live in the RAM at $FE00 (free: the kernel data is full), see fuzix.link; they need no zeroing */
static uint8_t tbuf1[TTYSIZ] __attribute__((section(".bssio")));

struct s_queue ttyinq[NUM_DEV_TTY + 1] = {
	/* ttyinq[0] is never used */
	{NULL, NULL, NULL, 0, 0, 0},
	{tbuf1, tbuf1, tbuf1, TTYSIZ, 0, TTYSIZ / 2},
};

tcflag_t termios_mask[NUM_DEV_TTY + 1] = {
	0,
	_CSYS,
};

/* ---- output: the sub system ---- */

static uint8_t cbuf[CON_MAX] __attribute__((section(".bssio")));
static uint8_t cn;
static uint8_t cst;			/* 0 text, 1 after ESC, 2 inside ESC [ */
static uint8_t np, pv[3];
static uint8_t attr = 7;

/* wait until the sub CPU is halted, so that its shared memory can be written */
static void sub_halt(void)
{
	while (FM_SUBST & 0x80)		/* the sub CPU is still busy with the last command */
		;
	FM_SUBST = 0x80;		/* HALT request */
	while (!(FM_SUBST & 0x80))	/* wait until it is halted */
		;
}

void __attribute__((section(".common"))) con_flush(void)
{
	volatile uint8_t *p = SHARED;
	uint8_t i;

	if (!cn)
		return;
	sub_halt();
	p[1] = 0;			/* no continuation */
	p[2] = 0x03;			/* PUT STRING */
	p[3] = cn;
	for (i = 0; i < cn; i++)
		p[4 + i] = cbuf[i];
	FM_SUBST = 0;			/* release: the sub CPU runs the command */
	cn = 0;
}

static void emit(uint8_t c)
{
	if (cn >= CON_MAX)
		con_flush();
	cbuf[cn++] = c;
}

static void order(uint8_t c)
{
	emit(0x1B);
	emit(c);
}

static void setattr(void)
{
	order('G');
	emit(0x40 | (attr & 0x3F));
}

static void sgr(uint8_t n)
{
	if (n == 0)
		attr = 7;
	else if (n == 7)
		attr |= 0x08;
	else if (n == 27)
		attr &= ~0x08;
	else if (n >= 30 && n <= 37) {	/* ANSI: 1 red, 2 green, 4 blue; FM-11: 1 blue, 2 red, 4 green */
		n -= 30;
		attr = (attr & 0x38) | ((n & 4) ? 1 : 0) | ((n & 1) ? 2 : 0) | ((n & 2) ? 4 : 0);
	}
}

static void csi(uint8_t c)
{
	uint8_t i, n = pv[0];

	switch (c) {
	case 'H':
	case 'f':
		order('=');
		emit(0x20 + (pv[0] ? pv[0] - 1 : 0));
		emit(0x20 + (pv[1] ? pv[1] - 1 : 0));
		break;
	case 'J':
		order(n == 2 ? '*' : 'Y');
		break;
	case 'K':
		order('T');
		break;
	case 'L':
	case 'M':
		for (i = n ? n : 1; i; i--)
			order(c == 'L' ? 'E' : 'R');
		break;
	case 'm':
		for (i = 0; i <= np; i++)
			sgr(pv[i]);
		setattr();
		break;
	}				/* (the other sequences, e.g. the scroll region r, are dropped) */
}

static void __attribute__((section(".common"))) con_put(uint8_t c)
{
	switch (cst) {
	case 0:
		if (c == 0x1B)
			cst = 1;
		else
			emit(c);
		return;
	case 1:
		if (c == '[') {
			cst = 2;
			np = 0;
			pv[0] = pv[1] = pv[2] = 0;
		} else
			cst = 0;
		return;
	default:
		if (c >= '0' && c <= '9')
			pv[np] = pv[np] * 10 + (c - '0');
		else if (c == ';') {
			if (np < 2)
				np++;
		} else if (c >= 0x40) {
			cst = 0;
			csi(c);
		}
		return;
	}
}

/* the graphic planes and the palette on (the kanji are drawn into them), Shift_JIS kanji mode (as bsp_con_init of MK09) */
__attribute__((section(".discard")))
void con_init(void)
{
	volatile uint8_t *p = SHARED;
	uint8_t i;

	for (i = 0; i < 8; i++)
		FM_IO(0xFD98 + i) = i;	/* palette: the colour code is the colour */
	FM_IO(0xFDA0) |= 0x0F;		/* text and graphic display on */
	sub_halt();
	p[1] = 0;
	p[2] = 0x37;
	p[3] = 0xFF;
	FM_SUBST = 0;
}

/* Output for the system console (kprintf etc) */
void kputchar(uint_fast8_t c)
{
	if (c == '\n')
		tty_putc(1, '\r');
	tty_putc(1, c);
}

ttyready_t tty_writeready(uint_fast8_t minor)
{
	return TTY_READY_NOW;
}

void tty_putc(uint_fast8_t minor, uint_fast8_t c)
{
	con_put(c);
	if (c == '\n')
		con_flush();
}

void tty_sleeping(uint_fast8_t minor)
{
	con_flush();			/* a prompt without a newline is shown before the process sleeps in the read */
}

void tty_setup(uint_fast8_t minor, uint_fast8_t flags)
{
}

int tty_carrier(uint_fast8_t minor)
{
	return 1;
}

void tty_interrupt(void)
{
}

void tty_data_consumed(uint_fast8_t minor)
{
}

/* ---- input and the tick ---- */

void plt_interrupt(void)
{
	uint8_t hi, lo;

	while (FM_IFLG & 0x40) {	/* a key code */
		hi = FM_KEYH;
		lo = FM_KEYL;		/* (reading it takes the code) */
		if (hi == 2)
			tty_inproc(1, 3);	/* BREAK = ^C */
		else if (!(hi & 1))
			tty_inproc(1, lo);	/* an ASCII key; function and cursor keys are not used */
	}

	if (FM_PTMST & 0x80) {		/* PTM: a timer interrupt is pending */
		(void)FM_PTM2H;		/* reading the counter after the status clears the flag */
		timer_interrupt();
	}
}

void plt_reinterrupt(void)
{
	panic("reint");
}
