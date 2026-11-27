# ============================================================
# Makefile - projet solution-01 (VE2CUY, 8088/8086 breadboard)
#
# HYPOTHESE (a corriger si necessaire): ce Makefile suppose GNU Make
# + un shell POSIX (cp, mkdir -p, rm -f) disponibles - le cas typique
# sous WSL, Git Bash ou MSYS2 sur Windows. Si tu utilises plutot
# nmake (Visual Studio) ou le make.exe minimaliste de MinGW sans
# coreutils, dis-le moi et j'adapte les regles ci-dessous (copy /
# mkdir / del au lieu de cp / mkdir -p / rm -f).
#
# nasm doit etre dans le PATH. Toutes les regles supposent que make
# est lance depuis LA RACINE de ce dossier (Solution-01/), jamais
# depuis un sous-dossier - c'est aussi la regle suivie par tous les
# %include du projet (voir include/hardware.inc).
# ============================================================

NASM        = nasm
# RAM du montage: 512 Ko (AS6C4008) par defaut -> -dRAM_512K pour TOUTES les ROM (rom, rom-fr, rom-en,
# trace, rom-pause...); "make ... RAM=128" (ou rom-128 / rom-128-en) pour l'ancienne HM628128 de 128 Ko.
RAM        ?= 512
ifeq ($(RAM),512)
RAMFLAGS    = -dRAM_512K
endif
NASMFLAGS   = -f bin $(RAMFLAGS)

ROM_BIN     = solution-01.bin
ROM_OUT     = Z:/Partage/Alain/rom.bin

LCD_BIN     = lib/bin/lcd.bin
UART_BIN    = lib/bin/uart.bin
UTILS_BIN   = lib/utils.bin
LCD_I2C_BIN = lib/bin/lcd_i2c.bin
PS2_BIN     = lib/bin/ps2.bin
TB_BIN      = lib/bin/tiny_basic.bin
BAS_BIN     = lib/bin/basic.bin
BAS_SRC     = lib/basic.asm lib/basic_tokens.inc lib/basic_float.asm lib/basic_fmath.asm \
              lib/basic_eval.asm lib/basic_str.asm lib/basic_stmt.asm lib/basic_func.asm lib/basic_data.asm lib/bridge.asm

# Dossier de sortie pour les .bin jetables de check-modules. On evite /tmp:
# quand ce Makefile est lance par un make natif Windows (ex. WinAVR) qui
# invoke sh.exe (Git/MSYS) comme SHELL, la traduction du chemin POSIX /tmp
# n'est pas fiable (l'environnement MSYS n'est pas toujours initialise
# comme lors d'un lancement direct du shell) et nasm echoue a l'ouverture
# du fichier de sortie. Un dossier local du projet n'a pas ce probleme.
CHECK_DIR   = build/check

# PC-DOS 2.1 de la ROM (lecteur A:, ROM 1.4): secteurs utilises de la disquette faite par tests/gen_dos21_rom.py
# (IBMBIO, IBMDOS, COMMAND, EDLIN de PC-DOS 2.1, MASM 1.00, LINK 1.08, HELLO.ASM, AUTOEXEC.BAT), inclus par
# solution-01.asm en D800:0000. Ecrit aussi ../PC-DOS/pcdos2_1_s01.img (la disquette complete de 180 Ko).
DOS_IMG     = build/dos21_rom.bin
$(DOS_IMG): tests/gen_dos21_rom.py ../PC-DOS/pcdos2_1.img ../PC-DOS/MASM/MASM1.EXE ../PC-DOS/MASM/LINK1.EXE
	python3 tests/gen_dos21_rom.py

.PHONY: all rom rom-fr rom-en rom-128 rom-128-en rom-pause ramtest test-ramtest lib check clean check-modules test test-rom test-rom-complet map trace trace-nohd

# --- Cible par defaut: la ROM complete + les modules individuels ---
all: rom lib

# --- ROM complete, copiee vers Z:\Partage\Alain\rom.bin ---
rom: $(ROM_BIN)
	@mkdir -p "$(dir $(ROM_OUT))" 2>/dev/null || true
	cp $(ROM_BIN) "$(ROM_OUT)"
	@echo "ROM copiee vers $(ROM_OUT)"

