; ============================================================
; isr.asm - irq1_arduino_handler
; Gestionnaire REEL de IR1 (INT 09h): INTR du 8255 (PC3, mode 2) se
; declenche a chaque octet que l'Arduino a pousse sur le Port A. Lit
; d'abord le mot d'etat (Port C): PC5 (IBF) confirme qu'un octet est
; bien la (sinon interruption parasite: rien a lire), PC0 (etiquette
; posee par l'Arduino AVANT son impulsion STB#) dit d'ou vient l'octet -
; 0 = scan code clavier (ps2_rx_push, lib/ps2.asm), 1 = octet recu par
; l'UART materiel (uart_rx_push, lib/uart.asm); PC1 = 1 (prioritaire) = octet
; de REPONSE a une commande du pont (bridge_rx_push, lib/bridge.asm). Lit ensuite le Port A
; (ce qui efface IBF et INTR - plus de PB_RX_ACK: c'est la poignee de
; main materielle du 8255), envoie l'EOI NON SPECIFIQUE (obligatoire en
; mode EOI MANUEL, voir init_8259) et fait IRET.
;
; REDEMARRAGE A CHAUD: l'octet UART WARM_RESET_KEY (Ctrl-\, 1Ch) n'est PAS range dans le tampon: l'ISR envoie l'EOI
; puis saute au vecteur de reset de la ROM (0C000h:0000h = start:), comme un reset materiel - cela fonctionne
; quoi qu'execute le 8088 (menu, BASIC, DOS, programme DOS bloque...) et ramene au menu principal sans toucher
; au bouton RESET. Les octets du clavier PS/2 ne sont pas concernes.
;
; TRACE DU BIOS: l'octet UART TRACE_KEY (Ctrl-T, 14h) ou Ctrl-Echap au clavier PS/2 bascule la trace des
; INT 13h/1Ah (BIOS_TRC_ON, lib/bios.asm) - trace_toggle - sans etre range: utilisable a tout moment,
; au menu comme sous DOS, sans changer de ROM.
;
; INDEPENDANTE DE LA PILE ET DE DS du programme interrompu (un DOS, par exemple, a sa
; propre pile et ses propres segments): l'ISR sauve DS, le charge avec VAR_SEG, et les
; routines *_rx_push adressent les tampons par DS.
;
; Aucune ecriture de port autre que l'EOI ici: cette ISR ne touche jamais
; au Port B ni au Port A en ecriture, donc ne peut pas perturber un
; arduino_send interrompu (voir lib/common.asm). Seuls AX et DS sont modifies
; (et restaures).
;
; Inclus par solution-01.asm et tests/bios_test.asm - garde requise.
; ============================================================
%ifndef ISR_ASM
%define ISR_ASM

WARM_RESET_KEY equ    1Ch                     ; Ctrl-\ envoye par le terminal
TRACE_KEY      equ    14h                     ; Ctrl-T envoye par le terminal: bascule la trace du BIOS
                                              ; (Ctrl-] d'abord: intapable dans PuTTY sur clavier francais, ] = AltGr)
PS2_SC_BREAK   equ    0F0h                    ; clavier PS/2 (jeu 2): prefixe de relachement
PS2_SC_EXT     equ    0E0h                    ; prefixe des touches etendues (Ctrl droit = E0 14)
PS2_SC_CTRL    equ    14h                     ; Ctrl (gauche, ou droit apres E0)
PS2_SC_ESC     equ    76h                     ; Echap

irq1_arduino_handler:
        push    ax
        push    ds
        mov     ax, VAR_SEG
        mov     ds, ax                  ; les tampons vivent dans VAR_SEG

        in      al, PORTC               ; mot d'etat + etiquette (PC0/PC1)
        test    al, PC_IBF
        jz      .fin                    ; rien a lire: interruption parasite
        call    irq1_dispatch
.fin:
        mov     al, 20h                 ; OCW2: EOI non specifique
        out     PIC_CMD, al

        pop     ds
        pop     ax
        iret

; irq1_dispatch: lit l'octet du Port A et le range selon son etiquette. Entree: AL = mot
; d'etat du Port C (IBF = 1), DS = VAR_SEG. Detruit AL seulement. Appelee par l'ISR ci-dessus
; ET par la scrutation de bridge_rx_get_t (lib/bridge.asm) quand IR1 est masquee pendant une
; commande au pont - meme classement dans les deux cas.
irq1_dispatch:
        test    al, PC_TAG_REPLY
        jz      .notreply
        cmp     byte [BRIDGE_EXPECT_OFF], 0     ; PC1 = 1 ne compte que pendant une commande
        jne     .reply                  ; (rtc_get, fs_*): hors de ces intervalles, une PC1 non
                                        ; cablee/flottante ne perturbe pas le clavier ni l'UART
