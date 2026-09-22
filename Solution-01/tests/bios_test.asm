; ============================================================
; bios_test.asm - banc d'essai de lib/bios.asm et lib/isr.asm (voir tests/bios_test.py)
; Assemble avec: nasm -f bin tests/bios_test.asm -o build/bios_test.bin
; (depuis la racine de Solution-01).
;
; INTERPRETE DE CAS. Le script Python ecrit une table de cas en 0C000h:4000h (entrees de 32 octets)
; et l'emulateur execute chaque cas comme le ferait un DOS: SS:SP, DS, ES, registres propres au cas
; (ici SS = 3000h, DS = 2000h... jamais VAR_SEG), puis INT n. Les registres et les indicateurs au
; retour sont ranges dans la table de resultats 0C000h:6000h (entrees de 32 octets).
;
;   entree  +0 INT n (octet)  +1 (libre)  +2 AX +4 BX +6 CX +8 DX +10 SI +12 DI +14 ES +16 DS
;           +18 BP +20 SS +22 SP  +24 PORTC (lu par IN 82h)  +25 PORTA (lu par IN 80h)
;           un octet 0FFh en +0 termine la table
;   resultat +0 AX +2 BX +4 CX +6 DX +8 SI +10 DI +12 ES +14 DS +16 BP +18 SS +20 SP +22 FLAGS
; Ports fictifs: OUT 0FFh = fin du test.
; ============================================================
BITS    16
CPU     8086
ORG     0000h
%include "include/hardware.inc"

CASES   equ     4000h
RESULTS equ     6000h

start:
        cli
        mov     ax, 2000h
        mov     ss, ax
        mov     sp, 0F000h              ; pile de l'interprete (le cas utilise la sienne)
        push    cs
        pop     ds
        cld
        call    init_ivt_not_implemented ; les 256 vecteurs: gestionnaires "non implemente" (comme start:)
        call    bios_init               ; vecteurs INT 11h-1Ah + zone de donnees 0040:0000
        xor     ax, ax
        mov     es, ax
        mov     word [es:09h*4], irq1_arduino_handler
        mov     [es:09h*4+2], cs
        mov     word [es:10h*4], bios_int10_std   ; (l'interface LCD de INT 10h est dans solution-01.asm)
        mov     [es:10h*4+2], cs
        mov     word [cs:cur], CASES
        mov     word [cs:res], RESULTS
.next:
        mov     si, [cs:cur]
        cmp     byte [cs:si], 0FFh
        je      .end
        mov     al, [cs:si]
        mov     [cs:.intins + 1], al     ; l'octet d'operande de "int n" est modifie
        mov     al, [cs:si + 24]
        mov     [cs:portc], al
        mov     al, [cs:si + 25]
        mov     [cs:porta], al
        cli
        mov     bx, [cs:si + 4]
        mov     cx, [cs:si + 6]
        mov     dx, [cs:si + 8]
        mov     di, [cs:si + 12]
        mov     bp, [cs:si + 18]
        mov     es, [cs:si + 14]
        mov     ss, [cs:si + 20]
        mov     sp, [cs:si + 22]
        mov     ds, [cs:si + 16]
        mov     ax, [cs:si + 2]
        mov     si, [cs:si + 10]
        sti
.intins:
        int     0
        pushf                           ; --- retour du service: on range tout ---
        pop     word [cs:o_fl]
        mov     [cs:o_ax], ax
        mov     [cs:o_bx], bx
        mov     [cs:o_cx], cx
        mov     [cs:o_dx], dx
        mov     [cs:o_si], si
        mov     [cs:o_di], di
        mov     [cs:o_bp], bp
        mov     ax, es
        mov     [cs:o_es], ax
        mov     ax, ds
        mov     [cs:o_ds], ax
        mov     ax, ss
        mov     [cs:o_ss], ax
        mov     [cs:o_sp], sp
        cli
        mov     ax, 2000h
        mov     ss, ax
        mov     sp, 0F000h
        push    cs
        pop     ds
        push    cs
        pop     es
        mov     si, o_ax
        mov     di, [cs:res]
        mov     cx, 12
        rep     movsw
        add     word [cs:res], 32
        add     word [cs:cur], 32
        sti
        jmp     .next
.end:
        mov     al, 1
        out     0FFh, al
        hlt

        times   3F00h - ($-$$) db 0      ; donnees a des adresses FIXES (lues par le script Python)
cur     dw      0                       ; 3F00h
res     dw      0                       ; 3F02h
portc   db      80h                     ; 3F04h: lu par IN 82h (PORTC): OBF# = 1
porta   db      0                       ; 3F05h: lu par IN 80h (PORTA)
o_ax    dw 0
o_bx    dw 0
o_cx    dw 0
o_dx    dw 0
o_si    dw 0
o_di    dw 0
o_es    dw 0
o_ds    dw 0
o_bp    dw 0
o_ss    dw 0
o_sp    dw 0
o_fl    dw 0

        times   CASES - ($-$$) db 0
        times   7000h - CASES db 0       ; table des cas (4000h) et des resultats (6000h)

%include "lib/uart.asm"
%include "lib/ps2.asm"
%include "lib/bridge.asm"
%include "lib/isr.asm"
%include "lib/bios.asm"
