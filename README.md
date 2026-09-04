1. Drive the power enable gpio pin to high to power the diplay chip
2. Need to toggle the reset to clear the screen controller
3. Configure the esp32 SPI peripheral registers (baud rate, clock phase, bit order)
4. Pull the TFT DC pin low and stream initialization command bytes over SPI
5. Set an address window (0x2A/0x2B), send the RAM write command (0x2C), pull 
   TFT_DC high, and stream your raw pixel array data.

The ESP32 communicates with the on board dispay ove SPI.

https://www.adafruit.com/product/5300

### QEMU setup for simulation
This is outside the scope of this repo and not implemented, but will link some references. Below some QEMU references.
https://github.com/espressif/esp-toolchain-docs/blob/main/qemu/esp32/README.md
https://shawnhymel.com/2954/esp32-how-to-use-i2c-with-esp-idf/
The next link is the implementation of a QEMU I2C slave.  
https://github.com/espressif/qemu/blob/esp-develop/hw/xtensa/esp32.c
Another reference for implementing custom QEMU peripherals.
https://www.mistrasolutions.com/page/qemu-custom-i2c-peripheral/