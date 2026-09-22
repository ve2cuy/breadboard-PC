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
NASMFLAGS   = -f bin

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

.PHONY: all rom lib check clean check-modules test map trace trace-nohd

# --- Cible par defaut: la ROM complete + les modules individuels ---
all: rom lib

# --- ROM complete, copiee vers Z:\Partage\Alain\rom.bin ---
rom: $(ROM_BIN)
	@mkdir -p "$(dir $(ROM_OUT))" 2>/dev/null || true
	cp $(ROM_BIN) "$(ROM_OUT)"
	@echo "ROM copiee vers $(ROM_OUT)"

$(ROM_BIN): solution-01.asm include/hardware.inc include/delay.inc include/lcd_macros.inc \
            lib/common.asm lib/lcd.asm lib/uart.asm lib/utils.asm lib/lcd_i2c.asm lib/ps2.asm lib/tiny_basic.asm lib/isr.asm lib/bios.asm $(BAS_SRC)
	$(NASM) $(NASMFLAGS) solution-01.asm -o $(ROM_BIN)

# --- ROM de diagnostic: chaque INT 13h / 1Ah est tracee sur l'UART (<nn AX BX CX DX ES -AH CF>); copiee en rom_trace.bin ---
trace: $(BAS_SRC) solution-01.asm lib/bios.asm
	$(NASM) $(NASMFLAGS) -dBIOS_TRACE=1 solution-01.asm -o solution-01-trace.bin
	cp solution-01-trace.bin "$(dir $(ROM_OUT))rom_trace.bin"
	@echo "ROM de trace copiee vers $(dir $(ROM_OUT))rom_trace.bin"

# --- idem + INT 13h refuse les disques DL >= 80h (le DOS ne voit pas la flash comme disque dur): rom_trace_nohd.bin ---
trace-nohd: $(BAS_SRC) solution-01.asm lib/bios.asm
	$(NASM) $(NASMFLAGS) -dBIOS_TRACE=1 -dBIOS_HIDE_HD=1 solution-01.asm -o solution-01-trace-nohd.bin
	cp solution-01-trace-nohd.bin "$(dir $(ROM_OUT))rom_trace_nohd.bin"
	@echo "ROM trace sans disque dur copiee vers $(dir $(ROM_OUT))rom_trace_nohd.bin"

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
	$(NASM) $(NASMFLAGS) lib/bridge.asm  -o $(CHECK_DIR)/_check_bridge.bin
	@echo "Tous les modules s'assemblent individuellement - OK"

$(CHECK_DIR):
	mkdir -p $(CHECK_DIR)

# --- Verification structurelle de la ROM assemblee (taille, vecteur
# de reset, signature) - voir check_rom.py ---
check: $(ROM_BIN)
	python3 check_rom.py $(ROM_BIN)

# --- Plan (MAP) de la ROM: zones, tailles, espace libre - voir rom_map.py ---
map:
	python3 rom_map.py

# --- Bancs d'essai sous emulateur (Unicorn - pip install unicorn numpy): Tiny BASIC,
# --- bibliotheque flottante et BASIC (assez long: ~2 minutes) ---
test:
	python3 tests/tb_test.py
	python3 tests/fl_test.py
	python3 tests/bridge_test.py
	python3 tests/bios_test.py
	python3 tests/basic_test.py

clean:
	rm -f $(ROM_BIN) $(LCD_BIN) $(UART_BIN) $(UTILS_BIN) $(LCD_I2C_BIN) $(PS2_BIN) $(TB_BIN) $(BAS_BIN)
	rm -rf $(CHECK_DIR)
