/* Anvil-Core start-up code. The core starts executing here at RESET_VECTOR. */

    .section .text.init
    .globl _start
_start:
    /* Relaxation must not use gp to initialize gp itself. */
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, __stack_top
    la t0, trap_entry
    csrw mtvec, t0

    /* Initialized data is already in RAM. Clear only the aligned BSS. */
    la t0, __bss_start
    la t1, __bss_end
.Lclear_bss:
    bgeu t0, t1, .Lrun_main
    sw zero, 0(t0)
    addi t0, t0, 4
    j .Lclear_bss

.Lrun_main:
    call __libc_init_array
    li a0, 0
    li a1, 0
    call main
    tail exit

    /* newlib calls _init between preinit and init arrays. */
    .weak _init
_init:
    ret

    .align 2
    .globl trap_entry
trap_entry:
    /* C preserves the callee-saved registers. Save the caller-saved set. */
    addi sp, sp, -64
    sw ra,  0(sp)
    sw t0,  4(sp)
    sw t1,  8(sp)
    sw t2, 12(sp)
    sw t3, 16(sp)
    sw t4, 20(sp)
    sw t5, 24(sp)
    sw t6, 28(sp)
    sw a0, 32(sp)
    sw a1, 36(sp)
    sw a2, 40(sp)
    sw a3, 44(sp)
    sw a4, 48(sp)
    sw a5, 52(sp)
    sw a6, 56(sp)
    sw a7, 60(sp)

    csrr a0, mcause
    csrr a1, mepc
    call trap_handler

    lw ra,  0(sp)
    lw t0,  4(sp)
    lw t1,  8(sp)
    lw t2, 12(sp)
    lw t3, 16(sp)
    lw t4, 20(sp)
    lw t5, 24(sp)
    lw t6, 28(sp)
    lw a0, 32(sp)
    lw a1, 36(sp)
    lw a2, 40(sp)
    lw a3, 44(sp)
    lw a4, 48(sp)
    lw a5, 52(sp)
    lw a6, 56(sp)
    lw a7, 60(sp)
    addi sp, sp, 64
    mret
