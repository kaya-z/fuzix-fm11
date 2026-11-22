; SPDX-License-Identifier: GPL-2.0-only
; Copyright (c) 2026 KAYANUMA Shin'ichi
	;
	; FUZIX platform for the FUJITSU FM-11 (6809 mode, MMU off = flat 64K RAM).
	; Everything the hardware needs is taken from the MK09 port (mk09/bsp/fm11, mk09/arch/m6809/kernel.s).
	;
	; Memory map
	;	0000-00FF	Interrupt stack (borrowed as swap stack)
	;	0100-0111	Vectors: JMP table, the RAM vectors $FFF2-$FFFD point here
	;	0200-02FF	sector buffer of the IPL; scratch of the disk probe (free after the boot)
	;	0300-05FF	IPL (the boot ROM loads it to $0400; its variables are at $03C0-$03FF)
	;	0600-6EFF	Kernel code
	;	6F00-E2FF	User space (29K)
	;	E300-F9FF	Kernel data (bss, data, common)
	;	FA00-FBFF	udata
	;	FC00-FC7F	RAM (the IPL stack)
	;	FC80-FCFF	memory shared with the display sub CPU
	;	FD00-FDFF	I/O
	;	FE00-FEFF	tty buffers (.bssio); FF00-FFFF RAM; FFF2-FFFD are the interrupt vectors (RAM on the FM-11), FFFE/FFFF reset (ROM)
	;

	.module fm11

	; exported
	.globl map_kernel
	.globl map_proc
	.globl map_proc_a
	.globl map_proc_always
	.globl map_save
	.globl map_restore
        .globl init_early
        .globl init_hardware
        .globl _program_vectors
	.globl _need_resched

	.globl _ramsize
	.globl _procmem

	; imported
	.globl unix_syscall_entry
	.globl null_handler
	.globl interrupt_handler
	.globl _con_init
	.globl _con_flush

	; exported debugging tools
	.globl _plt_monitor
	.globl _plt_reboot
	.globl _plt_idle
	.globl outchar
	.globl ___hard_di
	.globl ___hard_ei
	.globl ___hard_irqrestore

	include "kernel.def"
	include "../../cpu-6809/kernel09.def"


		.area .vectors
	;
	;	The RAM vectors $FFF2-$FFFD jump to these (the order of sim09: SWI3 SWI2 SWI NMI IRQ FIRQ)
	;
	jmp badswi_handler			; 0x100 SWI3
	jmp badswi_handler			; 0x103 SWI2
	jmp unix_syscall_entry 			; 0x106 SWI (system call)
	jmp badswi_handler			; 0x109 NMI
	jmp interrupt_handler			; 0x10C IRQ (PTM timer, keyboard)
	jmp firq_handler			; 0x10F FIRQ

	.area .discard

init_early:
	ldx #null_handler
	stx 1
	lda #0x7E
	sta 0
	rts

init_hardware:
	ldd #64
	std _ramsize
	ldd #29
	std _procmem

	; the hardware vectors are RAM on the FM-11: $FFF2 SWI3, $FFF4 SWI2, $FFF6 FIRQ, $FFF8 IRQ, $FFFA SWI, $FFFC NMI
	ldx #0x0100
	stx 0xFFF2
	ldx #0x0103
	stx 0xFFF4
	ldx #0x010F
	stx 0xFFF6
	ldx #0x010C
	stx 0xFFF8
	ldx #0x0106
	stx 0xFFFA
	ldx #0x0109
	stx 0xFFFC

	lda #0x01			; the boot ROM overlay at $5000-$5FFF off, MMU off (the IPL did it, be sure)
	sta FM_MCFG

	; the display: graphic planes and palette on, kanji mode (C, bsp_con_init of MK09)
	jsr _con_init

	; empty the keyboard (a key code left from the boot)
kbd_drain:	lda FM_IFLG
	bita #0x40
	beq kbd_done
	lda FM_KEYH
	lda FM_KEYL
	bra kbd_drain
kbd_done:

	; PTM (the same sequence as the MK09 kernel): reset, timer 2 = 16 bit, continuous, internal clock E (2 MHz),
	; interrupt on, 40000 counts = 50 Hz
	lda #0x01
	sta FM_PTMC2			; CR2 bit 0 = 1: $FD38 is CR1
	sta FM_PTMC13			; CR1 bit 0 = 1: reset the timers
	sta FM_PTMC2			; (the reset cleared CR2: select CR1 again)
	clr FM_PTMC13			; CR1 = 0: all timers run
	lda #0x42			; CR2: interrupt enable, 16 bit, continuous, E clock, $FD38 = CR3
	sta FM_PTMC2
	ldd #40000
	std FM_PTM2H			; starts the timer
	lda #0x90			; interrupt mask: keyboard and PTM
	sta FM_IMSK
	rts

	.area .common

_plt_reboot:
	; as the reboot command of MK09 (mk09/apps/reboot.c): the routine is copied to $0200 (the sector buffer of the IPL), runs
	; with the interrupts off, clears the memory and jumps to the boot loader entry of the boot ROM ($5003, as after the BREAK key;
	; the reset vector would run the memory test first).  The caller has synced the file systems.
	orcc #0x50
	lds #0x0100
	ldx #reboot_rt
	ldy #0x0200
reboot_cp:
	lda ,x+
	sta ,y+
	cmpx #reboot_end
	bne reboot_cp
	jmp 0x0200

reboot_rt:
	clr FM_IMSK			; no interrupt
	lda #0x01
	sta FM_PTMC2			; PTM: reset the timers
	sta FM_PTMC13
	ldx #0x0110			; clear $0110-$01FF
reboot_c1:
	clr ,x+
	cmpx #0x0200
	bne reboot_c1
	ldx #0x0300			; clear $0300-$FBFF
reboot_c2:
	clr ,x+
	cmpx #0xFC00
	bne reboot_c2
	clr FM_MCFG			; the boot ROM is mapped at $5000 again
	ldx #0x5003
	jmp ,x
reboot_end:

_plt_monitor:
	orcc #0x10
halted:	bra halted

; Wait for an interrupt: SYNC with IRQs enabled.  Send what the console has collected first.
_plt_idle:
	jsr _con_flush
	andcc #0xef
	sync
	rts

___hard_di:
	tfr cc,b		; return the old irq state
	orcc #0x10
	rts
___hard_ei:
	andcc #0xef
	rts

___hard_irqrestore:		; B holds the data
	tfr b,cc
	rts

;
; COMMON MEMORY PROCEDURES FOLLOW
;
;	Our vectors live in a fixed block and are not banked out. Likewise
;	No memory management (stage 1): the user process always lives in 6F00-E2FF
;
_program_vectors:
map_kernel:
map_restore:
map_proc:
map_proc_always:
map_proc_a:
map_save:
	rts

firq_handler:
badswi_handler:
	rti

;
;	debug output on the console
;
outchar:
	; debug output (panic and switch failures): one character straight to the display sub system, as a PUT STRING of one byte
	pshs a,b,x
oc_w1:	ldb FM_SUBST			; the sub CPU is still busy with the last command
	bmi oc_w1
	ldb #0x80			; HALT request
	stb FM_SUBST
oc_w2:	ldb FM_SUBST			; wait until it is halted
	bpl oc_w2
	ldx #0xFC80
	clr 1,x				; no continuation
	ldb #3
	stb 2,x				; PUT STRING
	ldb #1
	stb 3,x				; one byte
	sta 4,x
	clr FM_SUBST			; release: the sub CPU runs the command
	puls a,b,x
	rts

_need_resched:
	.db 0
