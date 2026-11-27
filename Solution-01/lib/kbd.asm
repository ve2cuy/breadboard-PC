; ============================================================
; kbd.asm (ROM 1.8)
; Clavier PS/2 -> caracteres, pour le BASIC, le Tiny BASIC et INT 16h (DOS). Le menu, lui, garde
; ps2_poll_char (liste blanche: chiffres, A-F, Q, R, Entree, Retour arriere, Echap, fleches).
;
; kbd_poll lit les scan codes du jeu 2 que le pont depose dans le tampon PS/2 (irq1_dispatch,
; ps2_rx_push), suit Maj gauche/droite, Ctrl, Alt et Verr. Maj, et rend la touche pressee sous la
; forme de INT 16h: AH = scan code du jeu 1 (XT), AL = caractere ASCII (0 pour une touche sans
; caractere: fleches, Debut, Fin, PgPrec, PgSuiv, Inser, Suppr, F1-F12, Alt + touche).
; Disposition: americaine (QWERTY US). Pave numerique: chiffres (Verr. Num toujours actif).
; Ctrl + touche de 40h-7Fh -> code de controle (Ctrl-C = 03h, Ctrl-X = 18h...).
;
; Etat: KBD_STATE (VAR_SEG, lu par SS: - tous les appelants ont SS = VAR_SEG), au format des
; indicateurs de INT 16h AH=02h: bit 0 Maj droite, bit 1 Maj gauche, bit 2 Ctrl, bit 3 Alt,
; bit 6 Verr. Maj.
; ============================================================
%ifndef KBD_ASM
%define KBD_ASM

%include "include/hardware.inc"
%include "lib/ps2.asm"

KBD_RSHIFT      equ     01h
KBD_LSHIFT      equ     02h
KBD_CTRL        equ     04h
KBD_ALT         equ     08h
KBD_CAPS        equ     40h

; kbd_reset: oublie les touches de modification enfoncees (le menu, qui ne les suit pas, a pu
; avaler leur relachement); Verr. Maj est gardee. Preserve tout.
kbd_reset:
        and     byte [ss:KBD_STATE], KBD_CAPS
        ret

; kbd_poll: CF = 0 et AX = touche (AH = scan code du jeu 1, AL = ASCII) si une touche a ete
; pressee; CF = 1 sinon (les relachements et les touches ignorees sont consommes). Ne bloque pas,
; sauf pour le 2e octet d'une sequence deja commencee (le pont l'envoie aussitot).
; Detruit AX. Preserve BX, CX, DX, SI, DI, BP, DS, ES.
kbd_poll:
        push    bx
        push    dx
.next:
        call    ps2_rx_available
        jc      .none
        call    ps2_read_byte           ; AL = octet
        xor     dl, dl                  ; DL: bit 0 relachement, bit 1 touche etendue (E0)
        cmp     al, 0E1h                ; Pause: E1 14 77 E1 F0 14 F0 77 -> Ctrl appuye puis relache
        je      .next
        cmp     al, 0E0h
        jne     .nx
        or      dl, 2
        call    ps2_read_byte
.nx:
        cmp     al, 0F0h
        jne     .code
        or      dl, 1
        call    ps2_read_byte
.code:
        ; --- touches de modification ---
        mov     dh, KBD_LSHIFT
        cmp     al, 12h
        je      .shift
        mov     dh, KBD_RSHIFT
        cmp     al, 59h
        je      .shift
        mov     dh, KBD_CTRL
        cmp     al, 14h
        je      .mod
        mov     dh, KBD_ALT
        cmp     al, 11h
        je      .mod
        test    dl, 1
        jnz     .next                   ; relachement d'une autre touche: rien
        cmp     al, 58h                 ; Verr. Maj: bascule a l'appui
        jne     .key
        xor     byte [ss:KBD_STATE], KBD_CAPS
        jmp     .next
.shift:
        test    dl, 2
        jnz     .next                   ; E0 12 / E0 59: Maj factices autour des touches etendues
.mod:
        test    dl, 1
        jnz     .up
        or      [ss:KBD_STATE], dh
        jmp     .next
.up:
        not     dh
        and     [ss:KBD_STATE], dh
        jmp     .next
.key:
        cmp     al, KBD_SET2_MAX
        ja      .next
        mov     bl, al
        xor     bh, bh
        mov     ah, [cs:kbd_set2 + bx]  ; AH = scan code du jeu 1
        or      ah, ah
        jz      .next                   ; touche inconnue
        test    dl, 2
        jnz     .ext
        ; --- touche normale ---
        cmp     ah, 47h
        jae     .high
        cmp     ah, 3Ah
        jae     .noasc                  ; F1-F10 (3Bh-44h)
        mov     bl, ah
        xor     bh, bh
        jmp     .asc
