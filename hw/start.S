/*
 * Bare-metal blink for the Adafruit ESP32-S2 TFT Feather (red LED = GPIO 13).
 *
 * No C, no IDF, no libc. The 2nd-stage bootloader copies this into IRAM and
 * jumps to _start. We never return.
 *
 * Xtensa call0 ABI (we pass -mabi=call0 to gcc):
 *   a0  return address after call0 / ret
 *   a1  stack pointer (we set it; nothing else uses the stack yet)
 *   a2–a7  scratch / arguments  (a8–a15 exist too; we barely use them)
 *
 * Memory-mapped I/O: a device is just an address. s32i writes a 32-bit
 * register, l32i reads one. Offsets are in bytes.
 *
 * LCD pins (not used here):
 *   TFT_I2C_POWER=21  TFT_BACKLITE=45  TFT_CS=7  TFT_DC=39  TFT_RST=40
 *   MOSI=35  SCK=36
 */

    /* "ax" = allocatable + executable. Linker puts this in IRAM (see esp32s2.ld). */
    .section .text._start, "ax"
    .align 4                    /* Xtensa wants 32-bit alignment for entry. */
    .global _start              /* Export so the ELF entry point can find us. */
    .type _start, @function
_start:
    /*----------------------------------------------------------------------
     * Processor State (special register "ps").
     *
     * movi  a2, imm     — put a constant in a2 (may become l32r + a literal).
     * wsr   a2, ps      — write special register.
     * rsync             — wait until that write is visible. Always after wsr.
     *
     * 0x2F = INTLEVEL=15 | UM=1 | WOE=0
     *   INTLEVEL 15  mask all interrupts (we have no handlers).
     *   UM=1         user mode (normal for apps).
     *   WOE=0        disable windowed registers. call0/ret need this off,
     *                or a call can take a window-overflow exception.
     *----------------------------------------------------------------------*/
    movi    a2, 0x2F
    wsr     a2, ps
    rsync

    /* a1 = top of the 4 KiB we reserved in DRAM (_stack_top in the linker script).
     * call0 does not push a frame by itself; we would store a0 here if delay
     * needed more than a leaf function. */
    movi    a1, _stack_top

    /*----------------------------------------------------------------------
     * Watchdogs. The bootloader leaves several running. If we do not kill
     * them, the chip resets after a short time (looks like “blinked twice”).
     *
     * Pattern for a protected WDT register:
     *   write magic key to *WPROTECT  → unlock
     *   write config / disable
     *   write 0 to *WPROTECT          → lock again
     *----------------------------------------------------------------------*/

    /* RTC watchdog (also has a “flash boot” mode that stays on even if the
     * main enable looks off). Base 0x3F408000 = DR_REG_RTCCNTL_BASE. */
    movi    a2, 0x3F408000      /* a2 = RTC_CNTL base for the next few stores */
    movi    a3, 0x50D83AA1      /* official unlock key */
    s32i    a3, a2, 0xAC        /* [base+0xAC] WDTWPROTECT = key */
    movi    a3, 0
    s32i    a3, a2, 0x94        /* [base+0x94] WDTCONFIG0 = 0  (off + no flashboot) */
    s32i    a3, a2, 0xAC        /* lock */

    /* Super WDT (SWD): a second, nastier timer. Unlock, set DISABLE, lock.
     * l32i / or / s32i is read-modify-write so we do not clobber other bits. */
    movi    a3, 0x8F1D312A
    s32i    a3, a2, 0xB4        /* SWD_WPROTECT = key */
    l32i    a3, a2, 0xB0        /* a3 = SWD_CONF */
    movi    a4, 0x40000000      /* bit 30 = SWD_DISABLE */
    or      a3, a3, a4          /* a3 = a3 | a4 */
    s32i    a3, a2, 0xB0
    movi    a3, 0
    s32i    a3, a2, 0xB4        /* lock */

    /* Timer-group watchdogs (MWDT). Same unlock / zero CONFIG0 / lock.
     * TIMG0 at 0x3F41F000, TIMG1 at +0x1000. CONFIG0 @ +0x48, WPROTECT @ +0x64. */
    movi    a2, 0x3F41F000
    movi    a3, 0x50D83AA1
    s32i    a3, a2, 0x64
    movi    a3, 0
    s32i    a3, a2, 0x48
    s32i    a3, a2, 0x64

    movi    a2, 0x3F420000
    movi    a3, 0x50D83AA1
    s32i    a3, a2, 0x64
    movi    a3, 0
    s32i    a3, a2, 0x48
    s32i    a3, a2, 0x64

    /*----------------------------------------------------------------------
     * GPIO 13 = the little red LED labeled #13.
     *
     * On ESP32 a pad is not “just a GPIO.” IO_MUX picks a function
     * (SPI, UART, GPIO, …). The GPIO matrix then picks which *signal*
     * drives that GPIO. Then ENABLE lets the pin actually toggle.
     *----------------------------------------------------------------------*/

    /* IO_MUX for GPIO13 at 0x3F409038.
     * 0x1400 = MCU_SEL=1 (function GPIO) and FUN_DRV=2 (~20 mA). */
    movi    a2, 0x3F409038
    movi    a3, 0x1400
    s32i    a3, a2, 0

    /* GPIO_FUNC13_OUT_SEL: 0x100 means “drive this pad from GPIO_OUT bit N”,
     * not from some peripheral. */
    movi    a2, 0x3F404588
    movi    a3, 0x100
    s32i    a3, a2, 0

    /* GPIO_ENABLE_W1TS: write-1-to-set. Writing (1<<13) enables output on 13
     * without touching the other 31 enable bits. */
    movi    a2, 0x3F404024
    movi    a3, (1 << 13)
    s32i    a3, a2, 0

    /* Keep the toggle addresses in a5/a6 so the loop is three cheap insns.
     * W1TS = write-1-to-set  (LED on),  W1TC = write-1-to-clear (LED off). */
    movi    a5, 0x3F404008
    movi    a6, 0x3F40400C
    movi    a7, (1 << 13)       /* bit mask, reused every iteration */

    /* Local label (.L...) is not exported. j is a PC-relative jump. */
.Lblink:
    s32i    a7, a5, 0           /* LED on */
    call0   delay               /* a0 := return addr; jump to delay */
    s32i    a7, a6, 0           /* LED off */
    call0   delay
    j       .Lblink             /* forever — there is no “return to main” */

    .align 4
delay:
    /* Busy-wait. Not a real timer. Count is tuned so you can *see* the blink
     * at the ROM/bootloader clock (tens of MHz). call0/ret: delay must not
     * trash a0, and must not call anything else unless it saves a0. */
    movi    a3, 8000000
.Ldelay:
    addi    a3, a3, -1          /* a3 = a3 - 1 */
    bnez    a3, .Ldelay         /* if a3 != 0, spin */
    ret                         /* jump to a0 (back into .Lblink) */
