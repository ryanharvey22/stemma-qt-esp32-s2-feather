### QEMU Simulation
This directory is for simulating the boards code using qemu.  Will set up a ST7789 driver which will push fake
gyro and acceleration readings over the same interface that the real hardware uses. We even may accept input to this driver
from an ouside source and interpolate a reading for the board/real code. This is known as injection.