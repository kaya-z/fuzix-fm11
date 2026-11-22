/* SPDX-License-Identifier: GPL-2.0-only */
/* Copyright (c) 2026 KAYANUMA Shin'ichi */
#include <kernel.h>
#include <timer.h>
#include <kdata.h>
#include <printf.h>
#include <device.h>
#include <devtty.h>

void map_init(void)
{
	kprintf("FM-11: MC6809, 64K RAM (MMU off), 29K for processes\n");
}
