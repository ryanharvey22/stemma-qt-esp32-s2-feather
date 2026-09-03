# Bare-metal ESP32-S2 (Xtensa asm, no Python, no IDF).
#
#   make              build blink.elf / blink.bin / blink.uf2
#   make uf2          same; copy blink.uf2 onto FTHRS2BOOT
#
# TinyUF2: slow double-tap RESET, drop build/blink.uf2 on FTHRS2BOOT.
# Board: Adafruit ESP32-S2 TFT Feather (ST7789 240x135). LED blink is GPIO 13.
# If UF2 is gone, flash build/blink.bin at 0x1000 with a non-Python flasher
# (e.g. espflash). That overwrites the 2nd-stage bootloader.

XT_ROOT ?= $(HOME)/.local/xtensa-esp-elf/xtensa-esp-elf
XT      := $(XT_ROOT)/bin/xtensa-esp32s2-elf-gcc
OBJDUMP := $(XT_ROOT)/bin/xtensa-esp32s2-elf-objdump
SIZE    := $(XT_ROOT)/bin/xtensa-esp32s2-elf-size
HOSTCC  ?= gcc

BUILD   := build
# TinyUF2 treats this as an offset into ota_0, not an absolute flash address.
UF2_BASE ?= 0x0

ASFLAGS := -mabi=call0 -mtext-section-literals -mlongcalls -ffreestanding
LDFLAGS := -mabi=call0 -nostdlib -Wl,-T,hw/esp32s2.ld -Wl,--gc-sections -Wl,-e,_start

.PHONY: all uf2 clean dump toolchain-check

all: toolchain-check $(BUILD)/blink.uf2

uf2: all

toolchain-check:
	@test -x "$(XT)" || { \
	  echo "missing $(XT)"; \
	  echo "install: see Makefile header / ~/.local/xtensa-esp-elf"; \
	  exit 1; }

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/elf2espimg: tools/elf2espimg.c | $(BUILD)
	$(HOSTCC) -O2 -o $@ $<

$(BUILD)/bin2uf2: tools/bin2uf2.c | $(BUILD)
	$(HOSTCC) -O2 -o $@ $<

$(BUILD)/blink.elf: hw/start.S hw/esp32s2.ld | $(BUILD)
	$(XT) $(ASFLAGS) $(LDFLAGS) -o $@ hw/start.S
	$(SIZE) $@

$(BUILD)/blink.bin: $(BUILD)/blink.elf $(BUILD)/elf2espimg
	$(BUILD)/elf2espimg $< $@

$(BUILD)/blink.uf2: $(BUILD)/blink.bin $(BUILD)/bin2uf2
	$(BUILD)/bin2uf2 $< $@ $(UF2_BASE)

dump: $(BUILD)/blink.elf
	$(OBJDUMP) -d $<

clean:
	rm -rf $(BUILD)
