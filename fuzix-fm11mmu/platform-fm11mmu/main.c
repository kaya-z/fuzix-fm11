/* SPDX-License-Identifier: GPL-2.0-only */
/* Copyright (c) 2026 KAYANUMA Shin'ichi */
#include <kernel.h>
#include <timer.h>
#include <kdata.h>
#include <printf.h>
#include <device.h>
#include <devtty.h>


uint16_t swap_dev = 0xFFFF;

uint8_t plt_param(char *p)
{
    return 0;
}

void do_beep(void)
{
}

void plt_discard(void)
{
    /* the kernel (data, bss) reaches into the page 9 now: it is not given to the processes */
}
