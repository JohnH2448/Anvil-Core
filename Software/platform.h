// Anvil-Core platform definitions: address map and device registers.
//
// RAM_BASE and RAM_END (one past the last RAM byte) come from the Makefile,
// which reads them from Core/Package/Parameters.sv.
//
// Address map (Core/SystemTop.sv):
//   [0x000, 0x100)          CLINT
//   [0x100, RAM_BASE)       UART (registers only, no serial hardware yet)
//   [RAM_BASE, RAM_END)     RAM (code and data share it)
//   anything else           access fault
#pragma once

#include <stdint.h>

#ifndef RAM_BASE
#error "RAM_BASE must come from the Makefile"
#endif

// ---------------------------------------------------------------------------
// Device registers
//
// Each register is a volatile lvalue at a fixed address, so plain C reads and
// writes become real loads and stores:
//     uint32_t now = CLINT_MTIME;     // load
//     UART_TX_DATA = 'A';             // store
// volatile stops the compiler from caching, merging, dropping or reordering
// these accesses relative to each other.
#define REG32(address) (*(volatile uint32_t *)(uintptr_t)(address))

// CLINT (Core/Peripherals/CLINT.sv). Same semantics as the RISC-V ACLINT;
// the offsets are compacted to fit the device window.
#define CLINT_BASE       0x000u
#define CLINT_MSIP       REG32(CLINT_BASE + 0x00) // bit 0: software interrupt pending
#define CLINT_MTIMECMP   REG32(CLINT_BASE + 0x08) // timer compare, low word
#define CLINT_MTIMECMPH  REG32(CLINT_BASE + 0x0C) // timer compare, high word
#define CLINT_MTIME      REG32(CLINT_BASE + 0x10) // time, low word (counts clock cycles)
#define CLINT_MTIMEH     REG32(CLINT_BASE + 0x14) // time, high word

// Counts delivered timer interrupts. One tick is one CPU cycle.
extern volatile uint32_t seconds;
void set_interval(uint64_t cycles); // Zero disables timer interrupts.

// UART (Core/Peripherals/UART.sv). Low byte of each register is used.
#define UART_BASE        0x100u
#define UART_TX_DATA     REG32(UART_BASE + 0x00)  // write-only: byte to send
#define UART_TX_BUSY     REG32(UART_BASE + 0x04)  // read-only: 1 while sending
#define UART_RX_DATA     REG32(UART_BASE + 0x08)  // read-only: received byte (reading clears RX_READY)
#define UART_RX_READY    REG32(UART_BASE + 0x0C)  // read-only: 1 when a byte is waiting

// ---------------------------------------------------------------------------
// CSRs
//
// C cannot name a CSR, so these use inline assembly. `name` is the CSR's
// assembler name (mstatus, mie, mcause, time, ...), pasted into the
// instruction text with #name.
#define read_csr(name) ({                                         \
    uint32_t __value;                                             \
    __asm__ volatile ("csrr %0, " #name : "=r"(__value));         \
    __value; })
#define write_csr(name, value) \
    __asm__ volatile ("csrw " #name ", %0" :: "rK"((uint32_t)(value)))
#define set_csr(name, bits) \
    __asm__ volatile ("csrs " #name ", %0" :: "rK"((uint32_t)(bits)))
#define clear_csr(name, bits) \
    __asm__ volatile ("csrc " #name ", %0" :: "rK"((uint32_t)(bits)))

// mstatus bits
#define MSTATUS_MIE   (1u << 3)   // global machine interrupt enable
#define MSTATUS_MPIE  (1u << 7)   // MIE before the last trap

// mie / mip bits
#define MIP_MSIP      (1u << 3)   // software interrupt (CLINT msip)
#define MIP_MTIP      (1u << 7)   // timer interrupt (mtime >= mtimecmp)
#define MIP_MEIP      (1u << 11)  // external interrupt

// mcause values. Bit 31 set = interrupt.
#define MCAUSE_INTERRUPT        (1u << 31)
#define MCAUSE_MISALIGNED_FETCH 0
#define MCAUSE_FETCH_ACCESS     1
#define MCAUSE_ILLEGAL          2
#define MCAUSE_BREAKPOINT       3
#define MCAUSE_MISALIGNED_LOAD  4
#define MCAUSE_LOAD_ACCESS      5
#define MCAUSE_MISALIGNED_STORE 6
#define MCAUSE_STORE_ACCESS     7
#define MCAUSE_ECALL_M          11
#define MCAUSE_SOFTWARE_IRQ     (MCAUSE_INTERRUPT | 3)
#define MCAUSE_TIMER_IRQ        (MCAUSE_INTERRUPT | 7)
#define MCAUSE_EXTERNAL_IRQ     (MCAUSE_INTERRUPT | 11)
