/*
 * Bit-bang SPI mailman for the onboard ST7789.
 *
 * Does not know about commands, pixels, DC, or CS. Those belong to ST7789.S.
 * One job: clock out bytes on MOSI (GPIO 35) with SCK (GPIO 36).
 *
 * Mode 0: clock idles low. We set MOSI, raise SCK (screen samples), lower SCK.
 * MSB first. Write-only — the panel has no MISO wire.
 *
 * call0: a2 = first argument, a0 = return address, ret to come back.
 */

.section .text
.align 4
.literal_position

.equ PIN_MOSI, 35
.equ PIN_SCK,  36

/* GPIO 35 and 36 live in the "high" bank (pin - 32).
 *   MOSI = bit 3 of OUT1
 *   SCK  = bit 4 of OUT1
 * OUT1_W1TS at GPIO_BASE+0x14 sets bits; OUT1_W1TC at +0x18 clears them. */
.equ BIT_MOSI, (1 << 3)
.equ BIT_SCK,  (1 << 4)

.extern gpio_out_setup
.extern gpio_write

/* void spi_init(void) — pads as GPIO outputs, clock idle low. */
.global spi_init
.type spi_init, @function
spi_init:
    addi    a1, a1, -16
    s32i    a0, a1, 0           /* save return address; we are about to call0 */

    movi    a2, PIN_MOSI
    call0   gpio_out_setup
    movi    a2, PIN_SCK
    call0   gpio_out_setup

    movi    a2, PIN_MOSI
    movi    a3, 0
    call0   gpio_write
    movi    a2, PIN_SCK
    movi    a3, 0
    call0   gpio_write          /* SCK idle low = SPI mode 0 */

    l32i    a0, a1, 0
    addi    a1, a1, 16
    ret

/* void spi_byte(uint8_t b)
 * a2 = the byte. Eight times: put bit 7 on MOSI, pulse SCK, shift left. */
.global spi_byte
.type spi_byte, @function
spi_byte:
    movi    a4, 0x3F404000      /* a4 = GPIO_BASE */
    movi    a3, 8               /* 8 bits to send */

.Lbit:
    /* MOSI = top bit of a2 */
    bbci    a2, 7, .Lmosi_lo    /* branch if bit 7 is clear */
    movi    a5, BIT_MOSI
    s32i    a5, a4, 0x14        /* OUT1_W1TS — MOSI high */
    j       .Lclk
.Lmosi_lo:
    movi    a5, BIT_MOSI
    s32i    a5, a4, 0x18        /* OUT1_W1TC — MOSI low */
.Lclk:
    memw
    movi    a5, BIT_SCK
    s32i    a5, a4, 0x14        /* SCK high — ST7789 samples MOSI */
    memw
    s32i    a5, a4, 0x18        /* SCK low */
    memw

    slli    a2, a2, 1           /* next bit into bit 7 */
    addi    a3, a3, -1
    bnez    a3, .Lbit
    ret
