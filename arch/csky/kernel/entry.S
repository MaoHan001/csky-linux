#include <linux/linkage.h>
#include <abi/entry.h>
#include <abi/pgtable-bits.h>
#include <asm/errno.h>
#include <asm/setup.h>
#include <asm/traps.h>
#include <asm/unistd.h>
#include <asm/asm-offsets.h>
#include <linux/threads.h>
#include <asm/setup.h>
#include <asm/page.h>
#include <asm/thread_info.h>
#include <asm/fpu.h>

#define PTE_INDX_MSK    0xffc
#define PTE_INDX_SHIFT  10
#define _PGDIR_SHIFT    22
#define THREADSIZE_MASK_BIT 13

.macro tlbop_begin name, val0, val1, val2
ENTRY(csky_\name)
	mtcr    a3, ss2
	mtcr    r6, ss3
	mtcr    a2, ss4

	RD_MEH	a3
#ifdef CONFIG_CPU_HAS_TLBI
	tlbi.va	a3
#else
	bgeni	a2, 31
	WR_MCIR	a2
	bgeni	a2, 25
	WR_MCIR	a2
#endif

	RD_PGDR	r6
	bclri   r6, 0
	lrw	a2, PHYS_OFFSET
	subu	r6, a2
	bseti	r6, 31

	mov     a2, a3
   	lsri    a2, _PGDIR_SHIFT
	lsli    a2, 2
	addu    r6, a2
	ldw     r6, (r6)

	lrw	a2, PHYS_OFFSET
	subu	r6, a2
	bseti	r6, 31

	lsri    a3, PTE_INDX_SHIFT
	lrw     a2, PTE_INDX_MSK
	and     a3, a2
	addu    r6, a3
	ldw     a3, (r6)

	movi	a2, (_PAGE_PRESENT | \val0)
	and     a3, a2
	cmpne   a3, a2
	bt	\name

	/* First read/write the page, just update the flags */
	ldw     a3, (r6)
	bgeni   a2, PAGE_VALID_BIT
	bseti   a2, PAGE_ACCESSED_BIT
	bseti   a2, \val1
	bseti   a2, \val2
	or      a3, a2
	stw     a3, (r6)

	/* Some cpu tlb-hardrefill bypass the cache */
#ifndef CONFIG_CPU_HAS_TLBCACHE
	movi	a2, 0x22
	bseti	a2, 6
	mtcr	r6, cr22
	mtcr	a2, cr17
	sync
#endif

	mfcr    a3, ss2
	mfcr    r6, ss3
	mfcr    a2, ss4
	rte
\name:
	mfcr    a3, ss2
	mfcr    r6, ss3
	mfcr    a2, ss4
	SAVE_ALL
.endm
.macro tlbop_end is_write
	RD_MEH	a2
	psrset  ee, ie
	mov     a0, sp
	movi    a1, \is_write
	jbsr    do_page_fault
	movi    r11_sig, 0             /* r11 = 0, Not a syscall. */
	jmpi    ret_from_exception
.endm

.text

tlbop_begin tlbinvalidl, _PAGE_READ, PAGE_VALID_BIT, PAGE_ACCESSED_BIT
tlbop_end 0

tlbop_begin tlbinvalids, _PAGE_WRITE, PAGE_DIRTY_BIT, PAGE_MODIFIED_BIT
tlbop_end 1

tlbop_begin tlbmodified, _PAGE_WRITE, PAGE_DIRTY_BIT, PAGE_MODIFIED_BIT
jbsr csky_cmpxchg_fixup
tlbop_end 1


ENTRY(csky_systemcall)
	SAVE_ALL_TRAP

	psrset  ee, ie

	/* Stack frame for syscall, origin call set_esp0 */
	mov     r12, sp

	bmaski  r11, 13
	andn    r12, r11
	bgeni   r11, 9
	addi    r11, 32
	addu    r12, r11
	st      sp, (r12, 0)

	lrw     r11, __NR_syscalls
	cmphs   syscallid, r11                 /* Check nr of syscall */
	bt      ret_from_exception

	lrw     r13, sys_call_table
	ixw     r13, syscallid                 /* Index into syscall table */
	ldw     r11, (r13)               /* Get syscall function */
	cmpnei  r11, 0                  /* Check for not null */
	bf      ret_from_exception

	mov     r9, sp				 /* Get task pointer */
	bmaski  r10, THREADSIZE_MASK_BIT
	andn    r9, r10                      /* Get thread_info */
	ldw     r8, (r9, TINFO_FLAGS)       /* Get thread_info.flags value */
	btsti   r8, TIF_SYSCALL_TRACE       /* Check if TIF_SYSCALL_TRACE set */
	bt      1f
#if defined(__CSKYABIV2__)
	subi    sp, 8
	stw  	r5, (sp, 0x4)
	stw  	r4, (sp, 0x0)
	jsr     r11                      /* Do system call */
	addi 	sp, 8