$(ROM_BIN): $(DOS_IMG) Makefile solution-01.asm include/hardware.inc include/delay.inc include/lcd_macros.inc \
            lib/common.asm lib/lcd.asm lib/uart.asm lib/utils.asm lib/lcd_i2c.asm lib/ps2.asm lib/tiny_basic.asm lib/isr.asm lib/bios.asm $(BAS_SRC)
	$(NASM) $(NASMFLAGS) solution-01.asm -o $(ROM_BIN)

# --- ROM bilingue (Manifest.md): textes UART/LCD du moniteur et du
# --- BIOS partage (voir lib/bios.asm) en francais (rom-fr, PAR
# --- DEFAUT - identique a "rom" ci-dessus) ou en anglais (rom-en,
# --- -dLANG_EN=1). "-w-error=label-redef-late" pour rom-en seulement:
# --- la taille legerement differente des textes anglais retarde la
# --- convergence normale de nasm (plusieurs passes) sur certains sauts
# --- eloignes dans ce gros fichier - inoffensif (2 compilations
# --- successives produisent un binaire IDENTIQUE, verifie), juste plus
# --- lent a converger; "rom"/"rom-fr" n'en ont jamais eu besoin.
rom-fr: $(BAS_SRC) solution-01.asm lib/bios.asm $(DOS_IMG)
	$(NASM) $(NASMFLAGS) solution-01.asm -o solution-01-fr.bin
	cp solution-01-fr.bin "$(dir $(ROM_OUT))solution-01-fr.bin"
	@echo "ROM (francais): solution-01-fr.bin, copiee vers $(dir $(ROM_OUT))"

rom-en: $(BAS_SRC) solution-01.asm lib/bios.asm $(DOS_IMG)
	$(NASM) $(NASMFLAGS) -dLANG_EN=1 -w-error=label-redef-late solution-01.asm -o solution-01-en.bin
	cp solution-01-en.bin "$(dir $(ROM_OUT))solution-01-en.bin"
	@echo "ROM (anglais): solution-01-en.bin, copiee vers $(dir $(ROM_OUT))"

# --- ancienne RAM de 128 Ko (HM628128): sans -dRAM_512K - identique a la ROM 1.2 ---
rom-128: $(BAS_SRC) solution-01.asm lib/bios.asm $(DOS_IMG)
	$(NASM) -f bin solution-01.asm -o solution-01-128k.bin
	cp solution-01-128k.bin "$(dir $(ROM_OUT))solution-01-128k.bin"
	@echo "ROM 128 Ko (francais): solution-01-128k.bin, copiee vers $(dir $(ROM_OUT))"

rom-128-en: $(BAS_SRC) solution-01.asm lib/bios.asm $(DOS_IMG)
	$(NASM) -f bin -dLANG_EN=1 -w-error=label-redef-late solution-01.asm -o solution-01-128k-en.bin
	cp solution-01-128k-en.bin "$(dir $(ROM_OUT))solution-01-128k-en.bin"
	@echo "ROM 128 Ko (anglais): solution-01-128k-en.bin, copiee vers $(dir $(ROM_OUT))"

# --- ROM de TEST de la RAM de 128 Ko SANS RAM (ni pile ni variable): ramtest-128k.asm. Diagnostic du bus
# --- de donnees, des lignes A0-A16 et des 16 blocs de 8 Ko sur le LCD, en boucle. Pour une RAM morte ou
# --- douteuse (HM628128, JP2 2-3) que le BIOS ne pourrait pas tester. Banc d'essai: make test-ramtest. ---
RAMTEST_BIN = solution-01-ramtest-128k.bin
ramtest: ramtest-128k.asm include/hardware.inc
	$(NASM) -f bin ramtest-128k.asm -o $(RAMTEST_BIN)
	cp $(RAMTEST_BIN) "$(dir $(ROM_OUT))$(RAMTEST_BIN)"
	@echo "ROM de test RAM 128 Ko: $(RAMTEST_BIN), copiee vers $(dir $(ROM_OUT))"

