/*
 * Bare-metal ESP32-S2 TFT Feather: blink the red LED on GPIO 13.
 * call0 ABI, no C runtime, no IDF. ROM loads this into IRAM and jumps here.
 *
 * LCD (not driven here): ST7789 240x135 on SPI.
 *   TFT_I2C_POWER=21  TFT_BACKLITE=45  TFT_CS=7  TFT_DC=39  TFT_RST=40
 *   MOSI=35  SCK=36  (STEMMA QT also needs GPIO 21 high)
 */

    .section .text._start, "ax"
    .align 4
    .global _start
    .type _start, @function
_start:
    /* User mode, interrupts masked, windowed overflow off (call0). */
    movi    a2, 0x2F            /* PS: INTLEVEL=15, UM=1, WOE=0 */
    wsr     a2, ps
    rsync

    movi    a1, _stack_top

    /* Unlock and disable RTC watchdog (incl. flash-boot mode). */
    movi    a2, 0x3F408000      /* DR_REG_RTCCNTL_BASE */
    movi    a3, 0x50D83AA1
    s32i    a3, a2, 0xAC        /* WDTWPROTECT */
    movi    a3, 0
    s32i    a3, a2, 0x94        /* WDTCONFIG0 */
    s32i    a3, a2, 0xAC

    /* Super WDT */
    movi    a3, 0x8F1D312A
    s32i    a3, a2, 0xB4        /* SWD_WPROTECT */
    l32i    a3, a2, 0xB0        /* SWD_CONF */
    movi    a4, 0x40000000      /* SWD_DISABLE */
    or      a3, a3, a4
    s32i    a3, a2, 0xB0
    movi    a3, 0
    s32i    a3, a2, 0xB4

    /* Timer-group MWDT0 / MWDT1 */
    movi    a2, 0x3F41F000      /* TIMG0 */
    movi    a3, 0x50D83AA1
    s32i    a3, a2, 0x64
    movi    a3, 0
    s32i    a3, a2, 0x48
    s32i    a3, a2, 0x64

    movi    a2, 0x3F420000      /* TIMG1 */
    movi    a3, 0x50D83AA1
    s32i    a3, a2, 0x64
    movi    a3, 0
    s32i    a3, a2, 0x48
    s32i    a3, a2, 0x64

    /* GPIO13: IO_MUX function GPIO, 20 mA drive. */
    movi    a2, 0x3F409038      /* PERIPHS_IO_MUX_GPIO13_U */
    movi    a3, 0x1400          /* MCU_SEL=1, FUN_DRV=2 */
    s32i    a3, a2, 0

    /* Route GPIO_OUT bit 13 to the pad (0x100 = GPIO_OUT). */
    movi    a2, 0x3F404588      /* GPIO_FUNC13_OUT_SEL_CFG */
    movi    a3, 0x100
    s32i    a3, a2, 0

    /* Enable output. */
    movi    a2, 0x3F404024      /* GPIO_ENABLE_W1TS */
    movi    a3, (1 << 13)
    s32i    a3, a2, 0

    movi    a5, 0x3F404008      /* GPIO_OUT_W1TS */
    movi    a6, 0x3F40400C      /* GPIO_OUT_W1TC */
    movi    a7, (1 << 13)

.Lblink:
    s32i    a7, a5, 0
    call0   delay
    s32i    a7, a6, 0
    call0   delay
    j       .Lblink

    .align 4
delay:
    movi    a3, 400000
.Ldelay:
    addi    a3, a3, -1
    bnez    a3, .Ldelay
    ret
