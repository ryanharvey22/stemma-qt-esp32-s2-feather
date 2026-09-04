/*
 * GPIO functions for ESP32-S2 TFT Feather
 *
 * Assembly version of gpio.c. call0 ABI (see start.S / -mabi=call0):
 *   a0  return address  — ret jumps here
 *   a1  stack pointer   — we do not use the stack
 *   a2  first argument  (pin)
 *   a3  second argument (high, gpio_write only)
 *   a4–a7  scratch
 *
 * A peripheral is just an address. s32i writes 32 bits; the ESP32-S2 GPIO
 * and IO_MUX blocks sit at the bases in the literal pool below.
 */

.section .text
.align 4                    /* Xtensa wants 32-bit alignment for entry points. */
.literal_position           /* Assembler parks auto-generated l32r literals here. */

/*--------------------------------------------------------------------------
 * void gpio_out_setup(int pin)
 *
 * Make `pin` a GPIO output:
 *   1. IO_MUX: route the pad to the GPIO matrix, 20 mA drive (0x1400)
 *   2. GPIO_FUNCn_OUT_SEL: take the output from GPIO_OUT, not a peripheral
 *   3. ENABLE_W1TS / ENABLE1_W1TS: turn the output driver on
 *--------------------------------------------------------------------------*/
.global gpio_out_setup
.type gpio_out_setup, @function
gpio_out_setup:
    /* a2 is `pin` from the caller. We never overwrite it until we are done
     * using it as an index (all three steps need the pin number). */

    /*----- step 1: wr(IOMUX_BASE + iomux_off[pin], 0x1400) -----*/

    /* l32r = "load 32-bit from a PC-relative literal".
     * movi cannot hold a 32-bit address, so the constant lives in a .word
     * later in this file and we load it into a register. */
    l32r    a3, L_IOMUX_BASE    /* a3 = 0x3F409000, the IO_MUX register block */
    l32r    a4, L_IOMUX_OFF     /* a4 = &iomux_off[0], pointer to the lookup table */

    /* addx2 dest, src, base  means  dest = base + (src << 1).
     * Each table entry is a uint16_t (2 bytes), so pin * 2 is the byte
     * offset. a5 now points at iomux_off[pin]. */
    addx2   a5, a2, a4

    /* l16ui = load 16 bits, zero-extend to 32. Offset 0: we already have
     * the element address in a5. a5 = iomux_off[pin] (byte offset of that
     * pad's IO_MUX register, or 0 if we never use this pin). */
    l16ui   a5, a5, 0

    /* a3 = IOMUX_BASE + iomux_off[pin]  — the pad register we will write. */
    add     a3, a3, a5

    /* 0x1400 is also too wide for a small immediate, so it is a literal.
     * Bits: function = GPIO, drive strength = 20 mA (matches the C). */
    l32r    a4, L_0x1400        /* a4 = 0x1400 */
    s32i    a4, a3, 0           /* store 32 bits: *a3 = 0x1400 */

    /* memw = memory wait. Xtensa can keep going before an MMIO store is
     * visible to the peripheral. memw drains the write so the next access
     * sees the new pad function. */
    memw

    /*----- step 2: wr(GPIO_BASE + 0x554 + pin*4, 0x100) -----*/
    /* GPIO_FUNCn_OUT_SEL_CFG for pin n lives at base + 0x554 + n*4.
     * 0x100 = "output comes from the GPIO_OUT register" (not a peri signal). */

    l32r    a3, L_GPIO_BASE     /* a3 = 0x3F404000 */
    movi    a4, 0x554           /* movi fits 12-bit signed immediates; 0x554 is fine */
    add     a3, a3, a4          /* a3 = GPIO_BASE + 0x554 */

    /* addx4 dest, src, base  means  dest = base + (src << 2).
     * Each FUNCn register is 4 bytes, so pin * 4. We cannot put 0x554 on
     * s32i itself: s32i immediates only go 0..1020. */
    addx4   a5, a2, a3          /* a5 = GPIO_BASE + 0x554 + pin*4 */

    movi    a4, 0x100           /* a4 = 0x100, "source = GPIO_OUT" */
    s32i    a4, a5, 0           /* *a5 = 0x100 */
    memw                        /* wait until the matrix sees it */

    /*----- step 3: turn the output driver on -----*/
    /* Pins 0–31 use ENABLE_W1TS  at GPIO_BASE + 0x24 (write-1-to-set).
     * Pins 32–45 use ENABLE1_W1TS at GPIO_BASE + 0x30.
     * Writing a 1 in bit k enables that pin; other bits are left alone. */

    l32r    a3, L_GPIO_BASE     /* a3 = GPIO_BASE again (a3 was clobbered above) */
    movi    a4, 32              /* a4 = 32, the bank split */

    /* blt a, b, label  = branch if a < b (signed).
     * Here: if pin < 32, go configure the low bank. Otherwise fall through
     * and use ENABLE1 with bit (pin - 32). */
    blt     a2, a4, .L_setup_low

    /* pin >= 32: bit index is pin - 32 (0 for GPIO32, 13 for GPIO45). */
    sub     a5, a2, a4          /* a5 = pin - 32 */

    /* ssl / sll is how Xtensa does a variable left shift (there is no
     * "slli rd, rs, register" form):
     *   ssl src     sets the Shift Amount Register: SAR = 32 - (src & 31)
     *   sll dest, src   dest = src << (32 - SAR)
     * Together: dest = src << amount. We want 1u << (pin - 32). */
    movi    a4, 1
    ssl     a5                  /* SAR prepared for a shift of (pin - 32) */
    sll     a4, a4              /* a4 = 1 << (pin - 32) */

    /* s32i val, base, imm  stores 32 bits at base+imm. 0x30 fits (must be
     * a multiple of 4 and <= 1020). This is ENABLE1_W1TS. */
    s32i    a4, a3, 0x30
    j       .L_setup_done       /* skip the low-bank path; j = unconditional jump */

