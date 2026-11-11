# Solution-02 - BIOS (nasm dans le PATH)
NASM  ?= nasm
IMAGE  = build/solution-02-bios.bin

all: $(IMAGE)

$(IMAGE): bios.asm
	@mkdir -p build
	$(NASM) -f bin -l build/bios.lst -o $@ bios.asm
	@python -c "import os,sys; n=os.path.getsize('$@'); print('$@', n, 'octets'); sys.exit(n != 262144)"

test: $(IMAGE)
	python tests/sim.py $(IMAGE)

clean:
	rm -rf build

.PHONY: all test clean flash

# Graver la ROM (TL866CS + minipro sous WSL, comme Solution-01). Inserer la puce d'abord.
FLASH_CHIP ?= W29C020C
USBIPD     ?= C:/Program Files/usbipd-win/usbipd.exe
USB_BUSID  ?= 1-2
MINIPRO_DIR ?= ~/minipro
MINIPRO     = MINIPRO_HOME=$(MINIPRO_DIR) $(MINIPRO_DIR)/minipro

flash: $(IMAGE)
ifneq ($(PUCE),ok)
	@echo "Inserer la puce $(FLASH_CHIP) dans le support ZIF du TL866CS, puis: make flash PUCE=ok [FLASH_CHIP=...]"
	@exit 1
else
	-@wsl -e true
	-@wsl -e bash -c "lsusb | grep -q 04d8:e11c" || { "$(USBIPD)" detach --busid $(USB_BUSID) >/dev/null 2>&1; 	  for i in 1 2 3 4 5 6 7 8 9 10; do "$(USBIPD)" attach --wsl --busid $(USB_BUSID) >/dev/null 2>&1 && break; sleep 1; done; }
	@wsl -e bash -c "for i in 1 2 3 4 5 6 7 8 9 10; do lsusb | grep -q 04d8:e11c && exit 0; sleep 1; done; echo 'TL866CS absent de WSL (usbipd list / bind --busid $(USB_BUSID))'; exit 1"
	wsl --cd "$(CURDIR)" -e bash -lc "$(MINIPRO) -p $(FLASH_CHIP) -u -w $(IMAGE)"
	@echo "ROM $(IMAGE) gravee et verifiee sur la $(FLASH_CHIP)"
endif
