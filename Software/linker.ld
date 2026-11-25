OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = __ram_base;

    .text :
    {
        KEEP(*(.text.init))
        *(.text .text.*)
    }

    .rodata :
    {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    }

    .data :
    {
        *(.data .data.*)
        . = ALIGN(8);
        /* Signed 12-bit offsets cover the first 4 KiB from this boundary. */
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
    }

    .preinit_array : ALIGN(4)
    {
        PROVIDE_HIDDEN(__preinit_array_start = .);
        KEEP(*(.preinit_array))
        PROVIDE_HIDDEN(__preinit_array_end = .);
    }

    .init_array : ALIGN(4)
    {
        PROVIDE_HIDDEN(__init_array_start = .);
        KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*)))
        KEEP(*(.init_array))
        PROVIDE_HIDDEN(__init_array_end = .);
    }

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    }

    __heap_start = ALIGN(., 16);
    __stack_top = __ram_end & ~15;

    ASSERT(_start == __ram_base && LOADADDR(.text) == __ram_base,
           "Startup and image must begin at RAM_BASE")
    ASSERT(__heap_start < __stack_top,
           "Static allocations leave no space for heap or stack")
}
