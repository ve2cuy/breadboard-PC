# Solution-02 - BIOS (nasm dans le PATH)
NASM  ?= nasm
IMAGE  = build/solution-02-bios.bin
# calibration de l'UART logiciel : make UART_N=28 (voir README) ; refaire "make clean" avant
NASM_DEF = $(if $(UART_N),-DUART_N=$(UART_N))

all: $(IMAGE)

$(IMAGE): bios.asm clavier_us.inc accueil.inc services.inc ../../PC-DOS/pcdos2_1.img
	@mkdir -p build
	$(NASM) -f bin $(NASM_DEF) -l build/bios.lst -o $@ bios.asm
	@python -c "import os,sys; n=os.path.getsize('$@'); print('$@', n, 'octets'); sys.exit(n != 262144)"

# ROM de diagnostic du 8255 : ecritures en rafale continue en 10h-13h (CS#/WR# visibles)
DIAG = build/solution-02-diag-8255.bin
diag: $(DIAG)
$(DIAG): bios.asm clavier_us.inc accueil.inc services.inc
	@mkdir -p build
	$(NASM) -f bin $(NASM_DEF) -DDIAG_8255 -l build/diag-8255.lst -o $@ bios.asm
	@python -c "import os,sys; n=os.path.getsize('$@'); print('$@', n, 'octets'); sys.exit(n != 262144)"

# ROM de diagnostic du 2e 8255 (U12) : PC et PA clignotent, PB et trames PS/2 au LCD
DIAG2 = build/solution-02-diag-u12.bin
diag2: $(DIAG2)
$(DIAG2): bios.asm clavier_us.inc accueil.inc services.inc
	@mkdir -p build
	$(NASM) -f bin $(NASM_DEF) -DDIAG_U12 -l build/diag-u12.lst -o $@ bios.asm
	@python -c "import os,sys; n=os.path.getsize('$@'); print('$@', n, 'octets'); sys.exit(n != 262144)"

test: $(IMAGE)
	python tests/sim.py $(IMAGE)

clean:
	rm -rf build

.PHONY: all test clean flash diag diag2

# Graver la ROM (TL866CS + minipro sous WSL, comme Solution-01). Inserer la puce d'abord.
FLASH_CHIP ?= W29C020C
USBIPD     ?= C:/Program Files/usbipd-win/usbipd.exe
USB_BUSID  ?= 1-2
MINIPRO_DIR ?= ~/minipro
MINIPRO     = MINIPRO_HOME=$(MINIPRO_DIR) $(MINIPRO_DIR)/minipro

# image a graver : la ROM normale, ou un diagnostic (make flash PUCE=ok GRAVER=diag|diag2)
ifeq ($(GRAVER),diag)
FLASH_IMAGE = $(DIAG)
else ifeq ($(GRAVER),diag2)
FLASH_IMAGE = $(DIAG2)
else
FLASH_IMAGE = $(IMAGE)
endif

flash: $(FLASH_IMAGE)
ifneq ($(PUCE),ok)
	@echo "Inserer la puce $(FLASH_CHIP) dans le support ZIF du TL866CS, puis: make flash PUCE=ok [FLASH_CHIP=...]"
	@exit 1
else
	-@wsl -e true
	-@wsl -e bash -c "lsusb | grep -q 04d8:e11c" || { "$(USBIPD)" detach --busid $(USB_BUSID) >/dev/null 2>&1; 	  for i in 1 2 3 4 5 6 7 8 9 10; do "$(USBIPD)" attach --wsl --busid $(USB_BUSID) >/dev/null 2>&1 && break; sleep 1; done; }
	@wsl -e bash -c "for i in 1 2 3 4 5 6 7 8 9 10; do lsusb | grep -q 04d8:e11c && exit 0; sleep 1; done; echo 'TL866CS absent de WSL (usbipd list / bind --busid $(USB_BUSID))'; exit 1"
	wsl --cd "$(CURDIR)" -e bash -lc "$(MINIPRO) -p $(FLASH_CHIP) -u -w $(FLASH_IMAGE)"
	@echo "ROM $(FLASH_IMAGE) gravee et verifiee sur la $(FLASH_CHIP)"
endif
