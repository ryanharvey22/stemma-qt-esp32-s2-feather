/*
 * Onboard ST7789 on the Adafruit ESP32-S2 TFT Feather.
 *
 * Glass is 240 wide × 135 tall (1.14"). The controller RAM is 240×320; we
 * paint a window with a o 40,53ffset (Adafruit rotation 3, USB-C on the left).
 *
 * First milestone: turn the panel on and fill it with one color.
 * If you see a solid color, power / reset / SPI / init all worked.
 *
 * Wires (not I2C, not the Feather-header SPI):
 *   21  TFT_I2C_POWER  regulator — must be high
 *   45  backlight
 *   40  reset (pulse low then high)
 *    7  CS  (low = talking to this chip)
 *   39  DC  (low = command byte, high = data/pixels)
 *   35  MOSI }  spi.S clocks these
 *   36  SCK  }
 */

.section .text
.align 4
.literal_position

.equ PIN_POWER,    21
.equ PIN_BACKLITE, 45
.equ PIN_CS,        7
.equ PIN_DC,       39
.equ PIN_RST,      40

.equ CMD_SWRESET,  0x01
.equ CMD_SLPOUT,   0x11
.equ CMD_NORON,    0x13
.equ CMD_INVON,    0x21
.equ CMD_DISPON,   0x29
.equ CMD_CASET,    0x2A
.equ CMD_RASET,    0x2B
.equ CMD_RAMWR,    0x2C
.equ CMD_MADCTL,   0x36
.equ CMD_COLMOD,   0x3A
.equ MADCTL_MX_MV, 0x60       /* MX|MV — landscape, USB-C left */
.equ COLMOD_16,    0x55       /* RGB565 */

.equ XSTART, 40
.equ YSTART, 53
.equ TFT_W,  240
.equ TFT_H,  135

.extern gpio_out_setup
.extern gpio_write
.extern spi_init
.extern spi_byte

/* a2 = loop count. Tiny busy-wait; not calibrated to exact milliseconds. */
delay_loops:
    addi    a2, a2, -1
    bnez    a2, delay_loops
    ret

/* a2 = "milliseconds" (each one is 20000 inner loops). */
delay_ms:
    addi    a1, a1, -16
    s32i    a0, a1, 0
    s32i    a2, a1, 4
.Lms:
    l32i    a2, a1, 4
    beqz    a2, .Lms_done
    addi    a2, a2, -1
    s32i    a2, a1, 4
    movi    a2, 20000
    call0   delay_loops
    j       .Lms
.Lms_done:
    l32i    a0, a1, 0
    addi    a1, a1, 16
    ret

/* void st7789_cmd(uint8_t c) — DC low, CS low, one byte, CS high. */
st7789_cmd:
    addi    a1, a1, -16
    s32i    a0, a1, 0
    s32i    a2, a1, 4           /* save the command byte */

    movi    a2, PIN_DC
    movi    a3, 0
    call0   gpio_write          /* “this next byte is an order” */
    movi    a2, PIN_CS
    movi    a3, 0
    call0   gpio_write

    l32i    a2, a1, 4
    call0   spi_byte

    movi    a2, PIN_CS
    movi    a3, 1
    call0   gpio_write

    l32i    a0, a1, 0
    addi    a1, a1, 16
    ret

/* void st7789_data(uint8_t d) — same, but DC high (“this is payload”). */
st7789_data:
    addi    a1, a1, -16
    s32i    a0, a1, 0
    s32i    a2, a1, 4

    movi    a2, PIN_DC
    movi    a3, 1
    call0   gpio_write
    movi    a2, PIN_CS
    movi    a3, 0
    call0   gpio_write

    l32i    a2, a1, 4
    call0   spi_byte

    movi    a2, PIN_CS
    movi    a3, 1
    call0   gpio_write

    l32i    a0, a1, 0
    addi    a1, a1, 16
    ret

