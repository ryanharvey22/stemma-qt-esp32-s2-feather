/*
 * Adafruit LSM6DSOX on the Feather STEMMA QT port (I2C).
 *
 * Plug: STEMMA cable, no extra wires. The IMU does not use SPI / the TFT pins.
 *
 * Feather side (you must drive these before talking):
 *   GPIO 21  TFT_I2C_POWER  — high, or STEMMA has no 3.3 V
 *   GPIO  3  SDA
 *   GPIO  4  SCL
 *
 * Chip address (7-bit): 0x6A default. Solder jumper D0 on the breakout → 0x6B.
 * First transaction should read WHO_AM_I (0x0F) and expect 0x6C. Anything else
 * means wrong address, power still off, or a different chip.
 *
 * What the chip actually measures
 *   ax, ay, az   linear acceleration, including gravity (~9.8 m/s² on Z if flat)
 *   gx, gy, gz   rotation rate (degrees or rad per second)
 *
 * There is NO quaternion register. q0..q3 are computed later (Madgwick/Mahony)
 * from gyro + accel. Without a magnetometer, yaw drifts.
 *
 * I2C write one register:  START, addr+W, reg, value, STOP
 * I2C read  accel (6 bytes, auto-increment):
 *   START, addr+W, 0x28, RESTART, addr+R, read 6, STOP
 *   bytes: XL,XH, YL,YH, ZL,ZH   (each axis is int16 little-endian)
 * Gyro is the same starting at 0x22.
 *
 * i2c.S should expose something like:
 *   i2c_write_reg(addr, reg, val)
 *   i2c_read_regs(addr, reg, dst, n)
 * This file then: init, whoami, read_accel, read_gyro.
 */

.section .text

/* Register numbers (not assembled into code until a function uses them). */
.equ LSM6_ADDR,       0x6A
.equ LSM6_WHO_AM_I,   0x0F
.equ LSM6_CHIP_ID,    0x6C
.equ LSM6_CTRL1_XL,   0x10    /* accel ODR + full-scale */
.equ LSM6_CTRL2_G,    0x11    /* gyro  ODR + full-scale */
.equ LSM6_CTRL3_C,    0x12    /* BDU + auto-increment */
.equ LSM6_OUTX_L_G,   0x22    /* gyro  xyz, 6 bytes */
.equ LSM6_OUTX_L_A,   0x28    /* accel xyz, 6 bytes */

/* Typical init values (104 Hz, accel ±2 g, gyro ±250 dps, BDU + IF_INC): */
.equ LSM6_CTRL1_XL_104HZ_2G,   0x40
.equ LSM6_CTRL2_G_104HZ_250DPS, 0x40
.equ LSM6_CTRL3_C_BDU_INC,     0x44

/* ±2 g → 0.061 mg per LSB. raw_int16 * 0.061 / 1000 = g,
 * then * 9.81 for m/s². Screen can show raw or g; convert in the app. */