test-ramtest: ramtest-128k.asm include/hardware.inc tests/ramtest_sim.py
	python tests/ramtest_sim.py

# --- ROM d'ESSAI: pause (~5 ms) apres chaque ecriture de secteur (BRIDGE_WRITE_PAUSE, lib/bridge.asm) ---
rom-pause: $(BAS_SRC) solution-01.asm lib/bios.asm $(DOS_IMG)
	$(NASM) $(NASMFLAGS) -dBRIDGE_WRITE_PAUSE=1400 solution-01.asm -o solution-01-pause.bin
	cp solution-01-pause.bin "$(dir $(ROM_OUT))solution-01-pause.bin"
	@echo "ROM d'essai (pause apres ecriture): solution-01-pause.bin, copiee vers $(dir $(ROM_OUT))"

# --- ROM de diagnostic: chaque INT 13h / 1Ah est tracee sur l'UART (<nn AX BX CX DX ES -AH CF>); copiee en solution-01-trace.bin ---
trace: $(BAS_SRC) solution-01.asm lib/bios.asm $(DOS_IMG)
	$(NASM) $(NASMFLAGS) -dBIOS_TRACE=1 solution-01.asm -o solution-01-trace.bin
	cp solution-01-trace.bin "$(dir $(ROM_OUT))solution-01-trace.bin"
	@echo "ROM de trace copiee vers $(dir $(ROM_OUT))solution-01-trace.bin"

# --- idem + INT 13h refuse les disques DL >= 80h (le DOS ne voit pas la flash comme disque dur): solution-01-trace-nohd.bin ---
trace-nohd: $(BAS_SRC) solution-01.asm lib/bios.asm $(DOS_IMG)
	$(NASM) $(NASMFLAGS) -dBIOS_TRACE=1 -dBIOS_HIDE_HD=1 solution-01.asm -o solution-01-trace-nohd.bin
	cp solution-01-trace-nohd.bin "$(dir $(ROM_OUT))solution-01-trace-nohd.bin"
	@echo "ROM trace sans disque dur copiee vers $(dir $(ROM_OUT))solution-01-trace-nohd.bin"

# --- GRAVURE de la ROM (programmeur TL866CS, minipro compile sous WSL dans ~/minipro,
# --- programmeur passe a WSL par usbipd-win - voir README.md, section "Graver la ROM").
# ---   make flash PUCE=ok                    ROM francaise sur une W29C020C (rom-fr: compilee et copiee vers Z:)
# ---   make flash FLASH_LANG=en PUCE=ok      ROM anglaise
# ---   make flash FLASH_PUCE=pm29 PUCE=ok    sur une Pm29F002T (meme taille, 256 Ko, DIP32)
# ---   make flash FLASH_ROM=ramtest PUCE=ok  la ROM de test de la RAM de 128 Ko sans RAM (ramtest-128k.asm)
# --- Sans PUCE=ok, rien n'est grave: la cible rappelle d'inserer la puce dans le support ZIF du
# --- programmeur. minipro verifie d'abord l'ID de la puce (une autre puce que celle choisie est refusee),
# --- efface, ecrit puis VERIFIE toute la puce (echec = code de sortie non nul).
# --- Le programmeur doit etre branche DIRECTEMENT au PC (pas de hub USB: pages non ecrites).
FLASH_LANG ?= fr
# ROM a graver: FLASH_ROM=bios (defaut: le BIOS, langue FLASH_LANG) ou FLASH_ROM=ramtest (test RAM 128 Ko sans RAM)
FLASH_ROM  ?= bios
ifeq ($(FLASH_ROM),ramtest)
FLASH_BIN   = $(RAMTEST_BIN)
FLASH_DEP   = ramtest
else
FLASH_BIN   = solution-01-$(FLASH_LANG).bin
FLASH_DEP   = rom-$(FLASH_LANG)
endif
# Puce: nom court -> nom minipro + options d'ecriture (validees sur le TL866CS, 2026-11-25).
#   w29  = Winbond W29C020C (ID DA45h), -u: retire la protection logicielle avant d'ecrire
#   pm29 = PMC Pm29F002T (ID 9D1Dh), sans -u. Pm29F002T "neuves" a 16 derniers Ko figes: defectueuses
#          (refusees a la verification), voir Directives.md
FLASH_PUCE ?= w29
FLASH_CHIP_w29   = W29C020C
FLASH_OPTS_w29   = -u
FLASH_CHIP_pm29  = PM29F002T@DIP32
FLASH_OPTS_pm29  =
FLASH_CHIP ?= $(FLASH_CHIP_$(FLASH_PUCE))
FLASH_OPTS ?= $(FLASH_OPTS_$(FLASH_PUCE))
USBIPD     ?= C:/Program Files/usbipd-win/usbipd.exe
USB_BUSID  ?= 1-2
MINIPRO_DIR ?= ~/minipro
# (infoic.xml/logicic.xml: lus dans MINIPRO_HOME, minipro n'etant pas installe)
MINIPRO     = MINIPRO_HOME=$(MINIPRO_DIR) $(MINIPRO_DIR)/minipro