.high:
        cmp     ah, 53h
        ja      .noasc                  ; F11, F12
        mov     bl, ah
        xor     bh, bh
        mov     al, [cs:kbd_pad - 47h + bx]
        jmp     .done
.noasc:
        xor     al, al
        jmp     .done
.ext:
        ; --- touche etendue (E0 xx): pave de navigation, / et Entree du pave numerique ---
        mov     al, '/'
        cmp     ah, 35h
        je      .done
        mov     al, 0Dh
        cmp     ah, 1Ch
        je      .done
        cmp     ah, 47h
        jb      .next                   ; E0 1F, E0 27, E0 2F (touches Windows, menu), E0 7C...
        cmp     ah, 53h
        ja      .next
        xor     al, al
        jmp     .done
.asc:
        ; BX = scan code du jeu 1 (00h-39h)
        mov     al, [cs:kbd_asc + bx]
        mov     dh, [ss:KBD_STATE]
        test    dh, KBD_LSHIFT | KBD_RSHIFT
        jz      .caps
        mov     al, [cs:kbd_asc_shift + bx]
.caps:
        test    dh, KBD_CAPS
        jz      .ctrl
        mov     dl, al
        or      dl, 20h
        cmp     dl, 'a'
        jb      .ctrl
        cmp     dl, 'z'
        ja      .ctrl
        xor     al, 20h                 ; Verr. Maj inverse la casse des lettres (comme le PC)
.ctrl:
        test    dh, KBD_CTRL
        jz      .alt
        cmp     al, 40h
        jb      .alt
        and     al, 1Fh                 ; Ctrl-lettre, Ctrl-[ \ ] ...
.alt:
        test    dh, KBD_ALT
        jz      .done
        xor     al, al                  ; Alt + touche: AL = 0 (comme le BIOS du PC)
.done:
        pop     dx
        pop     bx
        clc
        ret
.none:
        pop     dx
        pop     bx
        stc
        ret

; scan code du jeu 2 (sans prefixe) -> jeu 1; 0 = touche ignoree
KBD_SET2_MAX    equ     83h
kbd_set2:
        ;       x0   x1   x2   x3   x4   x5   x6   x7   x8   x9   xA   xB   xC   xD   xE   xF
        db      00h, 43h, 00h, 3Fh, 3Dh, 3Bh, 3Ch, 58h, 00h, 44h, 42h, 40h, 3Eh, 0Fh, 29h, 00h  ; 0x
        db      00h, 38h, 2Ah, 00h, 1Dh, 10h, 02h, 00h, 00h, 00h, 2Ch, 1Fh, 1Eh, 11h, 03h, 00h  ; 1x
        db      00h, 2Eh, 2Dh, 20h, 12h, 05h, 04h, 00h, 00h, 39h, 2Fh, 21h, 14h, 13h, 06h, 00h  ; 2x
        db      00h, 31h, 30h, 23h, 22h, 15h, 07h, 00h, 00h, 00h, 32h, 24h, 16h, 08h, 09h, 00h  ; 3x
        db      00h, 33h, 25h, 17h, 18h, 0Bh, 0Ah, 00h, 00h, 34h, 35h, 26h, 27h, 19h, 0Ch, 00h  ; 4x
        db      00h, 00h, 28h, 00h, 1Ah, 0Dh, 00h, 00h, 3Ah, 36h, 1Ch, 1Bh, 00h, 2Bh, 00h, 00h  ; 5x
        db      00h, 2Bh, 00h, 00h, 00h, 00h, 0Eh, 00h, 00h, 4Fh, 00h, 4Bh, 47h, 00h, 00h, 00h  ; 6x
        db      52h, 53h, 50h, 4Ch, 4Dh, 48h, 01h, 00h, 57h, 4Eh, 51h, 4Ah, 37h, 49h, 00h, 00h  ; 7x
        db      00h, 00h, 00h, 41h                                                              ; 80-83

; jeu 1 (00h-39h) -> ASCII, sans Maj puis avec Maj (QWERTY US)
kbd_asc:
        db      0, 1Bh, '1234567890-=', 8, 9
        db      'qwertyuiop[]', 0Dh, 0
        db      'asdfghjkl;', 27h, '`', 0, '\'
        db      'zxcvbnm,./', 0, '*', 0, ' '
kbd_asc_shift:
        db      0, 1Bh, '!@#$%^&*()_+', 8, 9
        db      'QWERTYUIOP{}', 0Dh, 0
        db      'ASDFGHJKL:"~', 0, '|'
        db      'ZXCVBNM<>?', 0, '*', 0, ' '
; pave numerique (jeu 1, 47h-53h)
kbd_pad:
        db      '789-456+1230.'

%endif ; KBD_ASM
