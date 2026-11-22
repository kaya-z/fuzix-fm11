; SPDX-License-Identifier: GPL-2.0-only
; Copyright (c) 2026 KAYANUMA Shin'ichi
	;
	; FUZIX platform for the FUJITSU FM-11 (6809 mode, MMU off = flat 64K RAM).
	; Everything the hardware needs is taken from the MK09 port (mk09/bsp/fm11, mk09/arch/m6809/kernel.s).
	;
	; Memory map (map set 0 = the kernel, identity: logical page n = physical page n; set 1 = the process; see DESIGN_MMU.md)
	;	0200-02FF	sector buffer of the IPL; scratch of the disk probe (free after the boot)
	;	0300-05FF	IPL (the boot ROM loads it to $0400; its variables are at $03C0-$03FF)
	;	0600-6EFF	Kernel code
	;	7000-8FFF	Kernel data (bss, data, discard)
	;	A000-BFFF	in the kernel map: windows to the memory of the process (usermem.s, tricks.s)
	;	E000-EFFF	the page of udata of the process, in both maps: user memory below $EE00, udata + kernel stack $EE00-$EFFF
	;	F000-FBFF	common page: the code that runs in both maps, the interrupt stack and the vectors (the same physical page in every map)
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
	.globl set1_dirty

	.globl _ramsize
	.globl _procmem
	.globl _memgrp

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

WINLOG	equ	0x7C00			; the window of the MMU

	.area .bss
_memgrp:	.db 0			; installed memory in steps of 128K (1-8)

	.area .discard

init_early:
	ldx #null_handler
	stx 1
	lda #0x7E
	sta 0
	rts

init_hardware:
	; the hardware vectors are RAM on the FM-11: $FFF2 SWI3, $FFF4 SWI2, $FFF6 FIRQ, $FFF8 IRQ, $FFFA SWI, $FFFC NMI.
	; They point to the jump table in the common page.
	ldx #vec_swi3
	stx 0xFFF2
	ldx #vec_swi2
	stx 0xFFF4
	ldx #vec_firq
	stx 0xFFF6
	ldx #vec_irq
	stx 0xFFF8
	ldx #vec_swi
	stx 0xFFFA
	ldx #vec_nmi
	stx 0xFFFC

	; The MMU.  Map set 0 is the kernel: logical page n = physical page n (the memory is as it was with the MMU off).
	clr FM_MSG
	ldx #FM_MMR
	clra
mm_id:	sta ,x+
	inca
	cmpa #16
	bne mm_id
	; map set 1 (the process): nothing mapped (ROM) except the page of udata (logical 14) and the common page (15)
	lda #1
	sta FM_MSG
	ldx #FM_MMR
	lda #0xFF			; PAGE_INVALID
mm_s1:	sta ,x+
	cmpx #FM_MMR+14
	bne mm_s1
	lda #14
	sta ,x+
	lda #15
	sta ,x
	clr FM_MSG
	lda #0x81			; MMU on, the boot ROM overlay at $5000-$5FFF off
	sta FM_MCFG

	; how much memory (steps of 128K)
	jsr memprobe
	lda _memgrp
	ldb #128
	mul
	std _ramsize			; KB; _procmem is set by pagemap_init

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

;
; memprobe: how much RAM the machine has (the method of memprobe in mk09/arch/m6809/kernel.s).  The memory comes in steps of 128K
; (32 pages of 4K, the first step is always there).  For every further step the first two bytes of its first page are written through
; the window ($7C00-$7FFF; FM_WIN1/FM_WIN2) with $A5 $5A and read back: the step is there when they stay and when they are not an
; echo (a mirror of a lower step: the same bytes show in the first page of a step below, whose bytes are put back).
; Result: _memgrp = the number of steps (1-8).  The window hides $7C00-$7FFF: nothing of the kernel data is used meanwhile.
;
memprobe:
	pshs d,x,y,u
	leas -17,s			; 0,s: g (the step that is tried), 1..16,s: the first words of the steps 0..g (saved)
	lda #1
	sta ,s
	lda #0xC1			; window on
	sta FM_MCFG
	ldx #WINLOG
mp_g:	lda ,s
	cmpa #8
	bhs mp_end			; all 8 steps are there
	leau 1,s
	clra
mp_sv:	bsr mp_win			; save the first words of the steps 0..g
	ldy ,x
	sty ,u++
	cmpa ,s
	beq mp_t
	inca
	bra mp_sv
mp_t:	lda ,s				; try step g
	bsr mp_win
	ldd #0xA55A
	std ,x
	ldd ,x
	cmpd #0xA55A
	bne mp_nak			; not installed
	clra
mp_ec:	cmpa ,s				; is it an echo of a step below?
	bhs mp_ok
	bsr mp_win
	ldy ,x
	cmpy #0xA55A
	beq mp_nak
	inca
	bra mp_ec