.PHONY: flash
flash: $(FLASH_DEP)
ifeq ($(FLASH_CHIP),)
	@echo "FLASH_PUCE=$(FLASH_PUCE) inconnue: w29 (W29C020C, defaut) ou pm29 (Pm29F002T)"
	@exit 1
else ifneq ($(PUCE),ok)
	@echo "Inserer la puce $(FLASH_CHIP) dans le support ZIF du TL866CS, puis: make flash FLASH_ROM=$(FLASH_ROM) FLASH_LANG=$(FLASH_LANG) FLASH_PUCE=$(FLASH_PUCE) PUCE=ok"
	@exit 1
else
	@# WSL arrete sa machine virtuelle quand il est inactif: usbipd croit alors le programmeur encore
	@# attache. On le detache, puis on le rattache (il se re-enumere: quelques essais).
	-@wsl -e true
	-@wsl -e bash -c "lsusb | grep -q 04d8:e11c" || { "$(USBIPD)" detach --busid $(USB_BUSID) >/dev/null 2>&1; \
	  for i in 1 2 3 4 5 6 7 8 9 10; do "$(USBIPD)" attach --wsl --busid $(USB_BUSID) >/dev/null 2>&1 && break; sleep 1; done; }
	@wsl -e bash -c "for i in 1 2 3 4 5 6 7 8 9 10; do lsusb | grep -q 04d8:e11c && exit 0; sleep 1; done; echo 'TL866CS absent de WSL (usbipd list / bind --busid $(USB_BUSID))'; exit 1"
	wsl --cd "$(CURDIR)" -e bash -lc "$(MINIPRO) -p '$(FLASH_CHIP)' $(FLASH_OPTS) -w $(FLASH_BIN)"
	@echo "ROM $(FLASH_BIN) gravee et verifiee sur la $(FLASH_CHIP)"
endif

# --- Modules individuels (LCD, UART, delay_ms, LCD I2C, PS/2) ---
lib: $(LCD_BIN) $(UART_BIN) $(UTILS_BIN) $(LCD_I2C_BIN) $(PS2_BIN) $(TB_BIN) $(BAS_BIN)

$(LCD_BIN): lib/lcd.asm lib/common.asm include/hardware.inc | lib/bin
	$(NASM) $(NASMFLAGS) lib/lcd.asm -o $(LCD_BIN)

$(UART_BIN): lib/uart.asm lib/common.asm include/hardware.inc | lib/bin
	$(NASM) $(NASMFLAGS) lib/uart.asm -o $(UART_BIN)

$(UTILS_BIN): lib/utils.asm
	$(NASM) $(NASMFLAGS) lib/utils.asm -o $(UTILS_BIN)

$(LCD_I2C_BIN): lib/lcd_i2c.asm lib/lcd.asm lib/common.asm include/hardware.inc | lib/bin
	$(NASM) $(NASMFLAGS) lib/lcd_i2c.asm -o $(LCD_I2C_BIN)

