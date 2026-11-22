/* SPDX-License-Identifier: GPL-2.0-only */
/* Copyright (c) 2026 KAYANUMA Shin'ichi */
/*
 *	Memory management of the FM-11 with its MMU: pages of 4K, 16 logical pages of a process (see DESIGN_MMU.md).
 *	After mm/bank8k.c.  No swap yet.
 *
 *	The table of a process (p_page points to it) has 16 bytes, the physical page of every logical page:
 *	  0 .. needed-1	the pages of the program (needed = from maps_needed(), at least 1 and at most 14)
 *	  needed .. 13	PAGE_INVALID (the ROM: the pages do not exist)
 *	  14		the page of udata: the user memory below $EE00, udata + the kernel stack from $EE00
 *	  15		the common page (always the same; the kernel loads it itself)
 *	The first process (init) lives in the page that the kernel booted in (the physical page 14): udata is live there
 *	before there is a process table.
 */
#include <kernel.h>
#include <kdata.h>
#include <printf.h>
#include <exec.h>

#define PTSIZE		16
#define NUSER		14		/* logical pages that hold only the program: 0-13 */
#define BOOT_UDATA	14		/* the physical page of the udata at boot */

static uint8_t pfree[MAX_MAPS];
static uint8_t pfptr;
static uint8_t pmap[PTABSIZE][PTSIZE];
static uint8_t boot_done;
/* Text sharing: fork gives the child the pages 1..pshare-1 of the parent (they hold only program text, which is never written)
   instead of copies; pgref counts the holders of a physical page. */
static uint8_t pgref[256];
static uint8_t pshare[PTABSIZE];

extern void program_vectors(uint16_t *pageptr);

/* Helper for the platform to add physical pages at boot */
void pagemap_add(uint8_t page)
{
	if (pfptr == MAX_MAPS)
		panic(PANIC_MAPOVER);
	pfree[pfptr++] = page;
}

/* take a page from the pool (the caller has checked that there is one) */
static uint8_t getpage(void)
{
	uint8_t pg;

	pfptr--;
	pg = pfree[pfptr];
	pgref[pg] = 1;
	return pg;
}

/*
 *	The page of udata (logical page 14) holds the udata and the kernel stack in its last 512 bytes only.  If the last page of the
 *	program uses no more than the first $E00 bytes (the exec sets the top that way) that page IS the page of udata: logical
 *	page k and logical page 14 are the same physical page.  So a process costs k+1 pages, k = the pages below the last one.
 */

/* The logical pages of the program for the top address of a process: 1..15 */
static int maps_needed(uint16_t top)
{
	int n = ((top - 1) >> 12) + 1;
	if (n > 15)
		n = 15;
	return n;
}

/* Is the last page of the program the page of udata? */
static int merged(uint16_t top)
{
	return ((top - 1) & 0xFFF) < 0xE00;
}

/* The pages of the program that are pages of their own (the logical pages 0..k-1, k <= 14) */
static int nprivate(uint16_t top)
{
	int n = maps_needed(top);
	return merged(top) ? n - 1 : n;
}

/* The stack for the swap in of switchin (the stack of the old process may be given to the new one) */
uint8_t swstack[512];

/* Free the maps of this task (the pages are not cleared) */
void pagemap_free(ptptr p)
{
	uint8_t *pt = (uint8_t *) p->p_page;
	uint8_t i;

	for (i = 0; i < PAGE_UDATA; i++) {
		if (pt[i] != PAGE_INVALID && pt[i] != pt[PAGE_UDATA]) {
			if (--pgref[pt[i]] == 0)
				pfree[pfptr++] = pt[i];
		}
		pt[i] = PAGE_INVALID;
	}
	if (pt[PAGE_UDATA] != PAGE_INVALID) {
		/* the udata page of init (the boot page) is not given to the pool: the kernel is running in it */
		if (--pgref[pt[PAGE_UDATA]] == 0 && pt[PAGE_UDATA] != BOOT_UDATA)
			pfree[pfptr++] = pt[PAGE_UDATA];
		pt[PAGE_UDATA] = PAGE_INVALID;
	}
	pshare[p - ptab] = 0;
	p->p_page = 0;
}

