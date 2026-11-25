# Anvil-Core software build: C/asm -> ELF (newlib-nano) -> word hex for the RAM.
#
# Run from WSL inside Software/:   make          build and write the hex image
#                                   make dump     disassemble the ELF
#                                   make clean
#
# The ISA and the memory map are read from Core/Package/Parameters.sv, so the
# build follows the hardware configuration:
#   -march      rv32i + m (SUPPORT_MUL && SUPPORT_DIV) + c, plus zicsr/zifencei
#   RAM_BASE / MAX_MEMORY_ADDRESS
#       passed to the linker as the symbols __ram_base / __ram_end
#       and to C as the macros RAM_BASE / RAM_END
#
# The image is written to Core/Frontend/Fetch/program.hex (word 0 = RAM_BASE),
# which SystemTop and the debugger load at start-up.

ROOT       := ..
PARAMETERS := $(ROOT)/Core/Package/Parameters.sv
HEX_OUT    := $(ROOT)/Core/Frontend/Fetch/program.hex

# newlib-nano toolchain (rv32i/ilp32 libraries).
PREFIX     ?= $(HOME)/riscv-toolchain/bin/riscv32-unknown-elf-
CC         := $(PREFIX)gcc
OBJCOPY    := $(PREFIX)objcopy
OBJDUMP    := $(PREFIX)objdump
SIZE       := $(PREFIX)size

# --- Hardware parameters -----------------------------------------------------
# param: a parameter's value, with Verilog sized-hex literals (32'h0000_0200)
# converted to C hex (0x00000200).
param       = $(shell sed -n "s/.*parameter[^=]*\b$(1)[[:space:]]*=[[:space:]]*\([^;]*\);.*/\1/p" $(PARAMETERS) \
                | head -n1 | sed -e "s/^[0-9]*'[hH]/0x/" -e "s/_//g")
SUPPORT_MUL := $(call param,SUPPORT_MUL)
SUPPORT_DIV := $(call param,SUPPORT_DIV)
RAM_BASE    := $(call param,RAM_BASE)
RAM_LIMIT   := $(call param,MAX_MEMORY_ADDRESS)
RAM_END     := $(shell printf '0x%x' $$(( $(RAM_LIMIT) + 1 )))

MARCH := rv32i$(if $(filter 1,$(SUPPORT_MUL)),$(if $(filter 1,$(SUPPORT_DIV)),m))c_zicsr_zifencei
MABI  := ilp32

# --- Sources -------------------------------------------------------------------
TARGET  := program
SOURCES := crt0.S main.c syscalls.c
BUILD   := build
OBJECTS := $(addprefix $(BUILD)/,$(addsuffix .o,$(basename $(SOURCES))))

# --param=min-pagesize=0: the devices live at 0x000-0x10F. GCC 12+ otherwise
# treats any pointer below 4 KiB as a null dereference (-Warray-bounds).
CFLAGS  := -march=$(MARCH) -mabi=$(MABI) -O2 -g -Wall -Wextra \
           -ffunction-sections -fdata-sections --param=min-pagesize=0 \
           -DRAM_BASE=$(RAM_BASE) -DRAM_END=$(RAM_END)
LDFLAGS := -march=$(MARCH) -mabi=$(MABI) -nostartfiles --specs=nano.specs \
           -T linker.ld -Wl,--gc-sections -Wl,-Map=$(BUILD)/$(TARGET).map \
           -Wl,--defsym,__ram_base=$(RAM_BASE) -Wl,--defsym,__ram_end=$(RAM_END)
LDLIBS  := -lc_nano -lgcc

.PHONY: all dump clean
all: $(HEX_OUT)

$(BUILD):
	mkdir -p $@

$(BUILD)/%.o: %.c platform.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: %.S platform.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/$(TARGET).elf: $(OBJECTS) linker.ld
	$(CC) $(LDFLAGS) $(OBJECTS) $(LDLIBS) -o $@
	$(SIZE) $@

# Flat binary from the lowest load address (must be RAM_BASE), then one
# little-endian 32-bit word per line.
$(HEX_OUT): $(BUILD)/$(TARGET).elf
	$(OBJCOPY) -O binary $< $(BUILD)/$(TARGET).bin
	od -An -tx4 -v -w4 $(BUILD)/$(TARGET).bin | tr -d ' ' > $@
	@echo "wrote $@ ($(MARCH), RAM $(RAM_BASE)..$(RAM_LIMIT))"

dump: $(BUILD)/$(TARGET).elf
	$(OBJDUMP) -d -S $<

clean:
	rm -rf $(BUILD)