#else
	jsr     r11
#endif
	stw     a0, (sp, LSAVE_A0)      /* Save return value */
	jmpi    ret_from_exception

1:
	movi    a0, 0                   /* enter system call */
	mov     a1, sp                  /* right now, sp --> pt_regs */
	jbsr    syscall_trace
	/* Prepare args before do system call */
	ldw     a0, (sp, LSAVE_A0)
	ldw     a1, (sp, LSAVE_A1)
	ldw     a2, (sp, LSAVE_A2)
	ldw     a3, (sp, LSAVE_A3)
#if defined(__CSKYABIV2__)
	subi    sp, 8
	stw     r5, (sp, 0x4)
	stw     r4, (sp, 0x0)
#else
	ldw     r6, (sp, LSAVE_A4)
	ldw     r7, (sp, LSAVE_A5)
#endif
	jsr     r11                     /* Do system call */
#if defined(__CSKYABIV2__)
	addi    sp, 8
#endif
	stw     a0, (sp, LSAVE_A0)     /* Save return value */

	movi    a0, 1                   /* leave system call */
	mov     a1, sp                  /* right now, sp --> pt_regs */
	jbsr    syscall_trace

syscall_exit_work:
	ld       syscallid, (sp, 8)     /* get psr, is user mode? */
	btsti    syscallid, 31
	bt       2f

	jmpi     resume_userspace

2:      RESTORE_ALL

ENTRY(ret_from_kernel_thread)
	jbsr     schedule_tail
	mov	 a0, r8
	jsr	 r9
	jbsr     ret_from_exception

ENTRY(ret_from_fork)
	jbsr     schedule_tail
	mov      r9, sp				 /* Get task pointer */
	bmaski   r10, THREADSIZE_MASK_BIT
	andn     r9, r10                     /* Get thread_info */
	ldw      r8, (r9, TINFO_FLAGS)       /* Get thread_info.flags value */
	movi     r11_sig, 1                  /* is a syscall */
	btsti    r8, TIF_SYSCALL_TRACE       /* Check if TIF_SYSCALL_TRACE set */
	bf       3f
	movi     a0, 1                       /* leave system call */
	mov      a1, sp                      /* right now, sp --> pt_regs */
	jbsr     syscall_trace
3:
	jbsr     ret_from_exception

ret_from_exception:
	ld       syscallid, (sp,8)     /* get psr, is user mode? */
	btsti    syscallid, 31
	bt       1f
	/*
	 * Load address of current->thread_info, Then get address of task_struct
	 * Get task_needreshed in task_struct
	 */
	mov     r9, sp     					 /* Get current stack  pointer */
	bmaski  r10, THREADSIZE_MASK_BIT
	andn    r9, r10                      /* Get task_struct */

resume_userspace:
	ldw      r8, (r9, TINFO_FLAGS)
	andi     r8, (_TIF_SIGPENDING | _TIF_NOTIFY_RESUME | _TIF_NEED_RESCHED)
	cmpnei   r8, 0
	bt       exit_work
1:  RESTORE_ALL

exit_work:
	mov      a0, sp                 /* Stack address is arg[0] */
	jbsr     set_esp0               /* Call C level */
	btsti    r8, TIF_NEED_RESCHED
	bt       work_resched
	cmpnei   r8, 0		/* If thread_info->flag is empty, RESTORE_ALL. */
	bf       1b
	mov      a1, sp
	mov      a0, r8
	mov      a2, r11_sig        /* syscall? */
	btsti    r8, TIF_SIGPENDING /* delivering a signal? */
	clrt     r11_sig            /* prevent further restarts(set r11 = 0) */
	jbsr     do_notify_resume	/* do signals */
	br       resume_userspace

work_resched:
	lrw      syscallid, ret_from_exception
	mov      r15, syscallid                /* Return address in link */
	jmpi     schedule

ENTRY(sys_rt_sigreturn)
	movi	r11_sig, 0
	jmpi	do_rt_sigreturn

/*
 * Common trap handler. Standard traps come through here first
 */

ENTRY(csky_trap)
	SAVE_ALL
	psrset   ee
	movi     r11_sig, 0             /* r11 = 0, Not a syscall. */
	mov      a0, sp                 /* Push Stack pointer arg */
	jbsr     trap_c                 /* Call C-level trap handler */
	jmpi     ret_from_exception

/*
 * handle FPU exception.
 */
ENTRY(csky_fpe)
	SAVE_ALL
	/* Clear FPU exception state */
#if defined(CONFIG_CPU_HAS_FPU)
	mfcr      a0, cr<2, 2>	       /* fpu fesr is cr<2,2> in CSKY_CPUV2 */
	movi      r11_sig, 0           /* r11 = 0, Not a syscall. */
	mov       a1, sp               /* Push Stack pointer arg */
	jbsr      handle_fpe_c         /* Call C-level fpe handler */