.L_setup_low:
    /* pin < 32: same 1 << pin, but the enable register is +0x24. */
    movi    a4, 1
    ssl     a2                  /* SAR prepared for a shift of pin */
    sll     a4, a4              /* a4 = 1 << pin */
    s32i    a4, a3, 0x24        /* ENABLE_W1TS */

.L_setup_done:
    memw                        /* make sure the enable write has landed */
    ret                         /* jump to a0; caller resumes after call0 */

/*--------------------------------------------------------------------------
 * void gpio_write(int pin, int high)
 *
 * Drive the pin high or low by writing 1 << bit into a write-1-to-set or
 * write-1-to-clear register (we never read-modify-write GPIO_OUT).
 *
 *   pin <  32: OUT_W1TS  +0x08  /  OUT_W1TC  +0x0C
 *   pin >= 32: OUT1_W1TS +0x14  /  OUT1_W1TC +0x18
 *--------------------------------------------------------------------------*/
.global gpio_write
.type gpio_write, @function
gpio_write:
    /* entry a1, 32  is the windowed-ABI prologue: rotate the register
     * window and allocate a 32-byte frame. This project compiles -mabi=call0
     * and start.S clears WOE, so the caller already left pin in a2 / high
     * in a3 and expects a plain ret. Left as written. */
    entry   a1, 32

    l32r    a4, L_GPIO_BASE     /* a4 = 0x3F404000; we will add the W1TS/W1TC offset */
    movi    a5, 32
    blt     a2, a5, .L_write_low_pins   /* if pin < 32, low bank (bits 0–31) */

    /* High bank: the bit we set is (pin - 32), not pin. */
    sub     a2, a2, a5          /* a2 = pin - 32  (reuse a2; we are done with `pin`) */
    movi    a5, 1
    ssl     a2                  /* SAR = shift of (pin - 32) */
    sll     a5, a5              /* a5 = 1u << (pin - 32)  — this is `bit` in the C */

    /* Pick the register offset: high ? 0x14 : 0x18.
     * beqz rs, label  = branch if rs == 0. a3 is `high`. */
    movi    a2, 0x18            /* assume low: OUT1_W1TC (clear / drive 0) */
    beqz    a3, .L_write_exec   /* high == 0, keep 0x18 */
    movi    a2, 0x14            /* high != 0: OUT1_W1TS (set / drive 1) */
    j       .L_write_exec

.L_write_low_pins:
    /* pin < 32 */
    movi    a5, 1
    ssl     a2                  /* SAR prepared for a shift of pin */
    sll     a5, a5              /* a5 = 1u << pin  (`bit`) */

    /* high ? 0x08 : 0x0C */
    movi    a2, 0x0C            /* assume low: OUT_W1TC */
    beqz    a3, .L_write_exec   /* high == 0, keep 0x0C */
    movi    a2, 0x08            /* high != 0: OUT_W1TS */

.L_write_exec:
    add     a4, a4, a2          /* a4 = GPIO_BASE + chosen offset */
    s32i    a5, a4, 0           /* wr(addr, bit) — only that one pin changes */
    memw                        /* drain the store so the pad updates before we return */

    /* retw = windowed return (undoes entry). Pair with entry; call0 uses ret. */
    retw

/* Literals for l32r. Must be 4-byte aligned and within ~256 KiB of the
 * loads (they are in the same .text section, so they are). */
.align 4
L_GPIO_BASE:  .word 0x3F404000  /* GPIO register block */
L_IOMUX_BASE: .word 0x3F409000  /* IO_MUX pad-function block */
L_0x1400:     .word 0x1400      /* GPIO function + 20 mA drive */
L_IOMUX_OFF:  .word iomux_off   /* address of the table, not a table entry */

/* IO_MUX register offset for each pad we touch. Unused pins stay 0.
 * Indexed by GPIO number; each .short is 2 bytes (see addx2 above). */
.section .rodata
.align 4
iomux_off:
    .short 0, 0, 0, 0, 0, 0, 0, 0x20          /*  0 -  7   TFT_CS = 7  */
    .short 0, 0, 0, 0, 0, 0x38, 0, 0          /*  8 - 15   LED    = 13 */
    .short 0, 0, 0, 0, 0, 0x58, 0, 0          /* 16 - 23   I2C pwr= 21 */
    .short 0, 0, 0, 0, 0, 0, 0, 0             /* 24 - 31              */
    .short 0, 0, 0, 0x90, 0x94, 0, 0, 0xA0    /* 32 - 39   MOSI/SCK/DC */
    .short 0xA4, 0, 0, 0, 0, 0xB8             /* 40 - 45   RST / backlight */
