#include <linux/bug.h>
#include <linux/module.h>
#include <linux/init.h>
#include <linux/signal.h>
#include <linux/sched.h>
#include <linux/kernel.h>
#include <linux/errno.h>
#include <linux/string.h>
#include <linux/types.h>
#include <linux/pagemap.h>
#include <linux/ptrace.h>
#include <linux/mman.h>
#include <linux/mm.h>
#include <linux/bootmem.h>
#include <linux/highmem.h>
#include <linux/memblock.h>
#include <linux/swap.h>
#include <linux/proc_fs.h>
#include <linux/pfn.h>

#include <asm/setup.h>
#include <asm/cachectl.h>
#include <asm/dma.h>
#include <asm/pgtable.h>
#include <asm/pgalloc.h>
#include <asm/mmu_context.h>
#include <asm/sections.h>
#include <asm/tlb.h>

#ifdef CONFIG_DISCONTIGMEM
#error "CONFIG_HIGHMEM and CONFIG_DISCONTIGMEM dont work together yet"
#endif

pgd_t swapper_pg_dir[PTRS_PER_PGD] __page_aligned_bss;
pte_t invalid_pte_table[PTRS_PER_PTE] __page_aligned_bss;
unsigned long empty_zero_page[PAGE_SIZE / sizeof(unsigned long)] __page_aligned_bss;

void __init mem_init(void)
{
#ifdef CONFIG_HIGHMEM
	unsigned long tmp;
	max_mapnr = highend_pfn;
#else
	max_mapnr = max_low_pfn;
#endif
	high_memory = (void *) __va(max_low_pfn << PAGE_SHIFT);

	free_all_bootmem();

#ifdef CONFIG_HIGHMEM
	for (tmp = highstart_pfn; tmp < highend_pfn; tmp++) {
		struct page *page = pfn_to_page(tmp);

		/* FIXME not sure about */
		if (!memblock_is_reserved(tmp << PAGE_SHIFT))
			free_highmem_page(page);
	}
#endif
	mem_init_print_info(NULL);
}

#ifdef CONFIG_BLK_DEV_INITRD
void free_initrd_mem(unsigned long start, unsigned long end)
{
	if (start < end)
		printk(KERN_INFO "Freeing initrd memory: %ldk freed\n",
                     (end - start) >> 10);

	for (; start < end; start += PAGE_SIZE) {
	ClearPageReserved(virt_to_page(start));
	init_page_count(virt_to_page(start));
	free_page(start);
	totalram_pages++;
    }
}
#endif

extern char __init_begin[], __init_end[];
extern void __init prom_free_prom_memory(void);

void free_initmem(void)
{
	unsigned long addr;

	addr = (unsigned long) &__init_begin;
	while (addr < (unsigned long) &__init_end) {
	        ClearPageReserved(virt_to_page(addr));
	        init_page_count(virt_to_page(addr));
	        free_page(addr);
	        totalram_pages++;
	        addr += PAGE_SIZE;
	}
	printk(KERN_INFO "Freeing unused kernel memory: %dk freed\n",
	        ((unsigned int)&__init_end - (unsigned int)&__init_begin) >> 10);
}

void pgd_init(unsigned long *p)
{
	int i;

#define val	(unsigned long) __pa(invalid_pte_table);

	for (i = 0; i < USER_PTRS_PER_PGD*2; i+=8) {
		p[i + 0] = val;
		p[i + 1] = val;
		p[i + 2] = val;
		p[i + 3] = val;
		p[i + 4] = val;
		p[i + 5] = val;
		p[i + 6] = val;
		p[i + 7] = val;
	}
}