/* void st7789_init(void) */
.global st7789_init
.type st7789_init, @function
st7789_init:
    addi    a1, a1, -16
    s32i    a0, a1, 0

    /* Every TFT pad as a GPIO output. */
    movi    a2, PIN_POWER
    call0   gpio_out_setup
    movi    a2, PIN_BACKLITE
    call0   gpio_out_setup
    movi    a2, PIN_CS
    call0   gpio_out_setup
    movi    a2, PIN_DC
    call0   gpio_out_setup
    movi    a2, PIN_RST
    call0   gpio_out_setup
    call0   spi_init            /* MOSI + SCK */

    /* Power and lamp on. Without pin 21 the glass stays dead. */
    movi    a2, PIN_POWER
    movi    a3, 1
    call0   gpio_write
    movi    a2, 10
    call0   delay_ms
    movi    a2, PIN_BACKLITE
    movi    a3, 1
    call0   gpio_write

    movi    a2, PIN_CS
    movi    a3, 1
    call0   gpio_write          /* idle: not selected */

    /* Hardware reset of the ST7789. */
    movi    a2, PIN_RST
    movi    a3, 0
    call0   gpio_write
    movi    a2, 10
    call0   delay_ms
    movi    a2, PIN_RST
    movi    a3, 1
    call0   gpio_write
    movi    a2, 10
    call0   delay_ms

    movi    a2, CMD_SWRESET
    call0   st7789_cmd
    movi    a2, 150
    call0   delay_ms

    movi    a2, CMD_SLPOUT      /* leave sleep */
    call0   st7789_cmd
    movi    a2, 10
    call0   delay_ms

    movi    a2, CMD_COLMOD
    call0   st7789_cmd
    movi    a2, COLMOD_16
    call0   st7789_data         /* 16-bit color */

    movi    a2, CMD_MADCTL
    call0   st7789_cmd
    movi    a2, MADCTL_MX_MV
    call0   st7789_data

    movi    a2, CMD_INVON       /* this panel’s colors are inverted */
    call0   st7789_cmd
    movi    a2, 10
    call0   delay_ms

    movi    a2, CMD_NORON
    call0   st7789_cmd
    movi    a2, 10
    call0   delay_ms

    movi    a2, CMD_DISPON      /* show whatever is in RAM */
    call0   st7789_cmd
    movi    a2, 10
    call0   delay_ms

    l32i    a0, a1, 0
    addi    a1, a1, 16
    ret

/* void st7789_fill(uint16_t color)
 * a2 = RGB565 (e.g. 0xF800 red, 0x07E0 green, 0x001F blue, 0xFFFF white).
 * Sets the visible window, then streams width*height pixels. */
.global st7789_fill
.type st7789_fill, @function
st7789_fill:
    addi    a1, a1, -16
    s32i    a0, a1, 0
    s32i    a2, a1, 4           /* color */

    /* Column address: x = 0..239 in glass space → + XSTART in controller RAM. */
    movi    a2, CMD_CASET
    call0   st7789_cmd
    movi    a2, 0
    call0   st7789_data
    movi    a2, XSTART
    call0   st7789_data
    /* x1 = 239 + 40 = 279 = 0x0117 */
    movi    a2, 0x01
    call0   st7789_data
    movi    a2, 0x17
    call0   st7789_data

    /* Row address: y = 0..134 → + YSTART. y1 = 134+53 = 187 = 0x00BB */
    movi    a2, CMD_RASET
    call0   st7789_cmd
    movi    a2, 0
    call0   st7789_data
    movi    a2, YSTART
    call0   st7789_data
    movi    a2, 0
    call0   st7789_data
    movi    a2, 0xBB
    call0   st7789_data

    movi    a2, CMD_RAMWR       /* “pixels follow” */
    call0   st7789_cmd

    /* Hold CS, DC=data, and blast 240*135 16-bit pixels. */
    movi    a2, PIN_DC
    movi    a3, 1
    call0   gpio_write
    movi    a2, PIN_CS
    movi    a3, 0
    call0   gpio_write

    movi    a3, TFT_W * TFT_H   /* 32400 */
    s32i    a3, a1, 8
.Lpix:
    l32i    a3, a1, 8
    beqz    a3, .Lpix_done
    addi    a3, a3, -1
    s32i    a3, a1, 8

    l32i    a2, a1, 4           /* color */
    srli    a2, a2, 8           /* high byte first */
    call0   spi_byte
    l32i    a2, a1, 4
    movi    a3, 0xFF
    and     a2, a2, a3          /* low byte */
    call0   spi_byte
    j       .Lpix
.Lpix_done:
    movi    a2, PIN_CS
    movi    a3, 1
    call0   gpio_write

    l32i    a0, a1, 0
    addi    a1, a1, 16
    ret