mp_ok:	bsr mp_rest			; the step is there: its words are put back and the next one is tried
	inc ,s
	bra mp_g
mp_nak:	bsr mp_rest			; not there (or only the echo of a lower step): put the words back, g steps are there
mp_end:	lda #0x81			; window off
	sta FM_MCFG
	lda ,s
	sta _memgrp			; (g steps are there)
	leas 17,s
	puls d,x,y,u,pc

mp_rest:				; put back the saved first words of the steps 0..g
	leau 3,s			; (the return address of this subroutine is on the stack: g is at 2,s, the saved words from 3,s)
	clra
mp_rl:	bsr mp_win
	ldy ,u++
	sty ,x
	cmpa 2,s
	beq mp_rr
	inca
	bra mp_rl
mp_rr:	rts

mp_win:	pshs a				; the window shows the first page of step A
	asla
	sta FM_WIN1			; physical address bits 19-16 of the page 32*A (= 2*A)
	lda #0x84			; and bits 15-8: $7C00 + $8400 wraps to offset 0 of the bank
	sta FM_WIN2
	puls a,pc

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
	clr FM_MSG			; the map set 0 (identity) and the MMU off again: the memory is flat
	lda #0x01
	sta FM_MCFG
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
	jsr map_kernel			; the kernel map and what the console has collected (the panic message)
	jsr _con_flush
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
; COMMON MEMORY PROCEDURES FOLLOW (the common page: the same in both map sets)
;

	.area .commondata
cur_msg:	.db 0			; the map set in use (FM_MSG cannot be read)
saved_msg:	.db 0			; map_save
set1_dirty:	.db 0			; set 1 has to be loaded from the table of the process (udata.u_page) by map_proc_always
rowbuf:		zmb 16			; the table of the process, copied here (the kernel data is not mapped in set 1)
_need_resched:	.db 0

	.area .common

;
;	The RAM vectors $FFF2-$FFFD jump to these (the order of sim09: SWI3 SWI2 SWI NMI IRQ FIRQ)
;
vec_swi3:	jmp badswi_handler
vec_swi2:	jmp badswi_handler
vec_swi:	jmp unix_syscall_entry		; system call
vec_nmi:	jmp badswi_handler
vec_irq:	jmp interrupt_handler		; PTM timer, keyboard
vec_firq:	jmp firq_handler

;
;	Map set 0 = kernel, set 1 = the process.  Set 1 is loaded when the process changes (_switchin) or when its table changes
;	(_program_vectors after exec): set1_dirty makes map_proc_always reload it.  All registers are preserved.
;
map_kernel:
	pshs a
	clra
	sta cur_msg
	sta FM_MSG
	puls a,pc

map_proc:
	cmpx #0				; (only the running process can be mapped: the table is always udata.u_page)
	beq map_kernel
map_proc_a:
map_proc_always:
	pshs a
	lda set1_dirty
	bne mpa_load
	lda #1
	sta cur_msg
	sta FM_MSG
	puls a,pc
mpa_load:
	pshs d,x,y
	clr FM_MSG			; the kernel map: the table of the process is in the kernel data
	ldx U_DATA__U_PAGE
	ldy #rowbuf
	ldb #16
mpa_c:	lda ,x+
	sta ,y+
	decb
	bne mpa_c
	lda #15
	sta rowbuf+15			; the common page is always the same
	clr set1_dirty
	lda #1
	sta cur_msg
	sta FM_MSG			; the map of the process: nothing of the kernel data is visible until it is loaded
	ldy #rowbuf
	lda 14,y
	sta FM_MMR+14			; the page of the stack first
	ldx #FM_MMR
	ldb #16
mpa_w:	lda ,y+
	sta ,x+
	decb
	bne mpa_w
	puls d,x,y
	puls a,pc

;
;	Restore a saved mapping (the interrupt handler: it was in the kernel or in the process map).  Registers preserved.
;
map_restore:
	pshs a
	lda saved_msg
	sta cur_msg
	sta FM_MSG
	puls a,pc

map_save:
	pshs a
	lda cur_msg
	sta saved_msg
	puls a,pc

;
;	Platform specific user space set up: the JMP to null_handler at the address 0 of the process (the interrupt handler looks
;	for it, a process that overwrites it is killed).  X = &udata.u_page (the table of the process)
;	If it is the running process the map of set 1 has to be reloaded.
;
_program_vectors:
	ldx ,x				; the table of the process
	cmpx U_DATA__U_PAGE
	bne pv_1
	lda #1
	sta set1_dirty
pv_1:	lda ,x
	sta FM_MMR+10			; window A ($A000-$AFFF) of the kernel map
	lda #0x7E
	sta 0xA000
	ldx #null_handler
	stx 0xA001
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

