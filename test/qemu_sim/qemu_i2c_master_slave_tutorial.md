# I2C master and slave on Espressif QEMU

The master is the guest firmware. The slave is a device compiled into QEMU. They meet on the bus owned by the emulated I2C controller. A second process cannot sit on that bus.

This is the original ESP32 controller in the `esp-develop` tree, reached with `-machine esp32`. Controller 0 is at `0x3FF53000`. The ESP32-S2 I2C block is at `0x3F413000` and this machine does not decode it. Bit-banged GPIO never enters the controller.

## Build

```sh
git clone --recursive https://github.com/espressif/qemu.git
cd qemu && mkdir build && cd build
../configure --target-list=xtensa-softmmu --enable-gcrypt
ninja
./qemu-system-xtensa -nographic -machine esp32 \
  -drive file=flash.bin,if=mtd,format=raw \
  -serial mon:stdio
```

## The slave that is already there

`hw/xtensa/esp32.c`, in `esp32_machine_init_i2c`, hangs a TMP105 on controller 0 at 7-bit address `0x48`:

```c
I2CBus *i2c_bus = I2C_BUS(qdev_get_child_bus(DEVICE(&s->i2c[0]), "i2c"));
i2c_slave_create_simple(i2c_bus, "tmp105", 0x48);
```

`-device` cannot add another slave. That bus is not on `sysbus-default`, so the command line never sees it. New slaves are added with another `i2c_slave_create_simple` in this function, then QEMU is rebuilt.

The controller is master only. `CTR.MS_MODE` (bit 4 of offset `0x04`) must be 1. Slave mode of the controller logs an error and does not respond.

## Master transfer

The transfer runs to completion inside the store that sets `CTR.TRANS_START` (bit 5 of offset `0x04`). QEMU walks the 16 command registers at offset `0x58` before that store returns.

FIFO data is offset `0x1c`. Both FIFOs are 32 bytes. Push the address byte first, then the payload. The address byte is `(addr << 1) | rnw`.

Command fields:

| Field | Bits |
|---|---|
| `BYTE_NUM` | 0..7, and on a `WRITE` this count includes the address byte |
| `ACK_CHECK_EN` | 8 |
| `ACK_EXP` | 9 |
| `ACK_VAL` | 10 |
| `OPCODE` | 11..13 |
| `DONE` | 31, set by the model when the slot finishes |

Opcodes: `RSTART=0`, `WRITE=1`, `READ=2`, `STOP=3`, `END=4`.

Write one register: `WRITE` with `BYTE_NUM=2` (address, register index), then `STOP`.

Repeated-start read: `WRITE` (address with write bit, register index), `RSTART`, `WRITE` with `BYTE_NUM=1` and the read bit set, `READ` with `BYTE_NUM` equal to the number of data bytes, then `STOP`. `RSTART` ends the current transfer so the next `WRITE` starts a new one. Do not put a `STOP` between them.

After `STOP`, `INT_RAW.TRANS_COMPLETE` (bit 7 of offset `0x20`) is set. Read the RX FIFO at offset `0x1c`. If no slave answers the address, the transfer stops. `ACK_ERR` (bit 10) is set when that command has `ACK_CHECK_EN` set and `ACK_EXP` clear.

Prove the master against the TMP105 before writing a new slave. A read of its temperature register at `0x48` must come back through the RX FIFO.

## A slave of your own

Copy `hw/sensor/tmp105.c`. Subclass `TYPE_I2C_SLAVE`. QEMU matches the 7-bit address and does not pass the address byte to the device.

- `event` receives `I2C_START_SEND`, `I2C_START_RECV`, and `I2C_FINISH`.
- `send` receives each byte the master wrote, starting with the register index.
- `recv` returns the next byte the master reads.

Register the type, then attach it next to the TMP105:

```c
i2c_slave_create_simple(i2c_bus, "lsm6dsox", 0x6A);
```

Rebuild and boot the same `-machine esp32` command. For an LSM6DSOX, `WHO_AM_I` is register `0x0F` and reads `0x6C`. Accel is six little-endian bytes at `0x28`. Gyro is six little-endian bytes at `0x22`.
