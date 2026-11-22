; SPDX-License-Identifier: GPL-2.0-only
; Copyright (c) 2026 KAYANUMA Shin'ichi
;
;	Context switch and fork of the FM-11 with the MMU (DESIGN_MMU.md).
;
;	The process table of a process is a row of 16 bytes (p_page points to it): the physical page of the logical pages 0-15.
;	Logical page 14 holds the udata of the process ($EE00) and its kernel stack: the kernel map (set 0) shows the page of the
;	running process there, so "the process switch" is one MMR write in set 0 and a reload of set 1 (set1_dirty).
;
        .module tricks

	# imported
        .globl _makeproc
        .globl _chksigs
        .globl _getproc
        .globl _plt_monitor
        .globl _inint
	.globl _runticks
	.globl _tmpbuf
	.globl _tmpfree
	.globl set1_dirty
	.globl _udata
	.globl _fm11_swapin
	.globl _swstack

	# exported
        .globl _plt_switchout
        .globl _switchin
        .globl _dofork
	.globl _ramtop

        include "kernel.def"
        include "../../cpu-6809/kernel09.def"

	.area .data

	; ramtop: the top of the user memory (= PROGTOP of config.h, set by start.c)
_ramtop:
	.dw 0

	.area .commondata
newpp:	.dw 0
fork_proc_ptr: .dw 0			; (C type is struct p_tab *) -- address of the child process p_tab entry
tmpudata: .dw 0				; the udata of the child, until it is written into its page

	.area .common

; Switchout switches out the current process, finds another that is READY,
; possibly the same process, and switches it in.  When a process is
; restarted after calling switchout, it thinks it has just returned
; from switchout().
;
; This function can have no arguments or auto variables.
_plt_switchout:
	orcc #0x10		; irq off

        ; save machine state, including Y and U used by our C code
        ldd #0 ; return code set here is ignored, but _switchin can
        ; return from either _switchout OR _dofork, so they must both write
        ; U_DATA__U_SP with the following on the stack:
	pshs d,y,u
	sts U_DATA__U_SP	; this is where the SP is restored in _switchin

        ; find another (or same) process to run, returned in X
        jsr _getproc
        jsr _switchin
        ; we should never get here
        jsr _plt_monitor

badswitchmsg:
	.ascii "_switchin: FAIL"
        .db 13
	.db 10
	.db 0

; new process pointer is in X
_switchin:
        orcc #0x10		; irq off

	stx newpp
	ldy P_TAB__P_PAGE_OFFSET,x	; the table of its pages
	bne swi_mem			; in memory

	; swapped out: get the pages (this may swap out others).  The stack of the old process is not safe (its pages may be
	; given to the new one): the interrupt stack, with the interrupts off
	lds #_swstack+512
	jsr _fm11_swapin
	ldx newpp
	ldy P_TAB__P_PAGE_OFFSET,x
	beq switchinfail
swi_mem:

	; The stack is the one of the old process: no use of it until the page of udata is the new one
	lda 14,y			; physical page of its udata (logical page 14)
	sta FM_MMR+14			; the kernel map shows it now
	lda #1
	sta set1_dirty			; map set 1 is loaded by map_proc_always

        ; check u_data->u_ptab matches what we wanted
	ldx newpp
	cmpx U_DATA__U_PTAB
        bne switchinfail

	lda #P_RUNNING
	sta P_TAB__P_STATUS_OFFSET,x

	ldx #0
	stx _runticks

        ; restore machine state -- note we may be returning from either
        ; _switchout or _dofork
        lds U_DATA__U_SP
        puls x,y,u ; return code and saved U and Y

        ; enable interrupts, if the ISR isn't already running
	lda U_DATA__U_ININTERRUPT
        bne swtchdone ; in ISR, leave interrupts off
	andcc #0xef
swtchdone:
        rts

switchinfail:
	jsr outx
        ldx #badswitchmsg
        jsr outstring
	; something went wrong and we didn't switch in what we asked for
        jmp _plt_monitor

;
;	Called from _fork. We are in a syscall, the uarea is live as the
;	parent uarea. The kernel is the mapped object.
;	The child gets copies of the pages of the parent and a copy of udata (with the kernel stack as it is now) made by
;	_makeproc; the parent goes on running and gets the pid of the child.
;
_dofork:
        orcc #0x10	 ; should already be the case ... belt and braces.

	stx fork_proc_ptr
	ldx #0		; child returns 0

        ; Save the stack pointer and critical registers (Y and U used by C).
        ; When this process (the parent) is switched back in, it will be as if
        ; it returns with the value of the child's pid.
        pshs x,y,u
        sts U_DATA__U_SP

	; Copy the parent udata (with the stack) into a temporary buffer
	jsr _tmpbuf
	stx tmpudata
	tfr x,y
	ldu #_udata
udsave:
	ldd ,u++
	std ,x++
	cmpu #_udata+U_DATA__TOTALSIZE
	bne udsave

	; the pages: parent -> child (all of them, the page of udata too)
	jsr copy_pages

	; Make the child process using the buffer, not the live udata
	pshs y
	ldx fork_proc_ptr
	jsr _makeproc
	leas 2,s

	; and put the udata of the child into its page (the window B: $B000 of the kernel map)
	ldx fork_proc_ptr
	ldy P_TAB__P_PAGE_OFFSET,x
	lda 14,y
	sta FM_MMR+11
	ldx tmpudata
	ldu #0xB000+0x0E00
cpud:	ldd ,x++
	std ,u++
	cmpu #0xB000+0x1000
	bne cpud

	ldx tmpudata
	jsr _tmpfree

	ldx fork_proc_ptr
	ldd P_TAB__P_PID_OFFSET,x
	; Clean up and return
	puls x,y,u
	tfr d,x
	rts

;
;	Copy the pages of the running process (udata.u_page) to the pages of the child (fork_proc_ptr): the table entries 0-14
;	that are not PAGE_INVALID.  The kernel map windows A ($A000: source) and B ($B000: destination) are used, Y is preserved.
;
copy_pages:
	pshs y,u
	ldx U_DATA__U_PAGE		; the table of the parent
	ldy fork_proc_ptr
	ldy P_TAB__P_PAGE_OFFSET,y	; the table of the child
	pshs x
	lda 14,x
	sta cp_u14
	puls x
	clrb
cp_pg:	lda ,x+
	cmpa #0xFF
	beq cp_skip
	cmpb #14
	beq cp_nu
	cmpa cp_u14			; the last page of the program is the page of udata: copied with the entry 14
	beq cp_skip
cp_nu:
	cmpa ,y				; the same page: shared text, nothing to copy
	beq cp_skip
	sta FM_MMR+10			; window A = the page of the parent
	lda ,y
	sta FM_MMR+11			; window B = the page of the child
	pshs b,x,y
	ldx #0xA000
	ldy #0xB000
cp_l:	ldd ,x++
	std ,y++
	ldd ,x++
	std ,y++
	ldd ,x++
	std ,y++
	ldd ,x++
	std ,y++
	ldd ,x++
	std ,y++
	ldd ,x++
	std ,y++
	ldd ,x++
	std ,y++
	ldd ,x++
	std ,y++
	cmpx #0xB000
	bne cp_l
	puls b,x,y
cp_skip:
	leay 1,y
	incb
	cmpb #15
	bne cp_pg
	puls y,u,pc

	.area .commondata
cp_u14:	.db 0
