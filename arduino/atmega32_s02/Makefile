# Solution-02 - micrologiciel de l'ATmega32-16PU.
#   make            : construit .pio/build/atmega32/firmware.hex (PlatformIO)
#   make fusibles   : lit les fusibles de la puce (TL866CS)
#   make flash PUCE=ok : grave le micrologiciel PUIS les fusibles (quartz 16 MHz)
# Le micrologiciel ne va JAMAIS dans Z:/Partage/Alain (reserve aux ROM du 8088).

PIO        ?= $(USERPROFILE)/.platformio/penv/Scripts/pio.exe
HEX         = .pio/build/atmega32/firmware.hex
PUCE_AVR    = ATMEGA32
USBIPD     ?= C:/Program Files/usbipd-win/usbipd.exe
USB_BUSID  ?= 1-2
MINIPRO_DIR ?= ~/minipro
MINIPRO     = MINIPRO_HOME=$(MINIPRO_DIR) $(MINIPRO_DIR)/minipro

.PHONY: all fusibles flash tl866

all:
	"$(PIO)" run


tl866:
	-@wsl -e true
	-@wsl -e bash -c "lsusb | grep -q 04d8:e11c" || { "$(USBIPD)" detach --busid $(USB_BUSID) >/dev/null 2>&1; 	  for i in 1 2 3 4 5 6 7 8 9 10; do "$(USBIPD)" attach --wsl --busid $(USB_BUSID) >/dev/null 2>&1 && break; sleep 1; done; }
	@wsl -e bash -c "for i in 1 2 3 4 5 6 7 8 9 10; do lsusb | grep -q 04d8:e11c && exit 0; sleep 1; done; echo 'TL866CS absent de WSL'; exit 1"

fusibles: tl866
	wsl --cd "$(CURDIR)" -e bash -lc "$(MINIPRO) -p $(PUCE_AVR) -c config -r fusibles_lus.txt && cat fusibles_lus.txt"

flash: all
ifneq ($(PUCE),ok)
	@echo "Inserer l'ATmega32 dans le support ZIF du TL866CS, puis: make flash PUCE=ok"
	@exit 1
else
	"$(MAKE)" tl866
	wsl --cd "$(CURDIR)" -e bash -lc "$(MINIPRO) -p $(PUCE_AVR) -c code -w $(HEX)"
	wsl --cd "$(CURDIR)" -e bash -lc "$(MINIPRO) -p $(PUCE_AVR) -c config -w fusibles.txt"
	@echo "ATmega32 grave (micrologiciel + fusibles lfuse BFh, hfuse CFh)"
endif
