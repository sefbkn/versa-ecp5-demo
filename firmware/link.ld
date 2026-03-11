/* Minimal VexRiscv SoC linker script.
 * Reset vector is at 0x0 and mtvec is hardwired to 0x20.
 */

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 8K
}

STACK_SIZE = 1024;
PROVIDE(__global_pointer$ = ORIGIN(RAM) + 0x800);

ENTRY(_start)

SECTIONS
{
    /* Reset vector at address 0 */
    .text.start 0x00000000 : {
        KEEP(*(.text.start))
    } > ROM

    /* Trap vector at address 0x20 (VexRiscv hardwired mtvec) */
    .trap 0x00000020 : {
        KEEP(*(.trap))
    } > ROM

    .text : {
        *(.text .text.*)
    } > ROM

    .rodata : {
        *(.rodata .rodata.*)
    } > ROM

    .data : {
        . = ALIGN(4);
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
    } > RAM AT > ROM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        . = ALIGN(4);
    } > RAM

    /DISCARD/ : {
        *(.eh_frame)
        *(.eh_frame_hdr)
    }

    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
    __stack_bottom = __stack_top - STACK_SIZE;

}

ASSERT(SIZEOF(.data) == 0, ".data requires startup copy logic");
ASSERT(SIZEOF(.bss) == 0, ".bss requires startup zero logic");
ASSERT(ADDR(.bss) + SIZEOF(.bss) <= __stack_bottom, "RAM overflow");
