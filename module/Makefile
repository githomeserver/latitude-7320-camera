obj-m += intel_skl_int3472_tps68470.o
intel_skl_int3472_tps68470-y := tps68470.o tps68470_board_data.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
