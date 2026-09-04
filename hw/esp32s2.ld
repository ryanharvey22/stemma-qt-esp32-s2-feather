/* ESP32-S2: 320 KiB SRAM, IRAM and DRAM are the same cells on two buses.
 * IRAM 0x40020000 == DRAM 0x3FFB0000. Keep .text in low IRAM and the
 * stack in high DRAM so they do not overlap. ROM copies PT_LOAD into RAM. */

MEMORY
{
    iram (rx) : ORIGIN = 0x40022000, LENGTH = 128K
    dram (rw) : ORIGIN = 0x3FFE0000, LENGTH = 16K
}

ENTRY(_start)

SECTIONS
{
    .text : {
        . = ALIGN(4);
        KEEP(*(.text._start))
        *(.literal .literal.*)
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.data .data.*)
        . = ALIGN(4);
    } > iram

    .bss (NOLOAD) : {
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        _stack_bottom = .;
        . += 4K;
        _stack_top = .;
    } > dram
}