/*
 *	Swap out processes until n pages are free
 */
static int makeroom(uint8_t n)
{
	while (pfptr < n) {
		if (swapneeded(udata.u_ptab, 1) == NULL) {
			return ENOMEM;
		}
	}
	return 0;
}

/*
 *	Allocate the maps for this task post fork.
 *	Use p-> not udata: the udata is the one of the parent.
 */
int pagemap_alloc(ptptr p)
{
	uint8_t *ptr = pmap[p - ptab];
	uint8_t *par = (uint8_t *) udata.u_page;	/* the parent (fork) */
	int k = nprivate(p->p_top);
	uint8_t nsh = 0;
	uint8_t i;
	uint8_t u;

	if (!boot_done) {
		/* init: udata is live in the boot page */
		if (k > pfptr)
			return ENOMEM;
	} else {
		nsh = pshare[udata.u_ptab - ptab];
		if (nsh > k)
			nsh = k;
		if (nsh < 2)
			nsh = 0;
		/* the pages that are copied, and the page of udata */
		if (makeroom(k - (nsh ? nsh - 1 : 0) + 1))
			return ENOMEM;
	}

	for (i = 0; i < k; i++) {
		if (i >= 1 && i < nsh) {
			ptr[i] = par[i];
			pgref[ptr[i]]++;
		} else
			ptr[i] = getpage();
	}
	for (; i < NUSER; i++)
		ptr[i] = PAGE_INVALID;
	if (!boot_done) {
		boot_done = 1;
		u = BOOT_UDATA;
		pgref[u] = 1;
	} else
		u = getpage();
	ptr[PAGE_UDATA] = u;
	if (merged(p->p_top) && k < PAGE_UDATA)
		ptr[k] = u;
	ptr[15] = 15;
	pshare[p - ptab] = nsh;
	p->p_page = (uint16_t) ptr;
	return 0;
}

/*
 *	Reallocate the maps for a process: execve.  The program is going to be loaded over the old one.
 */
int pagemap_realloc(struct exec *hdr, usize_t size)
{
	uint16_t top = size + MAPBASE;
	int kh = nprivate(udata.u_top);
	int kw = nprivate(top);
	uint8_t *ptr = (uint8_t *) udata.u_page;
	uint8_t idx = udata.u_ptab - ptab;
	uint8_t nsh = pshare[idx];
	int i, shared = 0, share;

	/* the pages that are shared with another process are replaced */
	for (i = 1; i < nsh && i < kh; i++)
		if (pgref[ptr[i]] > 1)
			shared++;
	if (makeroom(shared + (kw > kh ? kw - kh : 0)))
		return ENOMEM;
	for (i = 1; i < nsh && i < kh; i++) {
		if (pgref[ptr[i]] > 1) {
			pgref[ptr[i]]--;
			ptr[i] = getpage();
		}
	}
	pshare[idx] = 0;

	/* the last page of the old program was the page of udata */
	if (kh < PAGE_UDATA && ptr[kh] == ptr[PAGE_UDATA])
		ptr[kh] = PAGE_INVALID;
	if (kw < kh) {
		for (i = kw; i < kh; i++) {
			if (--pgref[ptr[i]] == 0)
				pfree[pfptr++] = ptr[i];
			ptr[i] = PAGE_INVALID;
		}
	} else {
		for (i = kh; i < kw; i++)
			ptr[i] = getpage();
	}
	if (merged(top) && kw < PAGE_UDATA)
		ptr[kw] = ptr[PAGE_UDATA];

	/* the pages that hold only text can be shared with the children: not the first one (the vectors, the zero page) */
	share = (PROGLOAD + hdr->a_text) >> 12;
	if (share > kw)
		share = kw;
	pshare[idx] = share >= 2 ? share : 0;
	udata.u_ptab->p_size = (maps_needed(top)) << 2;
	program_vectors(&udata.u_page);
	return 0;
}

