# breadboard-PC — consignes pour Claude

## Structure
- Solution-01/ : ROM du 8088 (NASM, Makefile). Journal : Solution-01/Directives.md
- arduino/8088_bridge_stm32/ : firmware du pont STM32 Black Pill (PlatformIO)
- PC-DOS/ : images disque de test

## Vérifications obligatoires après modification de la ROM
Depuis Solution-01 : make all, make check, make check-modules,
build TEST_PS2, make test, puis make test-rom (≈2 min).
Reproduire tout nouveau symptôme avec tests/rom_sim.py AVANT de modifier le code.

## Livraison
- Copier chaque ROM 8088 produite dans Z:/Partage/Alain/ (noms explicites).
- JAMAIS de firmware du pont dans Z:/Partage/Alain : tout ce qui s'y trouve
  est gravé dans l'EEPROM du 8088.
- Flasher le pont (carte en DFU) :
  platformio run -e blackpill_f411ce_usbdrive -t upload

## Git
- Ajouter chaque étape à la fin de Solution-01/Directives.md.
- Commit en français ; ne pousser que sur demande.
- Releases : wsl gh ... (avec MSYS_NO_PATHCONV=1 depuis Git Bash).

## Matériel à retenir
- 8255 en mode 2 ; 8259 en front, EOI manuel ; IR1 masquée pendant les
  commandes au pont (réponses lues par scrutation — ne pas revenir aux IRQ).
- RESET du 8088 piloté par PB2 du STM32 (Ctrl-Alt-Suppr / Ctrl-\).
- Octets libres de VAR_SEG déjà pris : 0FC54h–0FC56h.