#endif
	jmpi      ret_from_exception

/*
 * Prototype from libc:
 * register unsigned int __result asm("a0");
 * asm( "trap 3" :"=r"(__result)::);
 */
ENTRY(csky_get_tls)
	USPTOKSP

	/* increase epc for continue */
	mfcr	a0, epc
	INCTRAP	a0
	mtcr	a0, epc

	/* get current task thread_info with kernel 8K stack */
	bmaski   a0, (PAGE_SHIFT + 1)
	not      a0
	subi     sp, 1
	and      a0, sp
	addi     sp, 1

	/* get tls */
	ldw      a0, (a0, TINFO_TP_VALUE)

	KSPTOUSP
	rte

ENTRY(csky_irq)
	SAVE_ALL
	psrset  ee       // enable exception
	movi    r11_sig, 0                   /* r11 = 0, Not a syscall. */

#ifdef CONFIG_PREEMPT
	mov     r9, sp                       /* Get current stack  pointer */
	bmaski  r10, THREADSIZE_MASK_BIT
	andn    r9, r10                      /* Get thread_info */

	/*
	 * Get task_struct->stack.preempt_count for current,
	 * and increase 1.
	 */
	ldw      r8, (r9, TINFO_PREEMPT)
	addi     r8, 1
	stw      r8, (r9, TINFO_PREEMPT)
#endif

	mov      a0, sp                      /* arg[0] is stack pointer */
	jbsr     csky_do_auto_IRQ          /* Call handler */

#ifdef CONFIG_PREEMPT
	subi     r8, 1
	stw      r8, (r9, TINFO_PREEMPT)
	cmpnei   r8, 0
	bt       2f
	ldw      r8, (r9, TINFO_FLAGS)
	btsti    r8, TIF_NEED_RESCHED
	bf       2f
1:
	jbsr     preempt_schedule_irq   /* irq en/disable is done inside */
	ldw      r7, (r9, TINFO_FLAGS)  /* get new tasks TI_FLAGS */
	btsti    r7, TIF_NEED_RESCHED
	bt       1b                     /* go again */
#endif
2:
	jmpi     ret_from_exception

/*
 * a0 =  prev task_struct *
 * a1 =  next task_struct *
 * a0 =  return next
 */
ENTRY(__switch_to)
	lrw      a3, TASK_THREAD        /* struct_thread offset in task_struct */
	addu     a3, a0                 /* a3 point to thread in prev task_struct */

	mfcr     a2, psr                /* Save PSR value */
	stw      a2, (a3, THREAD_SR)    /* Save PSR in task struct */
	bclri    a2, 6                  /* Disable interrupts */
	mtcr     a2, psr

	SAVE_SWITCH_STACK

	GET_USP	 r6

	stw      r6, (a3, THREAD_USP)   /* Save usp in task struct */
	stw      sp, (a3, THREAD_KSP)   /* Save ksp in task struct */

#ifdef CONFIG_CPU_HAS_FPU
	FPU_SAVE_REGS
#endif

#ifdef CONFIG_CPU_HAS_HILO
	lrw      r10, THREAD_DSPHI
	add      r10, a3
	mfhi     r6
	mflo     r7
	stw      r6, (r10, 0)           /* THREAD_DSPHI */
	stw      r7, (r10, 4)           /* THREAD_DSPLO */
	mfcr     r6, cr14
	stw      r6, (r10, 8)           /* THREAD_DSPCSR */
#endif

	/* Set up next process to run */
	lrw      a3, TASK_THREAD	/* struct_thread offset in task_struct */
	addu     a3, a1			/* a3 point to thread in next task_struct */

	ldw      sp, (a3, THREAD_KSP)	/* Set next ksp */
	ldw      r6, (a3, THREAD_USP)	/* Set next usp */

	SET_USP	 r6

#ifdef CONFIG_CPU_HAS_FPU
	FPU_RESTORE_REGS
#endif

#ifdef CONFIG_CPU_HAS_HILO
	lrw      r10, THREAD_DSPHI
	add      r10, a3
	ldw      r6, (r10, 8)   /* THREAD_DSPCSR */
	mtcr     r6, cr14
	ldw      r6, (r10, 0)    /* THREAD_DSPHI */
	ldw      r7, (r10, 4)    /* THREAD_DSPLO */
	mthi     r6
	mtlo     r7
#endif

	ldw      a2, (a3, THREAD_SR)    /* Set next PSR */
	mtcr     a2, psr

#if  defined(__CSKYABIV2__)
	/* set TLS register (r31) */
	addi     r7, a1, TASK_THREAD_INFO
	ldw      r31, (r7, TINFO_TP_VALUE)
#endif

	RESTORE_SWITCH_STACK

	rts
ENDPROC(__switch_to)
