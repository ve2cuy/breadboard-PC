; ============================================================
; bridge_test.asm - banc d'essai de lib/bridge.asm (voir tests/bridge_test.py)
; Assemble avec: nasm -f bin tests/bridge_test.asm -o build/bridge_test.bin
; (depuis la racine de Solution-01). Utilise les VRAIES routines arduino_send /
; bridge_* / rtc_*; le 8255 (ports 80h-82h) et l'ISR (remplissage du tampon de
; reponses) sont emules par tests/bridge_test.py.
; Donnees (segment 1000h): 0200h = resultat de rtc_get (8 octets), 0210h = CF
; (octet), 0220h = 7 octets pour rtc_set.
; ============================================================
BITS    16
CPU     8086
ORG     0000h
%include "include/hardware.inc"

start:
        cli
        mov     ax, 1000h
        mov     ss, ax
        xor     sp, sp
        mov     ds, ax
        mov     es, ax
        cld
        mov     di, 0200h
        call    rtc_get
        mov     al, 0
        jnc     .ok
        mov     al, 1
.ok:
        mov     [0210h], al
        mov     si, 0220h
        call    rtc_set
        mov     al, 1
        out     0FFh, al
        hlt

%include "lib/bridge.asm"
