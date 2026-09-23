; ============================================================
; basic_test.asm - banc d'essai de lib/basic.asm (voir tests/basic_test.py)
; Assemble avec: nasm -f bin -dBASIC_TEST tests/tb_test.asm -o build/basic_test.bin
; (depuis la racine de Solution-01). Les E/S UART sont REMPLACEES par des
; instructions IN/OUT vers des ports fictifs, interceptees par l'emulateur:
;   OUT E0h = octet emis par le firmware     IN E1h = 0/1 octet disponible
;   IN  E2h = octet recu                     OUT FFh = fin du test
; ============================================================
BITS    16
CPU     8086
ORG     0000h
%define BASIC_TEST
%include "include/hardware.inc"

start:
        cli
        mov     ax, 1000h
        mov     ss, ax
        xor     sp, sp                  ; comme le firmware: SS=1000h, SP=0000h
        mov     ax, cs
        mov     ds, ax                  ; DS = CS en permanence (comme le firmware)
        mov     ax, 1111h
        mov     bx, 2222h
        mov     cx, 3333h
        mov     dx, 4444h
        mov     si, 5555h
        mov     di, 6666h
        mov     bp, 7777h
        call    basic_run
        ; --- retour au "menu": publie les registres pour verification ---
        mov     [cs:saved_ax], ax
        mov     [cs:saved_bx], bx
        mov     [cs:saved_cx], cx
        mov     [cs:saved_dx], dx
        mov     [cs:saved_si], si
        mov     [cs:saved_di], di
        mov     [cs:saved_bp], bp
        mov     ax, ds
        mov     [cs:saved_ds], ax
        mov     ax, es
        mov     [cs:saved_es], ax
        mov     ax, sp
        mov     [cs:saved_sp], ax
        mov     al, 1
        out     0FFh, al
        hlt

saved_ax        dw 0
saved_bx        dw 0
saved_cx        dw 0
saved_dx        dw 0
saved_si        dw 0
saved_di        dw 0
saved_bp        dw 0
saved_ds        dw 0
saved_es        dw 0
saved_sp        dw 0

%ifdef BASIC_REAL
; --- variante "reelle": les VRAIES routines uart_* (lib/uart.asm -> arduino_send,
; --- tampon circulaire en RAM) - seuls le 8255 (ports 80h-82h) et le remplissage
; --- du tampon de reception par l'ISR sont emules par tests/tb_test.py
%include "lib/uart.asm"
%else
uart_tx_byte:
        out     0E0h, al
        ret

uart_rx_available:
        in      al, 0E1h
        cmp     al, 1                   ; AL=1 (octet dispo) -> CF=0
        ret

uart_rx_byte:
        in      al, 0E2h
        ret
%endif

; les VRAIES routines du pont (arduino_send, rtc_*, fs_*): le 8255 et le pont sont
; emules par tests/basic_harness.py (BridgeModel)
%define BRIDGE_NO_ISR                   ; pas de lib/isr.asm ici: pas de scrutation du 8255
%include "lib/bridge.asm"

%include "lib/basic.asm"
