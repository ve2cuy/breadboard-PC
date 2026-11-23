# Solution-02 - micrologiciel de l'ATmega328P (U17).
#   make            : construit .pio/build/atmega328p/firmware.hex (PlatformIO)
#   make test       : essais du protocole sur le PC (gcc de WSL)
#   make banc       : micrologiciel complet sous simavr (UART logiciel, USART, SPI), au cycle pres
#   make fusibles   : lit les fusibles de la puce (TL866CS)
#   make flash PUCE=ok : grave le micrologiciel PUIS les fusibles (quartz 16 MHz)
# Le micrologiciel ne va JAMAIS dans Z:/Partage/Alain (reserve aux ROM du 8088).

PIO        ?= $(USERPROFILE)/.platformio/penv/Scripts/pio.exe
HEX         = .pio/build/atmega328p/firmware.hex
PUCE_AVR    = ATMEGA328P
USBIPD     ?= C:/Program Files/usbipd-win/usbipd.exe
USB_BUSID  ?= 1-2
MINIPRO_DIR ?= ~/minipro
MINIPRO     = MINIPRO_HOME=$(MINIPRO_DIR) $(MINIPRO_DIR)/minipro

.PHONY: all test banc fusibles flash tl866

all:
	"$(PIO)" run

# essais du protocole (src/protocole.c) sur le PC, avec le gcc de WSL
test:
	wsl --cd "$(CURDIR)" -e bash -lc "gcc -std=c99 -Wall -Wextra -O2 -o /tmp/test_protocole test/test_protocole.c src/protocole.c && /tmp/test_protocole"

# simavr extrait sans sudo, dans WSL :
#   mkdir ~/simavr-deb && cd ~/simavr-deb && apt-get download simavr libsimavr2 libsimavr-dev
#   libsimavrparts1 && for f in *.deb; do dpkg -x $f root; done
# BANC_VITESSES : codes du terminal (4 = 115200, 3 = 57600, 0 = 9600) ; BANC_US : us par octet SPI
# (le 8088 en met ~109 : SPI bit par bit)
SIMAVR ?= \$$HOME/simavr-deb/root/usr
BANC_VITESSES ?= 4 3 0
BANC_OCTETS ?= 300
BANC_US ?= 100
banc: all
	wsl --cd "$(CURDIR)" -e bash -lc "gcc -O2 -Wall -I$(SIMAVR)/include/simavr -I$(SIMAVR)/include/simavr/avr -o /tmp/banc_simavr test/banc_simavr.c -L$(SIMAVR)/lib/x86_64-linux-gnu -lsimavr"
	for v in $(BANC_VITESSES); do wsl --cd "$(CURDIR)" -e bash -lc "LD_LIBRARY_PATH=$(SIMAVR)/lib/x86_64-linux-gnu /tmp/banc_simavr .pio/build/atmega328p/firmware.elf $$v $(BANC_OCTETS) $(BANC_US)" || exit 1; done

tl866:
	-@wsl -e true
	-@wsl -e bash -c "lsusb | grep -q 04d8:e11c" || { "$(USBIPD)" detach --busid $(USB_BUSID) >/dev/null 2>&1; 	  for i in 1 2 3 4 5 6 7 8 9 10; do "$(USBIPD)" attach --wsl --busid $(USB_BUSID) >/dev/null 2>&1 && break; sleep 1; done; }
	@wsl -e bash -c "for i in 1 2 3 4 5 6 7 8 9 10; do lsusb | grep -q 04d8:e11c && exit 0; sleep 1; done; echo 'TL866CS absent de WSL'; exit 1"

fusibles: tl866
	wsl --cd "$(CURDIR)" -e bash -lc "$(MINIPRO) -p $(PUCE_AVR) -c config -r fusibles_lus.txt && cat fusibles_lus.txt"

flash: all
ifneq ($(PUCE),ok)
	@echo "Inserer l'ATmega328P dans le support ZIF du TL866CS, puis: make flash PUCE=ok"
	@exit 1
else
	"$(MAKE)" tl866
	wsl --cd "$(CURDIR)" -e bash -lc "$(MINIPRO) -p $(PUCE_AVR) -c code -w $(HEX)"
	wsl --cd "$(CURDIR)" -e bash -lc "$(MINIPRO) -p $(PUCE_AVR) -c config -w fusibles.txt"
	@echo "ATmega328P grave (micrologiciel + fusibles lfuse FFh, hfuse D9h, efuse FDh)"
endif