int pagemap_prepare(struct exec *hdr)
{
	/* If it is relocatable load it at PROGLOAD */
	if (hdr->a_base == 0)
		hdr->a_base = PROGLOAD >> 8;
	if (hdr->a_base != (PROGLOAD >> 8)) {
		udata.u_error = ENOEXEC;
		return -1;
	}
	/* A program that does not say how much memory it needs gets its text, data and bss and some room for the stack and the heap.
	   The top is $200 below a page boundary: the last page is the page of udata (see above).  chmem sets the size of a program
	   that needs more. */
	if (hdr->a_size == 0) {
		uint32_t need = (uint32_t)hdr->a_text + hdr->a_data + hdr->a_bss + PROGLOAD + 0x200;
		uint16_t max = (PROGTOP >> 8) - hdr->a_base;
		uint16_t pages;

		pages = (need + (procmem >= PROC_BIGMEM ? PROC_SLACK_BIG : PROC_SLACK_MIN) + 4095) >> 12;
		pages = (pages << 4) - 2 - hdr->a_base;	/* a_size counts from a_base */
		if (pages > max)
			pages = max;
		hdr->a_size = pages;
	}
	return 0;
}

/*
 *	Swap: a process goes to the disk as a whole: the pages of the program (k) and the page of udata, 8 blocks each, in this order.
 *	The pages that are shared are written too (and come back as private pages).  The DMA of the disk driver uses the physical
 *	pages, no mapping is needed.  p_page = 0 marks a process that is on the disk, p_page2 is its slot.
 */
int swapout(ptptr p)
{
	uint8_t *pt = (uint8_t *) p->p_page;
	int map;
	uint16_t blk;
	uint8_t i, j = 0;
	uint8_t k = nprivate(p->p_top);

	if (pt == NULL)
		panic("swapout0");
	map = swapmap_alloc();
	if (map < 0)
		return ENOMEM;
	blk = map * SWAP_SIZE;
	for (i = 0; i <= k; i++, j++) {
		if (swapwrite(SWAPDEV, blk + (j << 3), 0x1000, 0, i < k ? pt[i] : pt[PAGE_UDATA]) < 0) {
			swapmap_add(map);
			return EIO;
		}
	}
	pagemap_free(p);
	p->p_page2 = map;
	return 0;
}

/* The process p is going to run but it is on the disk (called by switchin on the interrupt stack, interrupts off) */
void fm11_swapin(ptptr p)
{
	uint8_t *ptr = pmap[p - ptab];
	uint8_t k = nprivate(p->p_top);
	uint16_t map = p->p_page2;
	uint16_t blk = map * SWAP_SIZE;
	uint8_t i, u;

	if (makeroom(k + 1))
		panic("swapin: no memory");
	for (i = 0; i < k; i++)
		ptr[i] = getpage();
	for (; i < NUSER; i++)
		ptr[i] = PAGE_INVALID;
	u = getpage();
	ptr[PAGE_UDATA] = u;
	if (merged(p->p_top) && k < PAGE_UDATA)
		ptr[k] = u;
	ptr[15] = 15;
	pshare[p - ptab] = 0;
	for (i = 0; i <= k; i++)
		if (swapread(SWAPDEV, blk + (i << 3), 0x1000, 0, i < k ? ptr[i] : u) < 0)
			panic("swapin: i/o");
	swapmap_add(map);
	p->p_flags &= ~PFL_BATCH;
	p->p_page = (uint16_t) ptr;
}

/* (swap.c: swapper() is not used, the platform swaps in with fm11_swapin) */
void swapin(ptptr p, uint16_t map)
{
	panic("swapin");
}

usize_t pagemap_mem_used(void)
{
	return procmem - (pfptr << 2);
}