.notreply:
        test    al, PC_TAG_UART
        jnz     .uart
        in      al, PORTA               ; scan code clavier brut
        call    ps2_hotkey              ; Ctrl-Echap: bascule la trace, scan code non range (CF = 1)
        jc      .r
        jmp     ps2_rx_push
.uart:
        in      al, PORTA               ; octet recu par l'UART materiel
        cmp     al, WARM_RESET_KEY
        je      .warm
        cmp     al, TRACE_KEY
        jne     .push_uart
        call    trace_toggle            ; Ctrl-T: bascule la trace, octet non range
.r:
        ret
.push_uart:
        jmp     uart_rx_push
.warm:
        mov     al, 20h                 ; EOI (start: reinitialise de toute facon le 8259)
        out     PIC_CMD, al
        jmp     0C000h:0000h            ; le meme saut que le vecteur de reset (FFFF0h)
.reply:
        in      al, PORTA               ; reponse du pont (horloge RTC, disque...)
        jmp     bridge_rx_push

; ps2_hotkey: suit Ctrl (make 14h / relachement F0 14, E0 ignore: Ctrl droit = Ctrl gauche) dans les scan
; codes bruts du clavier PS/2 et detecte Ctrl-Echap (76h avec Ctrl enfonce) -> trace_toggle. Entree: AL =
; scan code, DS = VAR_SEG. Sortie: CF = 1 si le scan code est consomme (Echap de Ctrl-Echap), CF = 0 sinon
; (AL intact: a ranger normalement). Le relachement F0 76 qui suit est range: sans effet pour le lecteur.
ps2_hotkey:
        cmp     al, PS2_SC_BREAK
        jne     .notbrk
        or      byte [PS2_HOTKEY_OFF], 1        ; le prochain scan code est un relachement
        jmp     .keep
.notbrk:
        cmp     al, PS2_SC_EXT
        je      .keep                           ; E0 (E0 F0 14 = Ctrl droit relache: F0 vient apres)
        test    byte [PS2_HOTKEY_OFF], 1
        jz      .make
        and     byte [PS2_HOTKEY_OFF], 0FEh     ; relachement:
        cmp     al, PS2_SC_CTRL
        jne     .keep
        and     byte [PS2_HOTKEY_OFF], 0FDh     ; Ctrl relache
        jmp     .keep
.make:
        cmp     al, PS2_SC_CTRL
        jne     .esc
        or      byte [PS2_HOTKEY_OFF], 2        ; Ctrl enfonce
        jmp     .keep
.esc:
        cmp     al, PS2_SC_ESC
        jne     .keep
        test    byte [PS2_HOTKEY_OFF], 2
        jz      .keep
        call    trace_toggle
        stc
        ret
.keep:
        clc
        ret

; trace_toggle: bascule BIOS_TRC_ON (trace des INT 13h/1Ah, lib/bios.asm) et l'annonce sur l'UART.
; DS = VAR_SEG. Preserve tout (appelee depuis l'ISR, qui ne sauve que AX/DS, et depuis la scrutation).
trace_toggle:
        push    si
        push    ds
        push    ax
        xor     byte [BIOS_TRC_ON], 1   ; ZF = 0: trace desormais active
        mov     si, txt_trace_on
        jnz     .msg
        mov     si, txt_trace_off
.msg:
        push    cs
        pop     ds                      ; messages en ROM
        call    uart_tx_string
        pop     ax
        pop     ds
        pop     si
        ret

%ifdef LANG_EN
txt_trace_on:   db      13, 10, '[BIOS trace ON: every INT 13h/1Ah on the UART - Ctrl-T or Ctrl-Esc = OFF]', 13, 10, 0
txt_trace_off:  db      13, 10, '[BIOS trace OFF]', 13, 10, 0
%else
txt_trace_on:   db      13, 10, '[Trace BIOS ACTIVE: chaque INT 13h/1Ah sur l', 27h, 'UART - Ctrl-T ou Ctrl-Echap = arret]', 13, 10, 0
txt_trace_off:  db      13, 10, '[Trace BIOS ARRETEE]', 13, 10, 0
%endif

%endif ; ISR_ASM
