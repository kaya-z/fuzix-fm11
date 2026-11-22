; SPDX-License-Identifier: GPL-2.0-only
; Copyright (c) 2026 KAYANUMA Shin'ichi
;
;	Copy to and from the memory of the process (kernel map = set 0 is active): the page of the process that holds the user
;	address is shown in the window A ($A000-$AFFF) of the kernel map (MMR 10) through the table of the process (udata.u_page).
;	No interrupt uses the window.  Calling convention of gcc6809: the first argument in X, the others on the stack.
;
	.module usermem

	include "kernel.def"
        include "../../cpu-6809/kernel09.def"

	.globl 	__ugetc
	.globl 	__ugetw
	.globl 	__uget
	.globl 	__uputc
	.globl 	__uputw
	.globl 	__uput
	.globl 	__uzero

	.area .text

WINA	equ	0xA000
WINEND	equ	0xB000

; D = user address -> X = the address of that byte in the window A (the window is mapped).  D is destroyed.
um_ptr:
	pshs d
	tfr a,b
	lsrb
	lsrb
	lsrb
	lsrb				; B = the logical page
	ldx U_DATA__U_PAGE
	abx
	lda ,x
	sta FM_MMR+10
	puls d
	anda #0x0F
	ora #0xA0
	tfr d,x
	rts

; the user address um_addr moves to the start of the next page
um_next:
	ldd um_addr
	anda #0xF0
	clrb
	addd #0x1000
	std um_addr
	rts

__ugetc:
	tfr x,d
	lbsr um_ptr
	ldb ,x
	clra
	tfr d,x
	rts

__ugetw:
	pshs u
	tfr x,u
	tfr u,d
	lbsr um_ptr
	lda ,x
	pshs a
	leau 1,u
	tfr u,d
	lbsr um_ptr
	ldb ,x
	puls a
	tfr d,x
	puls u,pc

__uputc:				; X = value, the user address at 2,s
	ldd 2,s
	pshs x
	lbsr um_ptr
	puls d
	stb ,x
	ldx #0
	rts

__uputw:				; X = value, the user address at 6,s (after the pushes)
	pshs u,x
	ldu 6,s
	tfr u,d
	lbsr um_ptr
	lda 0,s
	sta ,x
	leau 1,u
	tfr u,d
	lbsr um_ptr
	lda 1,s
	sta ,x
	leas 2,s
	ldx #0
	puls u,pc

__uget:					; X = user address, the kernel address at 6,s, the count at 8,s
	pshs u,y
	stx um_addr
	ldu 6,s
	ldy 8,s
	beq ug_end
ug_map:	ldd um_addr
	lbsr um_ptr
ug_l:	lda ,x+
	sta ,u+
	leay -1,y
	beq ug_end
	cmpx #WINEND
	bne ug_l
	lbsr um_next
	bra ug_map
ug_end:	ldx #0
	puls u,y,pc

__uput:					; X = kernel address, the user address at 6,s, the count at 8,s
	pshs u,y
	ldd 6,s
	std um_addr
	tfr x,u
	ldy 8,s
	beq up_end
up_map:	ldd um_addr
	lbsr um_ptr
up_l:	lda ,u+
	sta ,x+
	leay -1,y
	beq up_end
	cmpx #WINEND
	bne up_l
	lbsr um_next
	bra up_map
up_end:	ldx #0
	puls u,y,pc

__uzero:				; X = user address, the count at 4,s
	pshs y
	stx um_addr
	ldy 4,s
	beq uz_end
uz_map:	ldd um_addr
	lbsr um_ptr
uz_l:	clr ,x+
	leay -1,y
	beq uz_end
	cmpx #WINEND
	bne uz_l
	lbsr um_next
	bra uz_map
uz_end:	ldx #0
	puls y,pc

	.area .bss
um_addr:	.dw 0