$(PS2_BIN): lib/ps2.asm lib/lcd.asm lib/uart.asm lib/common.asm include/hardware.inc | lib/bin
	$(NASM) $(NASMFLAGS) lib/ps2.asm -o $(PS2_BIN)

$(TB_BIN): lib/tiny_basic.asm lib/uart.asm lib/common.asm include/hardware.inc | lib/bin
	$(NASM) $(NASMFLAGS) lib/tiny_basic.asm -o $(TB_BIN)

$(BAS_BIN): $(BAS_SRC) lib/uart.asm lib/common.asm include/hardware.inc | lib/bin
	$(NASM) $(NASMFLAGS) lib/basic.asm -o $(BAS_BIN)

lib/bin:
	mkdir -p lib/bin

# --- Verifie que chaque module (y compris common.asm, partage par
# lcd.asm/uart.asm) s'assemble seul sans erreur - sans produire de
# .bin livre, juste un test rapide de coherence des %include ---
check-modules: | $(CHECK_DIR)
	$(NASM) $(NASMFLAGS) lib/common.asm  -o $(CHECK_DIR)/_check_common.bin
	$(NASM) $(NASMFLAGS) lib/lcd.asm     -o $(CHECK_DIR)/_check_lcd.bin
	$(NASM) $(NASMFLAGS) lib/uart.asm    -o $(CHECK_DIR)/_check_uart.bin
	$(NASM) $(NASMFLAGS) lib/utils.asm   -o $(CHECK_DIR)/_check_utils.bin
	$(NASM) $(NASMFLAGS) lib/lcd_i2c.asm -o $(CHECK_DIR)/_check_lcd_i2c.bin
	$(NASM) $(NASMFLAGS) lib/ps2.asm     -o $(CHECK_DIR)/_check_ps2.bin
	$(NASM) $(NASMFLAGS) lib/tiny_basic.asm -o $(CHECK_DIR)/_check_tiny_basic.bin
	$(NASM) $(NASMFLAGS) lib/basic.asm   -o $(CHECK_DIR)/_check_basic.bin
	$(NASM) $(NASMFLAGS) -dBRIDGE_NO_ISR lib/bridge.asm  -o $(CHECK_DIR)/_check_bridge.bin   # seul: sans lib/isr.asm (irq1_dispatch)
	@echo "Tous les modules s'assemblent individuellement - OK"

$(CHECK_DIR):
	mkdir -p $(CHECK_DIR)

# --- Verification structurelle de la ROM assemblee (taille, vecteur
# de reset, signature) - voir check_rom.py ---
check: $(ROM_BIN)
	python3 check_rom.py $(ROM_BIN)

# --- Plan (MAP) de la ROM: zones, tailles, espace libre - voir rom_map.py ---
map: $(DOS_IMG)
	python3 rom_map.py

# --- Bancs d'essai sous emulateur (Unicorn - pip install unicorn numpy): Tiny BASIC,
# --- bibliotheque flottante et BASIC (assez long: ~2 minutes) ---
# --- scenarios de bout en bout avec IRQ1 ASYNCHRONES (tests/rom_sim.py): DOS 2.1/3.30 reels, trace,
# --- scrutation du pont (~ 2 min); test-rom-complet ajoute la ROM COMPLETE: menu, Ctrl-\, reamorcage
# --- de DOS, collage au BASIC (plusieurs minutes de plus). Hors de "test" (trop longs). ---
test-rom: $(DOS_IMG)
	python3 tests/rom_test.py

test-rom-complet: $(DOS_IMG)
	python3 tests/rom_test.py --complet

test:
	python3 tests/tb_test.py
	python3 tests/fl_test.py
	python3 tests/bridge_test.py
	python3 tests/bios_test.py
	python3 tests/basic_test.py

clean:
	rm -f $(ROM_BIN) $(LCD_BIN) $(UART_BIN) $(UTILS_BIN) $(LCD_I2C_BIN) $(PS2_BIN) $(TB_BIN) $(BAS_BIN)
	rm -rf $(CHECK_DIR)
