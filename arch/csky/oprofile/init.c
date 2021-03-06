#include <linux/kernel.h>
#include <linux/oprofile.h>
#include <linux/errno.h>
#include <linux/init.h>

int __init oprofile_arch_init(struct oprofile_operations *ops)
{
	return oprofile_perf_init(ops);
}

void oprofile_arch_exit(void)
{
	oprofile_perf_exit();
}
