; =============================================================================
; services.inc - services du BIOS de type IBM PC, et interruptions materielles du
; 8259A (U13) : IRQ0 = 8253 (INT 08h), IRQ1 = clavier (INT 09h), IRQ4 = UART (INT 0Ch),
; IRQ7 parasite (0Fh).
; Sans 8259 (V_PIC = 0) : clavier et UART scrutes pendant INT 16h, comme le BIOS 0.7.
;
;   INT 10h  ecran : tampon de 24 lignes x 80 colonnes en RAM (DSEG:ECRAN), en mode
;            teletype ; le LCD 20x4 montre une FENETRE de ce tampon, qui suit le
;            curseur (les dernieres lignes ecrites). Maj + fleches deplacent la
;            fenetre (haut/bas : 1 ligne, gauche/droite : NAV_C colonnes).
;            Console UART (V_UCON, menu 5) : AH = 0Eh recopie aussi le caractere sur TX
;            (~1 ms, interruptions masquees) ; les octets recus par IRQ4 deviennent des
;            touches d'INT 16h (ucon_entree).
;   INT 11h  equipement (BDA 0040:0010) ; INT 12h memoire (BDA 0040:0013, RAM_KO Ko).
;   INT 13h  disquette A: = image de 180 Ko EN ROM (DISQUE_SEG), lecture seule ;
;            B: = disque virtuel de 128 Ko en RAM (DISQUE_B_SEG), lecture-ecriture.
;   INT 14h  UART logiciel : envoi (AH=01h) ; reception (AH=02h/03h) avec le 8259.
;   INT 15h  non gere (CF = 1, AH = 86h).
;   INT 16h  file de FILE_N touches, remplie par IRQ1 (ou par scrutation sans 8259).
;   INT 17h  pas d'imprimante. INT 18h retour au menu. INT 19h amorcage de A:.
;   INT 1Ah  compteur de tops du BDA, avance par IRQ0 (8253) : 18,2065 tops/s.
;
; Conventions : dans les gestionnaires, DS = CS (tables en ROM), ES = DSEG
; (variables et tampon d'ecran). Les registres d'entree sont dans le cadre
; [bp + R_xx] (BIOS_ENTREE) ; les resultats y sont ecrits, bios_sortie les rend.
; =============================================================================

R_AX    equ     0
R_BX    equ     2
R_CX    equ     4
R_DX    equ     6
R_SI    equ     8
R_DI    equ     10
R_BP    equ     12
R_ES    equ     14
R_DS    equ     16
R_FL    equ     22                      ; indicateurs empiles par INT (IP 18, CS 20)

%macro BIOS_ENTREE 0
        push    ds
        push    es
        push    bp
        push    di
        push    si
        push    dx
        push    cx
        push    bx
        push    ax
        mov     bp, sp
        sti                             ; IRQ1/IRQ4 servies pendant les services
        cld
        mov     ax, cs
        mov     ds, ax
        mov     ax, DSEG
        mov     es, ax
        mov     ax, [bp + R_AX]
%endmacro

bios_cf1:                               ; sortie avec CF = 1
        or      word [bp + R_FL], 1
        jmp     bios_sortie
bios_cf0:                               ; sortie avec CF = 0
        and     word [bp + R_FL], 0FFFEh
bios_sortie:
        pop     ax
        pop     bx
        pop     cx
        pop     dx
        pop     si
        pop     di
        pop     bp
        pop     es
        pop     ds
int_defaut:                             ; vecteurs non geres : retour immediat
        iret

; -----------------------------------------------------------------------------
; Table des vecteurs : (numero, gestionnaire ou table en F000), 0FFh = fin
; -----------------------------------------------------------------------------
vecteurs:
        db      08h
        dw      irq_temps               ; IRQ0 : 8253
        db      09h
        dw      irq_clavier             ; IRQ1
        db      0Ch
        dw      irq_uart                ; IRQ4
        db      0Fh
        dw      irq_parasite            ; IRQ7 : demande retombee avant INTA
        db      10h
        dw      int10h
        db      11h
        dw      int11h
        db      12h
        dw      int12h
        db      13h
        dw      int13h
        db      14h
        dw      int14h
        db      15h
        dw      int15h
        db      16h
        dw      int16h
        db      17h
        dw      int17h
        db      18h
        dw      int18h
        db      19h
        dw      int19h
        db      1Ah
        dw      int1ah
        db      1Dh
        dw      table_nulle             ; parametres video (pas de CRTC)
        db      1Eh
        dw      dpt_180                 ; parametres de la disquette
        db      1Fh
        dw      table_nulle             ; caracteres graphiques
        db      0FFh

; table des parametres de disquette (INT 1Eh) : valeurs du BIOS d'origine, 9 secteurs
dpt_180:
        db      0DFh, 02h, 25h, 02h, DISQUE_SPT, 2Ah, 0FFh, 50h, 0F6h, 0Fh, 02h
table_nulle:
        times   16 db 0

; =============================================================================
; dos_charger : installe les vecteurs, le BDA et l'ecran, puis amorce A: (INT 19h).
; =============================================================================
dos_charger:
        cli
        cld
        call    ivt_init
        sti                             ; IRQ1/IRQ4 permises (la touche du menu se relache)
        mov     ax, 40h                 ; BDA (0040:0000-00FF) : remis a zero puis rempli
        mov     es, ax
        xor     di, di
        xor     ax, ax
        mov     cx, 128
        rep     stosw
        mov     word [es:10h], EQUIPEMENT
        mov     word [es:13h], RAM_KO
        push    ds
        mov     ax, DSEG
        mov     ds, ax
        cmp     byte [V_IMGB_ACTIF], 0  ; B: = image de la carte : le disque en RAM est
        pop     ds                      ; inutile, sa place va au DOS
        je      .memoire
        mov     word [es:13h], RAM_KO_SANS_B
.memoire:
        mov     word [es:1Ah], 1Eh      ; file du clavier du BDA (vide ; la vraie est en DSEG)
        mov     word [es:1Ch], 1Eh
        mov     word [es:80h], 1Eh
        mov     word [es:82h], 3Eh
        mov     byte [es:49h], 3        ; mode video 3 : 80 colonnes
        mov     word [es:4Ah], COLS
        mov     word [es:4Ch], 1000h
        mov     word [es:60h], 0607h
        mov     word [es:63h], 3D4h
        mov     byte [es:84h], LIGNES - 1
        push    ds                      ; disque dur C: : 1 disque fixe (BDA 0040:0075),
        mov     ax, DSEG                ; INT 41h -> sa table de parametres
        mov     ds, ax
        cmp     byte [V_HD_ACTIF], 0
        pop     ds
        je      .sans_c
        mov     byte [es:75h], 1
        push    es
        xor     ax, ax
        mov     es, ax
        mov     word [es:41h * 4], HD_TABLE
        mov     word [es:41h * 4 + 2], DSEG
        pop     es
.sans_c:
        push    ds
        mov     ax, DSEG
        mov     ds, ax
        cmp     byte [V_IMGB_ACTIF], 0
        pop     ds
        jne     .sans_ram
        call    disque_b_prepare
.sans_ram:
        mov     ax, DSEG
        mov     es, ax
        call    ecran_init
        call    kbd_bloque
        int     19h

; disque_b_prepare : lecteur B: (DISQUE_B_SEG) garde s'il porte la signature (OEM
; 'SOL02 B:', 55AAh, media FEh dans la FAT), sinon formate : amorce, 2 FAT (amas
; B_AMAS_BON+1 .. B_AMAS_MAX marques defectueux), repertoire vide. DS = CS. Detruit
; AX, BX, CX, SI, DI ; ES = DISQUE_B_SEG en sortie.
disque_b_prepare:
        mov     ax, DISQUE_B_SEG
        mov     es, ax
        mov     si, boot_b + 3
        mov     di, 3
        mov     cx, 8
        repe    cmpsb
        jne     .formate
        cmp     word [es:510], 0AA55h
        jne     .formate
        cmp     byte [es:512], 0FEh
        jne     .formate
        ret
.formate:
        xor     di, di                  ; secteurs 0-6 : amorce, FAT, FAT, racine (4)
        xor     ax, ax
        mov     cx, 7 * 256
        rep     stosw
        xor     di, di
        mov     si, boot_b
        mov     cx, boot_b_fin - boot_b
        rep     movsb
        mov     word [es:510], 0AA55h
        mov     word [es:512], 0FFFEh   ; FAT : FEh FFh FFh
        mov     byte [es:514], 0FFh
        mov     bx, B_AMAS_BON + 1
.bad:   call    fat12_bad
        inc     bx
        cmp     bx, B_AMAS_MAX
        jbe     .bad
        push    ds
        push    es
        pop     ds
        mov     si, 512                 ; 2e FAT = copie de la 1re
        mov     di, 1024
        mov     cx, 256
        rep     movsw
        pop     ds
        ret

; fat12_bad : amas BX = FF7h (defectueux) dans la FAT en ES:0200h. Detruit AX, DI.
fat12_bad:
        mov     di, bx
        shr     di, 1
        add     di, bx                  ; DI = 3 x amas / 2
        mov     ax, [es:di + 512]
        test    bl, 1
        jnz     .impair
        and     ax, 0F000h
        or      ax, 0FF7h
        jmp     .ecrit
.impair:
        and     ax, 000Fh
        or      ax, 0FF70h
.ecrit: mov     [es:di + 512], ax
        ret

; ivt_init : IVT = 256 vecteurs vers int_defaut, puis ceux de la table `vecteurs`.
; DS = CS. Preserve ES ; detruit AX, CX, SI, DI.
ivt_init:
        push    es
        xor     ax, ax
        mov     es, ax
        xor     di, di
        mov     cx, 256
.v:     mov     ax, int_defaut
        stosw
        mov     ax, cs
        stosw
        loop    .v
        mov     si, vecteurs            ; puis nos gestionnaires
.s:     lodsb
        cmp     al, 0FFh
        je      .fin
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     di, ax
        movsw
        mov     ax, cs
        stosw
        jmp     .s
.fin:   pop     es
        ret

; it_init : (interruptions masquees) vecteurs, puis 8259 : reinitialise, detecte par
; relecture du masque (A5h puis 5Ah ; sans 8259, le bus flottant ne les rend pas) ;
; present : IR1 et IR4 ouvertes, clavier libre (PC0 = 1), V_PIC = 1. Le STI est a
; faire par l'appelant. DS = CS, ES = DSEG. Detruit AX, CX, SI, DI.
it_init:
        cli
        call    ivt_init
        mov     al, PIC_ICW1
        out     PIC_CMD, al
        mov     al, PIC_ICW2
        out     PIC_DATA, al
        mov     al, PIC_ICW4
        out     PIC_DATA, al
        mov     al, 0A5h
        out     PIC_DATA, al
        in      al, PIC_DATA
        cmp     al, 0A5h
        jne     .absent
        mov     al, 5Ah
        out     PIC_DATA, al
        in      al, PIC_DATA
        cmp     al, 5Ah
        jne     .absent
        mov     al, PIC_MASQUE
        cmp     byte [es:V_PIT], 0      ; 8253 : IR0 aussi, animations en arriere-plan
        je      .masque
        mov     al, PIC_MASQUE_T
.masque:
        out     PIC_DATA, al
        mov     al, [es:V_PIT]
        mov     [es:V_TACHE_ON], al
        mov     byte [es:V_PIC], 1
        jmp     kbd_libere
.absent:
        mov     byte [es:V_PIC], 0
        mov     byte [es:V_TACHE_ON], 0
        ret

; =============================================================================
; IRQ0 (INT 08h) : 72,83 Hz (8253). EOI et STI tout de suite (IRQ1/IRQ4 ne doivent pas
; attendre : le 8259 en mode front perd la demande si elle retombe avant INTA). Un
; appel sur 4 : top du PC (0040:006C, minuit en 0040:0070, INT 1Ch). Puis, si c'est
; l'heure, un pas de la tache des animations, sur sa propre pile, jusqu'a ce qu'elle
; cede la main (tache_cede, depuis del_aff). Pas de pas si la tache tourne deja.
; =============================================================================
irq_temps:
        push    ax
        mov     al, PIC_EOI
        out     PIC_CMD, al
        sti
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        mov     ax, DSEG
        mov     es, ax
        mov     ax, cs
        mov     ds, ax
        inc     byte [es:V_IT0]
        inc     byte [es:V_QUART]
        test    byte [es:V_QUART], 3
        jnz     .anim
        push    ds
        mov     ax, 40h
        mov     ds, ax
        add     word [6Ch], 1
        adc     word [6Eh], 0
        cmp     word [6Eh], 18h         ; 1800B0h tops = 24 h
        jb      .jour
        cmp     word [6Ch], 0B0h
        jb      .jour
        xor     ax, ax
        mov     [6Ch], ax
        mov     [6Eh], ax
        mov     byte [70h], 1
.jour:  pop     ds
        int     1Ch
.anim:  cmp     byte [es:V_TACHE_ON], 0
        je      .retour
        cmp     byte [es:V_PROGRES], 0  ; progression du demarrage sur le bargraphe
        jne     .retour
        cmp     byte [es:V_DISQUE], 0   ; acces disque recent : LED Show en pause
        je      .tache
        dec     byte [es:V_DISQUE]
        jmp     .retour
.tache: cli
        cmp     byte [es:V_TACHE_OCC], 0
        jne     .retour_sti
        dec     byte [es:V_TACHE_ATT]
        jnz     .retour_sti
        mov     byte [es:V_TACHE_OCC], 1
        mov     [es:V_HOTE_SP], sp
        mov     [es:V_HOTE_SS], ss
        mov     ax, es
        mov     ss, ax
        mov     sp, [es:V_TACHE_SP]
        pop     es                      ; registres de la tache
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        sti
        ret                             ; reprise apres tache_cede
.retour_sti:
        sti
.retour:
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        iret

; =============================================================================
; Son : compteur 2 de la 8253 (mode 3, OUT2) et verrou du port 61h (U16). Seulement
; avec la 8253 et le 8259 (V_TACHE_ON) : les durees se comptent en IRQ0.
; son_note : AX = diviseur (2 666 667 / f), CL = duree en IRQ0 (13,7 ms) ; le son est
; coupe a la fin. Interruptions permises pendant l'attente. ES = DSEG. Preserve tout
; sauf CL.
; =============================================================================
son_note:
        cmp     byte [es:V_TACHE_ON], 0
        je      .fin
        push    ax
        push    bx
        mov     bx, ax
        mov     al, PIT_MOT2
        out     PIT_MODE, al
        mov     al, bl
        out     PIT_C2, al
        mov     al, bh
        out     PIT_C2, al
        mov     al, [es:V_P61]
        or      al, 3                   ; GATE2 et haut-parleur
        out     PORT_HP, al
        sti
.att:   mov     al, [es:V_IT0]
.w:     cmp     al, [es:V_IT0]
        je      .w
        dec     cl
        jnz     .att
        mov     al, [es:V_P61]
        and     al, 0FCh
        out     PORT_HP, al
        pop     bx
        pop     ax
.fin:   ret

; son_melodie : joue la suite (diviseur, duree) en CS:SI terminee par 0. Detruit AX, CX, SI.
son_melodie:
.n:     mov     ax, [cs:si]
        or      ax, ax
        jz      .fin
        mov     cl, [cs:si + 2]
        call    son_note
        add     si, 4
        jmp     .n
.fin:   ret

; tache_cede : (tache des animations) attend DI IRQ0 : sauve ses registres sur sa pile,
; rend la main au programme interrompu par IRQ0. Preserve tout (au retour).
tache_cede:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        mov     ax, DSEG
        mov     ds, ax
        mov     ax, di
        cli
        mov     [V_TACHE_ATT], al
        mov     [V_TACHE_SP], sp
        mov     byte [V_TACHE_OCC], 0
        mov     ss, [V_HOTE_SS]
        mov     sp, [V_HOTE_SP]
        jmp     irq_temps.retour

; =============================================================================
; IRQ1 (INT 09h) : debut d'une trame du clavier. La trame est lue par scrutation
; (~1 ms), decodee ; la touche va dans la file d'INT 16h. Maj + fleche sous DOS :
; notee dans V_NAV (la fenetre du LCD est deplacee par INT 16h, jamais pendant une
; ecriture au LCD). Ctrl + Alt + Suppr : redemarrage.
; =============================================================================
irq_clavier:
        push    ax
        push    ds
        push    es
        mov     ax, cs
        mov     ds, ax
        mov     ax, DSEG
        mov     es, ax
        inc     byte [es:V_KBD_N]       ; (ecran_uart attend le calme)
        call    ps2_trame_it
        jc      .fin
        call    clavier_decode
        jc      .fin
        cmp     ah, 53h                 ; Ctrl + Alt + Suppr
        jne     .pas_reset
        test    byte [es:V_CLAVIER], CLV_CTRL
        jz      .pas_reset
        test    byte [es:V_CLAVIER], CLV_ALT
        jz      .pas_reset
        mov     al, PIC_EOI
        out     PIC_CMD, al
        jmp     0F000h:debut
.pas_reset:
        or      al, al                  ; Maj + fleche sous DOS : deplacement de la fenetre
        jnz     .file
        cmp     byte [es:V_DOS], 0
        je      .file
        test    byte [es:V_CLAVIER], CLV_MAJS | CLV_FAUX
        jz      .file
        cmp     ah, 48h
        je      .nav
        cmp     ah, 50h
        je      .nav
        cmp     ah, 4Bh
        je      .nav
        cmp     ah, 4Dh
        jne     .file
.nav:   mov     [es:V_NAV], ah
        jmp     .fin
.file:  call    file_ajoute
        mov     byte [es:V_EVT], 1
.fin:   mov     al, PIC_EOI
        out     PIC_CMD, al
        pop     es
        pop     ds
        pop     ax
        iret

; IRQ4 (INT 0Ch) : bit de depart sur RX. L'octet est lu par scrutation (~1 ms) et
; mis dans la file de l'UART (INT 14h AH=02h, LED Show) ; console UART (V_UCON) :
; converti en touche dans la file du clavier, dans tous les modes.
irq_uart:
        push    ax
        push    es
        call    uart_rx_it
        jc      .fin
        push    bx
        mov     bx, DSEG
        mov     es, bx
        cmp     byte [es:V_UCON], 0     ; console UART (tous les modes) : touche
        je      .ufile
        call    ucon_entree
        jmp     .evt
.ufile: call    ufile_ajoute
.evt:   mov     byte [es:V_EVT], 1
        pop     bx
.fin:   mov     al, PIC_EOI
        out     PIC_CMD, al
        pop     es
        pop     ax
        iret

; ucon_entree : console UART, AL = octet recu -> touche(s) dans la file d'INT 16h.
; CR -> Entree, BS ou DEL -> retour arriere, TAB, ESC ; LF et NUL ignores ; autres :
; AL = caractere, AH = 0. Sequences ANSI du terminal (envoyees d'un trait, lues ici
; par scrutation) : ESC [ ou ESC O suivi de A B C D (fleches), H F (debut, fin),
; P Q R S (F1-F4), ou de 1-6 puis ~ (debut, inser, suppr, fin, page prec/suiv).
; ESC seul (rien dans les ~2,7 ms) : touche Echap. ES = DSEG. Detruit AX.
ucon_entree:
        push    bx
        push    cx
        cmp     al, 1Bh
        je      .esc
.simple:
        call    ucon_code
        jc      .fin
        call    file_ajoute
.fin:   pop     cx
        pop     bx
        ret
.esc:   call    ucon_suivant
        jc      .echap
        cmp     al, '['
        je      .csi
        cmp     al, 'O'
        je      .csi
        push    ax                      ; ESC puis un autre octet : Echap, puis cet octet
        mov     ax, 011Bh
        call    file_ajoute
        pop     ax
        jmp     .simple
.echap: mov     ax, 011Bh
        call    file_ajoute
        jmp     .fin
.csi:   call    ucon_suivant
        jc      .fin
        mov     bx, ucon_csi
        call    ucon_table
        jnc     .etendue
        mov     bx, ucon_tilde
        call    ucon_table
        jc      .fin
        push    ax
        call    ucon_suivant            ; '~' attendu
        mov     bl, al
        pop     ax
        jc      .fin
        cmp     bl, '~'
        jne     .fin
.etendue:
        xor     al, al                  ; touche etendue : AL = 0, AH = code XT
        call    file_ajoute
        jmp     .fin

; ucon_suivant : attend (~2,7 ms) le bit de depart de l'octet suivant d'une sequence
; et le lit. AL = octet, CF = 1 si rien ou trame invalide. Detruit CX.
ucon_suivant:
        mov     cx, UCON_ATTENTE
.a:     in      al, PPI2_PB
        test    al, UART_RX
        jz      .depart
        loop    .a
        stc
        ret
.depart:
        jmp     uart_rx

; ucon_table : cherche AL dans la table CS:BX de paires (caractere, code XT) terminee
; par 0. AH = code XT, CF = 0 ; CF = 1 si absent. Detruit BX.
ucon_table:
        mov     ah, [cs:bx]
        or      ah, ah
        jz      .non
        cmp     ah, al
        je      .oui
        add     bx, 2
        jmp     ucon_table
.oui:   mov     ah, [cs:bx + 1]
        clc
        ret
.non:   stc
        ret

ucon_csi:
        db      'A', 48h, 'B', 50h, 'C', 4Dh, 'D', 4Bh, 'H', 47h, 'F', 4Fh
        db      'P', 3Bh, 'Q', 3Ch, 'R', 3Dh, 'S', 3Eh, 0
ucon_tilde:
        db      '1', 47h, '2', 52h, '3', 53h, '4', 4Fh, '5', 49h, '6', 51h, 0

; ucon_code : AL = octet simple -> AX = touche (AH = code XT des touches de commande).
; CF = 1 : octet ignore (LF, NUL).
ucon_code:
        mov     ah, 1Ch
        cmp     al, 13
        je      .ok
        mov     ah, 0Eh
        cmp     al, 8
        je      .ok
        cmp     al, 7Fh                 ; DEL (retour arriere de bien des terminaux)
        jne     .tab
        mov     al, 8
        jmp     .ok
.tab:   mov     ah, 0Fh
        cmp     al, 9
        je      .ok
        mov     ah, 01h
        cmp     al, 1Bh
        je      .ok
        cmp     al, 10
        je      .non
        or      al, al
        jz      .non
        xor     ah, ah
.ok:    clc
        ret
.non:   stc
        ret

; IRQ7 : le 8259 donne ce vecteur quand l'entree est retombee avant INTA (pas de fin
; d'interruption a envoyer) ; comptee pour SysInfo.
irq_parasite:
        push    ds
        push    ax
        mov     ax, DSEG
        mov     ds, ax
        inc     word [V_IRQ7]
        pop     ax
        pop     ds
        iret

; ufile_ajoute : AL dans la file de l'UART (perdu si pleine). ES = DSEG. Preserve tout.
ufile_ajoute:
        push    bx
        mov     bl, [es:V_UFILE_Q]
        mov     bh, bl
        inc     bh
        and     bh, UFILE_N - 1
        cmp     bh, [es:V_UFILE_T]
        je      .fin
        mov     [es:V_UFILE_Q], bh
        xor     bh, bh
        mov     [es:bx + V_UFILE], al
.fin:   pop     bx
        ret

; ufile_retire : AL = octet le plus ancien, CF = 1 si la file est vide. Preserve le reste.
ufile_retire:
        push    bx
        mov     bl, [es:V_UFILE_T]
        cmp     bl, [es:V_UFILE_Q]
        je      .vide
        mov     bh, bl
        inc     bh
        and     bh, UFILE_N - 1
        mov     [es:V_UFILE_T], bh
        xor     bh, bh
        mov     al, [es:bx + V_UFILE]
        pop     bx
        clc
        ret
.vide:  pop     bx
        stc
        ret

; nav_traite : Maj + fleche notee par IRQ1 -> deplacement de la fenetre. Preserve tout.
nav_traite:
        cmp     byte [es:V_NAV], 0
        je      .fin
        push    ax
        mov     ah, 0
        xchg    ah, [es:V_NAV]
        call    ecran_nav
        pop     ax
.fin:   ret

; =============================================================================
; INT 10h - ecran
; =============================================================================
int10h:
        BIOS_ENTREE
        mov     byte [es:V_SORTIE], 1
        mov     byte [es:V_SUIT], 1
        cmp     ah, 0Eh
        je      .tty
        cmp     ah, 02h
        je      .pos
        cmp     ah, 03h
        je      .lit_pos
        cmp     ah, 06h
        je      .defile
        cmp     ah, 07h
        je      .defile
        cmp     ah, 09h
        je      .ecrit
        cmp     ah, 0Ah
        je      .ecrit
        cmp     ah, 08h
        je      .lit_car
        cmp     ah, 0Fh
        je      .mode
        cmp     ah, 00h
        je      .efface
        jmp     bios_sortie             ; 01h, 05h, 0Bh, ... : sans effet
.tty:   cmp     byte [es:V_UCON], 0     ; console UART : copie sur TX (80h-FFh en UTF-8)
        je      .t1
        call    uart_tx_cp437
.t1:    cmp     al, 7                   ; BEL : bip de 880 Hz, ~0,25 s
        jne     .t2
        push    ax
        mov     ax, NOTE_BIP
        mov     cl, 18
        call    son_note
        pop     ax
.t2:    call    ecran_tty
.fin:   call    ecran_fin
        jmp     bios_sortie
.pos:   cmp     dh, LIGNES - 1
        jbe     .p1
        mov     dh, LIGNES - 1
.p1:    cmp     dl, COLS - 1
        jbe     .p2
        mov     dl, COLS - 1
.p2:    mov     [es:V_CUR], dx
        jmp     .fin
.lit_pos:
        mov     ax, [es:V_CUR]
        mov     [bp + R_DX], ax
        mov     word [bp + R_CX], 0607h
        jmp     bios_sortie
.defile:
        call    ecran_defile
        jmp     .fin
.ecrit: mov     dx, [es:V_CUR]          ; AL, CX fois, sans deplacer le curseur
.e:     jcxz    .fin
        call    ecran_cellule
        inc     dl
        cmp     dl, COLS
        jb      .e1
        xor     dl, dl
        inc     dh
        cmp     dh, LIGNES
        jae     .fin
.e1:    loop    .e
        jmp     .fin
.lit_car:
        mov     dx, [es:V_CUR]
        call    ecran_adr
        mov     al, [es:di]
        mov     ah, 07h
        mov     [bp + R_AX], ax
        jmp     bios_sortie
.mode:  mov     word [bp + R_AX], (COLS << 8) | 3
        mov     byte [bp + R_BX + 1], 0
        jmp     bios_sortie
.efface:
        call    ecran_vide
        jmp     .fin

; ecran_init : tampon vide, curseur et fenetre en 0,0, LCD efface (et ses 8 caracteres
; programmables charges : accents). Mode DOS actif.
ecran_init:
        mov     byte [es:V_DOS], 1
        mov     byte [es:V_LCDC], 0
        call    lcd_cgram
        mov     al, 0Ch                 ; afficheur allume, sans curseur
        call    lcd_cmd_r
        mov     al, 01h                 ; effacer (1,52 ms)
        call    lcd_cmd_r
        push    cx
        DELAY   3000
        pop     cx
ecran_vide:
        push    cx
        push    di
        mov     ax, 2020h
        xor     di, di
        mov     cx, LIGNES * COLS / 2
        rep     stosw
        xor     ax, ax
        mov     [es:V_CUR], ax
        mov     [es:V_VUE], ax
        mov     byte [es:V_REDESS], 1
        pop     di
        pop     cx
        ret

; ecran_adr : DX = position (DH ligne, DL colonne) -> DI = decalage dans le tampon. Detruit AX.
ecran_adr:
        mov     al, COLS
        mul     dh
        mov     di, ax
        mov     al, dl
        xor     ah, ah
        add     di, ax
        ret

; ecran_cellule : ecrit AL en DX dans le tampon, et au LCD si la case est visible.
; Preserve tout.
ecran_cellule:
        push    ax
        push    bx
        push    di
        push    ax
        call    ecran_adr
        pop     ax
        mov     [es:di], al
        mov     bx, [es:V_VUE]          ; BL = colonne de gauche, BH = ligne du haut
        mov     ah, dh
        sub     ah, bh                  ; AH = ligne du LCD
        jb      .fin
        cmp     ah, 4
        jae     .fin
        mov     bh, dl
        sub     bh, bl                  ; BH = colonne du LCD
        jb      .fin
        cmp     bh, LCD_COLS
        jae     .fin
        push    ax
        call    lcd_aller
        pop     ax
        call    lcd_car_f
.fin:   pop     di
        pop     bx
        pop     ax
        ret

; ecran_tty : AL en mode teletype (BEL ignore, BS, CR, LF, retour a la ligne en
; colonne 80, defilement en bas du tampon).
ecran_tty:
        mov     dx, [es:V_CUR]
        cmp     al, 7
        je      .fin
        cmp     al, 8
        jne     .pas_bs
        or      dl, dl
        jz      .fin
        dec     dl
        jmp     .pos
.pas_bs:
        cmp     al, 13
        jne     .pas_cr
        xor     dl, dl
        jmp     .pos
.pas_cr:
        cmp     al, 10
        je      .lf
        call    ecran_cellule
        inc     dl
        cmp     dl, COLS
        jb      .pos
        xor     dl, dl
.lf:    inc     dh
        cmp     dh, LIGNES
        jb      .pos
        mov     dh, LIGNES - 1
        call    ecran_monte
.pos:   mov     [es:V_CUR], dx
.fin:   ret

; ecran_monte : tout le tampon monte d'une ligne, derniere ligne vide. Preserve tout.
ecran_monte:
        push    ax
        push    cx
        push    si
        push    di
        push    ds
        push    es
        pop     ds
        xor     di, di
        mov     si, COLS
        mov     cx, (LIGNES - 1) * COLS / 2
        rep     movsw
        mov     ax, 2020h
        mov     cx, COLS / 2
        rep     stosw
        pop     ds
        mov     byte [es:V_REDESS], 1
        pop     di
        pop     si
        pop     cx
        pop     ax
        ret

; ecran_defile : INT 10h AH = 06h (vers le haut) ou 07h (vers le bas) ; AL = lignes
; (0 = efface la fenetre), CH,CL = coin haut gauche, DH,DL = coin bas droit.
ecran_defile:
        cmp     dh, LIGNES - 1
        jbe     .1
        mov     dh, LIGNES - 1
.1:     cmp     dl, COLS - 1
        jbe     .2
        mov     dl, COLS - 1
.2:     cmp     ch, dh
        ja      .fin
        cmp     cl, dl
        ja      .fin
        mov     bl, al                  ; BL = nombre de lignes
        mov     al, dh
        sub     al, ch
        inc     al                      ; AL = hauteur de la fenetre
        or      bl, bl
        jz      .tout
        cmp     bl, al
        jb      .n
.tout:  mov     bl, al
.n:     mov     al, dl
        sub     al, cl
        inc     al
        mov     bh, al                  ; BH = largeur
        push    ds
        push    es
        pop     ds                      ; DS = ES = DSEG pour MOVSB
        cmp     byte [bp + R_AX + 1], 07h
        je      .bas
        mov     al, ch                  ; vers le haut : lignes CH..DH
.h:     mov     ah, al
        add     ah, bl                  ; AH = ligne source
        cmp     ah, dh
        ja      .h_vide
        call    ligne_copie
        jmp     .h_suiv
.h_vide:
        call    ligne_vide
.h_suiv:
        cmp     al, dh
        je      .fait
        inc     al
        jmp     .h
.bas:   mov     al, dh                  ; vers le bas : lignes DH..CH
.b:     mov     ah, al
        sub     ah, bl
        jb      .b_vide
        cmp     ah, ch
        jb      .b_vide
        call    ligne_copie
        jmp     .b_suiv
.b_vide:
        call    ligne_vide
.b_suiv:
        cmp     al, ch
        je      .fait
        dec     al
        jmp     .b
.fait:  pop     ds
        mov     byte [es:V_REDESS], 1
.fin:   ret

; ligne_copie : ligne AL <- ligne AH, a partir de la colonne CL, BH colonnes.
; ligne_vide : ligne AL remplie d'espaces, memes colonnes. DS = ES = DSEG. Preservent AX-DX.
ligne_copie:
        push    ax
        push    cx
        push    dx
        mov     dx, ax                  ; DL = destination, DH = source
        mov     al, COLS
        mul     dl
        mov     di, ax
        mov     al, COLS
        mul     dh
        mov     si, ax
        xor     ch, ch
        add     di, cx
        add     si, cx
        mov     cl, bh
        rep     movsb
        pop     dx
        pop     cx
        pop     ax
        ret
ligne_vide:
        push    ax
        push    cx
        mov     ah, COLS
        mul     ah
        mov     di, ax
        xor     ch, ch
        add     di, cx
        mov     cl, bh
        mov     al, ' '
        rep     stosb
        pop     cx
        pop     ax
        ret

; ecran_fin : la fenetre suit le curseur VERTICALEMENT (deplacement minimal : les
; dernieres lignes ecrites restent visibles) ; horizontalement, elle ne bouge pas
; pendant l'ecriture (seules ses 20 colonnes vont au LCD, voir ecran_suit_h).
; Redessine le LCD si la fenetre a bouge ou si le tampon a change en bloc, puis place
; le curseur du LCD. Detruit AX, BX, DX.
ecran_fin:
        mov     dx, [es:V_CUR]
        mov     bx, [es:V_VUE]
        cmp     dh, bh                  ; vertical
        jae     .v1
        mov     bh, dh
        jmp     .v2
.v1:    mov     al, bh
        add     al, 3
        cmp     dh, al
        jbe     .v2
        mov     bh, dh
        sub     bh, 3
.v2:    cmp     bx, [es:V_VUE]
        je      .meme
        mov     [es:V_VUE], bx
        jmp     .redess
.meme:  cmp     byte [es:V_REDESS], 0
        je      lcd_curseur
.redess:
        mov     byte [es:V_REDESS], 0
        call    ecran_redessine
        ; (suite : lcd_curseur)

; ecran_suit_h : appele quand le DOS attend une touche, s'il a affiche quelque chose
; depuis (V_SUIT) : si le curseur est hors des colonnes de la fenetre, elle se place
; par pas de NAV_C colonnes pour le montrer (gauche = (colonne / NAV_C - 1) x NAV_C,
; entre 0 et COLS - 20). Un deplacement par Maj + fleches reste donc en place tant
; que rien n'est affiche. Preserve tout.
ecran_suit_h:
        cmp     byte [es:V_SUIT], 0
        je      .r
        mov     byte [es:V_SUIT], 0
        push    ax
        push    bx
        push    dx
        mov     dx, [es:V_CUR]
        mov     bx, [es:V_VUE]
        cmp     dl, bl
        jb      .place
        mov     al, bl
        add     al, LCD_COLS - 1
        cmp     dl, al
        jbe     .fin
.place: mov     al, dl
        xor     ah, ah
        mov     dl, NAV_C
        div     dl                      ; AL = colonne / NAV_C
        mul     dl                      ; AX = AL x NAV_C
        sub     al, NAV_C
        jae     .p1
        xor     al, al
.p1:    cmp     al, COLS - LCD_COLS
        jbe     .p2
        mov     al, COLS - LCD_COLS
.p2:    mov     bl, al
        mov     [es:V_VUE], bx
        call    ecran_redessine
        call    lcd_curseur
.fin:   pop     dx
        pop     bx
        pop     ax
.r:     ret

; lcd_curseur : curseur du LCD sur la case du curseur si elle est visible, cache sinon.
; Detruit AX, BX, DX.
lcd_curseur:
        mov     dx, [es:V_CUR]
        mov     bx, [es:V_VUE]
        mov     ah, dh
        sub     ah, bh
        jb      .cache
        cmp     ah, 4
        jae     .cache
        mov     al, dl
        sub     al, bl
        jb      .cache
        cmp     al, LCD_COLS
        jae     .cache
        mov     bh, al
        call    lcd_aller
        cmp     byte [es:V_LCDC], 1
        je      .fin
        mov     byte [es:V_LCDC], 1
        mov     al, 0Eh                 ; curseur (souligne) visible
        jmp     lcd_cmd_r
.cache: cmp     byte [es:V_LCDC], 0
        je      .fin
        mov     byte [es:V_LCDC], 0
        mov     al, 0Ch
        jmp     lcd_cmd_r
.fin:   ret

; ecran_redessine : les 4 lignes de la fenetre au LCD. Preserve tout.
ecran_redessine:
        push    ax
        push    bx
        push    cx
        push    si
        xor     ah, ah                  ; AH = ligne du LCD
.l:     xor     bh, bh
        call    lcd_aller
        push    ax
        mov     bx, [es:V_VUE]
        mov     al, bh
        add     al, ah
        mov     cl, COLS
        mul     cl
        xor     bh, bh
        add     ax, bx
        mov     si, ax                  ; SI = (haut + ligne) * 80 + gauche
        pop     ax
        mov     cl, LCD_COLS
.c:     mov     al, [es:si]
        call    lcd_car_f
        inc     si
        dec     cl
        jnz     .c
        inc     ah
        cmp     ah, 4
        jb      .l
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

; ecran_nav : AH = code XT d'une fleche (Maj enfoncee) : deplace la fenetre.
; CF = 1 si AH n'est pas une fleche. Preserve tout.
ecran_nav:
        push    ax
        push    bx
        push    dx
        mov     bx, [es:V_VUE]
        cmp     ah, 48h                 ; haut
        jne     .b
        or      bh, bh
        jz      .ok
        dec     bh
        jmp     .ok
.b:     cmp     ah, 50h                 ; bas
        jne     .g
        cmp     bh, LIGNES - 4
        jae     .ok
        inc     bh
        jmp     .ok
.g:     cmp     ah, 4Bh                 ; gauche
        jne     .d
        sub     bl, NAV_C
        jae     .ok
        xor     bl, bl
        jmp     .ok
.d:     cmp     ah, 4Dh                 ; droite
        jne     .non
        add     bl, NAV_C
        cmp     bl, COLS - LCD_COLS
        jbe     .ok
        mov     bl, COLS - LCD_COLS
.ok:    cmp     bx, [es:V_VUE]
        je      .r
        mov     [es:V_VUE], bx
        call    ecran_redessine
        call    lcd_curseur
.r:     clc
        jmp     .sortie
.non:   stc
.sortie:
        pop     dx
        pop     bx
        pop     ax
        ret

; lcd_aller : AH = ligne du LCD (0-3), BH = colonne -> adresse DDRAM. Preserve tout sauf AL.
lcd_aller:
        push    bx
        mov     bl, ah
        mov     al, bh
        xor     bh, bh
        add     al, [cs:bx + lignes_ddram]
        or      al, 80h
        pop     bx
        jmp     lcd_cmd_r

; lcd_car_f : caractere AL (page de codes 437 du DOS) au LCD : codes de controle ->
; espace ; 80h-FFh -> table cp437_lcd (accents francais courants = CGRAM 0-7, voir
; lcd_cgram ; les autres sans accent ; quelques symboles de la ROM A00). Preserve tout.
lcd_car_f:
        cmp     al, ' '
        jb      .espace
        cmp     al, 80h
        jb      lcd_car_r
        push    bx
        mov     bl, al
        and     bx, 7Fh
        mov     al, [cs:bx + cp437_lcd]
        pop     bx
        jmp     lcd_car_r
.espace:
        mov     al, ' '
; lcd_car_r / lcd_cmd_r : donnee / commande AL, delai LCD_D. Preservent tout.
lcd_car_r:
        out     LCD_DATA, al
        jmp     lcd_attente
lcd_cmd_r:
        out     LCD_CMD, al
lcd_attente:
        push    cx
        mov     cx, LCD_D
.d:     loop    .d
        pop     cx
        ret

; lcd_cgram : charge les 8 caracteres programmables du LCD (codes 0-7) : e aigu, e grave,
; e circonflexe, a grave, a circonflexe, c cedille, u grave, o circonflexe. Preserve tout.
lcd_cgram:
        push    ax
        push    cx
        push    si
        mov     al, 40h                 ; adresse CGRAM 0
        call    lcd_cmd_r
        mov     si, lcd_glyphes
        mov     cx, 64
.g:     mov     al, [cs:si]
        call    lcd_car_r
        inc     si
        loop    .g
        mov     al, 80h                 ; retour en DDRAM
        call    lcd_cmd_r
        pop     si
        pop     cx
        pop     ax
        ret

lcd_glyphes:
        db      02h, 04h, 0Eh, 11h, 1Fh, 10h, 0Eh, 00h   ; 0 : e aigu
        db      08h, 04h, 0Eh, 11h, 1Fh, 10h, 0Eh, 00h   ; 1 : e grave
        db      04h, 0Ah, 0Eh, 11h, 1Fh, 10h, 0Eh, 00h   ; 2 : e circonflexe
        db      08h, 04h, 0Eh, 01h, 0Fh, 11h, 0Fh, 00h   ; 3 : a grave
        db      04h, 0Ah, 0Eh, 01h, 0Fh, 11h, 0Fh, 00h   ; 4 : a circonflexe
        db      00h, 00h, 0Eh, 10h, 10h, 11h, 0Eh, 04h   ; 5 : c cedille
        db      08h, 04h, 11h, 11h, 11h, 13h, 0Dh, 00h   ; 6 : u grave
        db      04h, 0Ah, 0Eh, 11h, 11h, 11h, 0Eh, 00h   ; 7 : o circonflexe

; page de codes 437 (80h-FFh) -> octet du LCD : 0-7 = CGRAM, sinon ASCII ou ROM A00
cp437_lcd:
        db      043h, 075h, 000h, 004h, 061h, 003h, 061h, 005h, 002h, 065h, 001h, 069h, 069h, 069h, 041h, 041h   ; 80h
        db      045h, 061h, 041h, 007h, 06Fh, 06Fh, 075h, 006h, 079h, 04Fh, 055h, 063h, 04Ch, 059h, 050h, 066h   ; 90h
        db      061h, 069h, 06Fh, 075h, 06Eh, 04Eh, 061h, 06Fh, 03Fh, 02Dh, 02Dh, 02Fh, 02Fh, 021h, 03Ch, 03Eh   ; A0h
        db      0FFh, 0FFh, 0FFh, 07Ch, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 07Ch, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh   ; B0h
        db      02Bh, 02Bh, 02Bh, 02Bh, 02Dh, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 03Dh, 02Bh, 02Bh   ; C0h
        db      02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 02Bh, 0FFh, 05Fh, 07Ch, 07Ch, 02Dh   ; D0h
        db      0E0h, 0E2h, 047h, 0F7h, 0F6h, 0E5h, 0E4h, 074h, 04Fh, 0F2h, 0F4h, 064h, 0F3h, 06Fh, 0E3h, 06Eh   ; E0h
        db      03Dh, 02Bh, 03Eh, 03Ch, 07Ch, 07Ch, 0FDh, 07Eh, 0DFh, 0A5h, 0A5h, 0E8h, 06Eh, 032h, 0FFh, 020h   ; F0h

; uart_tx_cp437 : AL (page de codes 437 du DOS) vers le terminal : 00h-7Fh tels quels,
; 80h-FFh en UTF-8 (2 ou 3 octets, comme Solution-01) : le terminal doit etre en UTF-8.
; Preserve tout.
uart_tx_cp437:
        test    al, 80h
        jnz     .ext
        jmp     uart_tx
.ext:   push    ax
        push    bx
        push    cx
        mov     bl, al
        and     bx, 007Fh
        shl     bx, 1
        mov     bx, [cs:bx + cp437_utf]
        cmp     bx, 0800h
        jae     .trois
        mov     ax, bx                  ; 2 octets : 110xxxxx 10xxxxxx
        mov     cl, 6
        shr     ax, cl
        or      al, 0C0h
        call    uart_tx
        jmp     .dernier
.trois: mov     ax, bx                  ; 3 octets : 1110xxxx 10xxxxxx 10xxxxxx
        mov     cl, 12
        shr     ax, cl
        or      al, 0E0h
        call    uart_tx
        mov     ax, bx
        mov     cl, 6
        shr     ax, cl
        and     al, 3Fh
        or      al, 80h
        call    uart_tx
.dernier:
        mov     al, bl
        and     al, 3Fh
        or      al, 80h
        call    uart_tx
        pop     cx
        pop     bx
        pop     ax
        ret

; page de codes 437 : point de code Unicode de 80h-FFh
cp437_utf:
        dw      000C7h, 000FCh, 000E9h, 000E2h, 000E4h, 000E0h, 000E5h, 000E7h   ; 80h-87h
        dw      000EAh, 000EBh, 000E8h, 000EFh, 000EEh, 000ECh, 000C4h, 000C5h   ; 88h-8Fh
        dw      000C9h, 000E6h, 000C6h, 000F4h, 000F6h, 000F2h, 000FBh, 000F9h   ; 90h-97h
        dw      000FFh, 000D6h, 000DCh, 000A2h, 000A3h, 000A5h, 020A7h, 00192h   ; 98h-9Fh
        dw      000E1h, 000EDh, 000F3h, 000FAh, 000F1h, 000D1h, 000AAh, 000BAh   ; A0h-A7h
        dw      000BFh, 02310h, 000ACh, 000BDh, 000BCh, 000A1h, 000ABh, 000BBh   ; A8h-AFh
        dw      02591h, 02592h, 02593h, 02502h, 02524h, 02561h, 02562h, 02556h   ; B0h-B7h
        dw      02555h, 02563h, 02551h, 02557h, 0255Dh, 0255Ch, 0255Bh, 02510h   ; B8h-BFh
        dw      02514h, 02534h, 0252Ch, 0251Ch, 02500h, 0253Ch, 0255Eh, 0255Fh   ; C0h-C7h
        dw      0255Ah, 02554h, 02569h, 02566h, 02560h, 02550h, 0256Ch, 02567h   ; C8h-CFh
        dw      02568h, 02564h, 02565h, 02559h, 02558h, 02552h, 02553h, 0256Bh   ; D0h-D7h
        dw      0256Ah, 02518h, 0250Ch, 02588h, 02584h, 0258Ch, 02590h, 02580h   ; D8h-DFh
        dw      003B1h, 000DFh, 00393h, 003C0h, 003A3h, 003C3h, 000B5h, 003C4h   ; E0h-E7h
        dw      003A6h, 00398h, 003A9h, 003B4h, 0221Eh, 003C6h, 003B5h, 02229h   ; E8h-EFh
        dw      02261h, 000B1h, 02265h, 02264h, 02320h, 02321h, 000F7h, 02248h   ; F0h-F7h
        dw      000B0h, 02219h, 000B7h, 0221Ah, 0207Fh, 000B2h, 025A0h, 000A0h   ; F8h-FFh

lignes_ddram:
        db      LIGNE1, LIGNE2, LIGNE3, LIGNE4

; =============================================================================
; INT 11h, 12h, 14h, 15h, 17h, 18h
; =============================================================================
int11h:
        push    ds
        mov     ax, 40h
        mov     ds, ax
        mov     ax, [10h]
        pop     ds
        iret

int12h:
        push    ds
        mov     ax, 40h
        mov     ds, ax
        mov     ax, [13h]
        pop     ds
        iret

; INT 14h : AH = 01h envoie AL sur l'UART logiciel ; AH = 02h rend l'octet le plus
; ancien recu par IRQ4 (attente ~0,5 s, puis AH = 80h) ; AH = 03h : AH bit 0 = octet
; en attente. Sans 8259 : rien n'est recu.
int14h:
        sti
        cmp     ah, 01h
        jne     .pas_tx
        call    uart_tx
        mov     ah, 60h                 ; emetteur vide
        iret
.pas_tx:
        push    es
        push    cx
        mov     cx, DSEG
        mov     es, cx
        cmp     ah, 02h
        jne     .etat
        xor     cx, cx                  ; ~65536 essais
.r:     call    ufile_retire
        jnc     .recu
        cmp     byte [es:V_PIC], 0
        je      .delai
        loop    .r
.delai: mov     ah, 80h                 ; delai depasse
        jmp     .fin
.recu:  xor     ah, ah
        jmp     .fin
.etat:  mov     ax, 6030h               ; emetteur vide ; CTS, DSR
        push    bx
        mov     bl, [es:V_UFILE_T]
        cmp     bl, [es:V_UFILE_Q]
        pop     bx
        je      .fin
        or      ah, 01h                 ; donnee prete
.fin:   pop     cx
        pop     es
        iret

int15h:
        BIOS_ENTREE
        mov     byte [bp + R_AX + 1], 86h
        jmp     bios_cf1

int17h:
        mov     ah, 01h                 ; delai depasse : pas d'imprimante
        iret

int18h:                                 ; (ROM BASIC sur un PC) : retour au menu
        jmp     menu

; =============================================================================
; INT 19h - amorcage : secteur 0 de A: en 0000:7C00, saut avec DL = 0
; =============================================================================
int19h:
        cli
        xor     ax, ax
        mov     ss, ax
        mov     sp, 7C00h
        sti
        mov     si, 3                   ; 3 essais
.essai: mov     ax, DSEG                ; A:, ou C: si choisi au Load DOS
        mov     es, ax
        xor     dx, dx
        cmp     byte [es:V_BOOT_C], 0
        je      .lecteur
        mov     dl, 80h
.lecteur:
        xor     ax, ax
        mov     es, ax
        mov     bx, 7C00h
        mov     ax, 0201h
        mov     cx, 0001h
        push    dx
        int     13h
        pop     dx
        jnc     .ok
        dec     si
        jnz     .essai
        jmp     menu                    ; (n'arrive pas : le disque est en ROM)
.ok:    jmp     0000h:7C00h             ; DL = lecteur d'amorcage

; =============================================================================
; INT 13h - disquette A: en ROM (180 Ko : 40 cylindres, 1 tete, 9 secteurs), ou image
; .IMG de la carte SD choisie au Load DOS (int13_sd) ; B: disque virtuel en RAM
; =============================================================================
int13h:
        BIOS_ENTREE
        cmp     dl, 80h                 ; C: = image de disque dur de la carte
        jne     .pas_c
        cmp     byte [es:V_HD_ACTIF], 0
        je      .absent
        jmp     int13_hd
.pas_c: cmp     dl, 1                   ; A: (ROM ou image de la carte SD) ou B: (RAM ou image)
        ja      .absent
        je      .lb
        cmp     byte [es:V_IMG_ACTIF], 0
        je      .b
        jmp     int13_sd                ; A: = image .IMG de la carte (sd.inc)
.lb:    cmp     byte [es:V_IMGB_ACTIF], 0
        je      .b
        jmp     int13_sd                ; B: = image DOS 2.x de la carte
.b:
        cmp     ah, 02h
        je      .lire
        cmp     ah, 00h
        je      .ok
        cmp     ah, 04h
        je      .verifier
        cmp     ah, 01h
        je      .etat
        cmp     ah, 03h
        je      .ecrire
        cmp     ah, 05h
        je      .formater
        cmp     ah, 08h
        je      .params
        cmp     ah, 15h
        je      .type
        cmp     ah, 16h
        je      .ok
        mov     ah, 01h                 ; fonction inconnue
        jmp     .err
.absent:
        mov     ah, 80h                 ; autre disquette : delai depasse
        test    dl, 80h
        jz      .err
        mov     ah, 01h                 ; disque dur : aucun
        jmp     .err
.protege:
        mov     ah, 03h
.err:   mov     [bp + R_AX + 1], ah
        mov     [es:V_DSTAT], ah
        jmp     bios_cf1
.ok:    mov     byte [bp + R_AX + 1], 0
        mov     byte [es:V_DSTAT], 0
        jmp     bios_cf0
.etat:  mov     al, [es:V_DSTAT]
        mov     [bp + R_AX], al
        jmp     .ok
.type:  mov     byte [bp + R_AX + 1], 01h   ; disquette sans ligne de changement
        jmp     bios_cf0
.params:
        mov     word [bp + R_AX], 0
        mov     word [bp + R_BX], 0001h
        mov     word [bp + R_CX], ((DISQUE_CYL - 1) << 8) | DISQUE_SPT
        or      dl, dl
        jz      .p_a
        mov     word [bp + R_CX], ((B_CYL - 1) << 8) | B_SPT
.p_a:   mov     word [bp + R_DX], 0002h     ; tete max 0, 2 lecteurs
        mov     word [bp + R_DI], dpt_180
        mov     [bp + R_ES], cs
        jmp     bios_cf0
.formater:
        or      dl, dl
        jz      .protege
        jmp     .ok                     ; B: : rien a faire (les secteurs existent)
.verifier:
        call    disque_lba
        jc      .err
        jmp     .ok
.ecrire:
        or      dl, dl
        jz      .protege
        call    disque_lba              ; DX = segment du 1er secteur dans la RAM
        jc      .err
        mov     ax, [bp + R_BX]         ; source ES:BX normalisee : DS:SI
        mov     si, ax
        and     si, 0Fh
        mov     cl, 4
        shr     ax, cl
        add     ax, [bp + R_ES]
        mov     ds, ax
        mov     bl, [bp + R_AX]
.e_sect:
        mov     es, dx
        xor     di, di
        mov     cx, 256
        rep     movsw
        mov     ax, ds
        add     ax, 32
        mov     ds, ax
        sub     si, 512
        add     dx, 32
        dec     bl
        jnz     .e_sect
        mov     ax, cs
        mov     ds, ax
        mov     ax, DSEG
        mov     es, ax
        jmp     .ok
.lire:  call    disque_lba              ; DX = segment du 1er secteur (ROM ou RAM)
        jc      .err
        mov     ax, [bp + R_BX]         ; destination ES:BX normalisee : ES' = ES + BX/16
        mov     di, ax
        and     di, 0Fh
        mov     cl, 4
        shr     ax, cl
        add     ax, [bp + R_ES]
        mov     es, ax
        mov     bl, [bp + R_AX]         ; BL = nombre de secteurs
.sect:  mov     ds, dx
        xor     si, si
        mov     cx, 256
        rep     movsw
        mov     ax, es
        add     ax, 32                  ; secteur suivant (512 octets)
        mov     es, ax
        sub     di, 512
        add     dx, 32
        dec     bl
        jnz     .sect
        mov     ax, DSEG
        mov     es, ax
        jmp     .ok

; disque_lba : AL = nombre de secteurs, CH = cylindre, CL = secteur, DH = tete,
; DL = lecteur (0 = A: en ROM, 1 = B: en RAM). Sortie : AX = LBA du premier secteur,
; DX = segment de ce secteur, ou CF = 1 et AH = code d'erreur. Detruit BX, SI.
disque_lba:
        mov     si, geo_a
        or      dl, dl
        jz      .geo
        mov     si, geo_b
.geo:   or      al, al
        jz      .inval
        or      dh, dh
        jnz     .introuvable
        cmp     ch, [cs:si]             ; cylindres
        jae     .introuvable
        mov     bl, cl
        and     bl, 3Fh
        jz      .introuvable
        cmp     bl, [cs:si + 1]         ; secteurs par piste
        ja      .introuvable
        mov     bh, al                  ; BH = nombre
        mov     al, [cs:si + 1]
        mul     ch                      ; AX = cylindre * secteurs par piste
        dec     bl
        add     al, bl
        adc     ah, 0                   ; AX = LBA
        push    ax
        add     al, bh
        adc     ah, 0
        cmp     ax, [cs:si + 2]         ; secteurs presents
        pop     ax
        ja      .introuvable
        mov     dx, ax
        push    cx
        mov     cl, 5
        shl     dx, cl
        pop     cx
        add     dx, [cs:si + 4]         ; DX = segment du secteur
        clc
        ret
.inval: mov     ah, 01h
        stc
        ret
.introuvable:
        mov     ah, 04h
        stc
        ret

; geometrie : cylindres, secteurs par piste, secteurs presents, segment
geo_a:  db      DISQUE_CYL, DISQUE_SPT
        dw      DISQUE_SECT, DISQUE_SEG
geo_b:  db      B_CYL, B_SPT
        dw      B_SECT, DISQUE_B_SEG

; =============================================================================
; INT 16h - clavier
; =============================================================================
int16h:
        BIOS_ENTREE
        and     ah, 0EFh                ; 10h-12h (clavier etendu) = 00h-02h
        cmp     ah, 00h
        je      .lire
        cmp     ah, 01h
        je      .etat
        cmp     ah, 02h
        je      .drapeaux
        cmp     ah, 05h
        je      .pousse
        jmp     bios_sortie
.lire:  cmp     byte [es:V_PROGRES], 0  ; 1re attente du clavier : fin de la progression
        je      .lire1                  ; (le LCD reprend la fenetre, les DEL leurs animations)
        mov     byte [es:V_PROGRES], 0
        call    ecran_redessine
.lire1: call    ecran_suit_h            ; curseur montre avant d'attendre
        call    kbd_attend
        mov     [bp + R_AX], ax
        jmp     .bloque
.etat:  cmp     byte [es:V_SORTIE], 0   ; le DOS attend vraiment une touche (pendant DIR,
        je      .e0                     ; il appelle aussi AH=01h pour Ctrl+C) quand
        mov     byte [es:V_INACTIF], 0  ; INACTIF_N appels se suivent sans affichage :
        jmp     .e1                     ; la fenetre montre alors le curseur
.e0:    cmp     byte [es:V_INACTIF], INACTIF_N
        jae     .e2
        inc     byte [es:V_INACTIF]
        jmp     .e1
.e2:    call    ecran_suit_h
.e1:    cmp     byte [es:V_PIC], 0
        je      .e_scrute
        call    nav_traite              ; 8259 : la file est remplie par IRQ1
        mov     byte [es:V_SORTIE], 0
        call    file_regarde
        jnc     .attend
        jmp     .vide
.e_scrute:
        call    file_regarde
        jnc     .attend
        call    kbd_libere
        mov     cx, KBD_FENETRE         ; DOS affiche : ecoute courte ; DOS attend
        cmp     byte [es:V_SORTIE], 0   ; (rien affiche depuis l'appel precedent) :
        jne     .scrute                 ; ecoute longue
        mov     cx, KBD_FENETRE_L
.scrute:
        mov     byte [es:V_SORTIE], 0
        call    kbd_scrute
        call    file_regarde
        jc      .vide
.attend:
        mov     [bp + R_AX], ax
        and     word [bp + R_FL], ~40h  ; ZF = 0 : une touche attend
        jmp     .bloque
.vide:  or      word [bp + R_FL], 40h   ; ZF = 1
.bloque:
        call    kbd_bloque
        jmp     bios_sortie
.drapeaux:
        mov     bl, [es:V_CLAVIER]
        xor     al, al
        test    bl, CLV_MAJ
        jz      .d0
        or      al, 02h                 ; Maj gauche
.d0:    test    bl, CLV_MAJ_D
        jz      .d1
        or      al, 01h                 ; Maj droite
.d1:    test    bl, CLV_CTRL
        jz      .d2
        or      al, 04h
.d2:    test    bl, CLV_ALT
        jz      .d3
        or      al, 08h
.d3:    test    bl, CLV_VERR_MAJ
        jz      .d4
        or      al, 40h
.d4:    or      al, 20h                 ; Verr Num (suppose actif)
        mov     [bp + R_AX], al
        jmp     bios_sortie
.pousse:
        mov     ax, cx
        cli                             ; (IRQ1 ajoute aussi a la file)
        call    file_ajoute
        sti
        mov     byte [bp + R_AX], 0
        jmp     bios_sortie

; kbd_libere / kbd_bloque : relache / bloque l'horloge du clavier (diode sur PC0 de
; U12). Le clavier n'est libre que pendant que le BIOS l'ecoute (kbd_attend, INT 16h,
; attentes du LED Show) : une touche frappee entre-temps attend dans le clavier.
; Detruisent AL.
kbd_libere:
        mov     al, KBD_LIBRE
        out     PPI2_CTRL, al
        ret
kbd_bloque:
        cmp     byte [es:V_PIC], 0      ; 8259 : le clavier reste libre (IRQ1)
        jne     .fin
        mov     al, KBD_BLOQUE
        out     PPI2_CTRL, al
.fin:   ret

; kbd_attend : attend une touche. Sortie : AX = code (AH = XT, AL = ASCII). ES = DSEG.
; Avec le 8259 : attend que IRQ1 remplisse la file (interruptions permises) et traite
; Maj + fleches sous DOS ; sinon : scrutation.
kbd_attend:
        push    cx
        cmp     byte [es:V_PIC], 0
        je      .scrute
        sti
.it:    call    file_retire
        jnc     .ok
        call    nav_traite
        jmp     .it
.scrute:
        call    file_retire
        jnc     .ok
        push    ax
        call    kbd_libere
        pop     ax
.a:     mov     cx, 2000
        call    kbd_scrute
        call    file_retire
        jc      .a
        push    ax
        call    kbd_bloque
        pop     ax
.ok:    pop     cx
        ret

; kbd_scrute : scrute l'horloge du clavier pendant CX tours (~8 us chacun) ; une
; trame recue est decodee et la touche mise dans la file. Rend la main des qu'une
; touche est dans la file. Detruit AX.
kbd_scrute:
        push    cx
.w:     in      al, PPI2_PB
        test    al, KBD_CLK
        jz      .trame
        loop    .w
        jmp     .fin
.trame: call    kbd_octet
        jnc     .fin
        loop    .w
.fin:   pop     cx
        ret

; kbd_octet : CLK vient d'etre vu bas : lit la trame, decode, traite les touches
; speciales. CF = 0 si une touche a ete mise dans la file. Detruit AX.
kbd_octet:
        call    ps2_trame
        jc      .rien
        call    clavier_decode
        jc      .rien
        cmp     ah, 53h                 ; Ctrl + Alt + Suppr : retour au menu
        jne     .pas_reset
        test    byte [es:V_CLAVIER], CLV_CTRL
        jz      .pas_reset
        test    byte [es:V_CLAVIER], CLV_ALT
        jz      .pas_reset
        jmp     0F000h:debut
.pas_reset:
        or      al, al                  ; Maj + fleche sous DOS : deplace la fenetre
        jnz     .file
        cmp     byte [es:V_DOS], 0
        je      .file
        test    byte [es:V_CLAVIER], CLV_MAJS | CLV_FAUX
        jz      .file
        push    ax
        call    kbd_bloque              ; clavier bloque pendant le dessin du LCD
        pop     ax
        call    ecran_nav
        pushf
        push    ax
        call    kbd_libere
        pop     ax
        popf
        jnc     .rien
.file:  call    file_ajoute
        clc
        ret
.rien:  stc
        ret

; file de FILE_N codes de touche (mots) en DSEG : tete V_FILE_T, queue V_FILE_Q.
; file_ajoute : AX dans la file (perdu si elle est pleine). Preserve tout.
file_ajoute:
        push    bx
        mov     bl, [es:V_FILE_Q]
        mov     bh, bl
        inc     bh
        and     bh, FILE_N - 1
        cmp     bh, [es:V_FILE_T]
        je      .fin
        mov     [es:V_FILE_Q], bh
        xor     bh, bh
        shl     bx, 1
        mov     [es:bx + V_FILE], ax
.fin:   pop     bx
        ret

; file_regarde : AX = premier code sans le retirer ; CF = 1 si la file est vide.
; file_retire : idem, en le retirant. Preservent le reste.
file_regarde:
        push    bx
        mov     bl, [es:V_FILE_T]
        cmp     bl, [es:V_FILE_Q]
        je      file_vide
        xor     bh, bh
        shl     bx, 1
        mov     ax, [es:bx + V_FILE]
        pop     bx
        clc
        ret
file_retire:
        push    bx
        mov     bl, [es:V_FILE_T]
        cmp     bl, [es:V_FILE_Q]
        je      file_vide
        mov     bh, bl
        inc     bh
        and     bh, FILE_N - 1
        mov     [es:V_FILE_T], bh
        xor     bh, bh
        shl     bx, 1
        mov     ax, [es:bx + V_FILE]
        pop     bx
        clc
        ret
file_vide:
        pop     bx
        stc
        ret

; =============================================================================
; INT 1Ah - horloge : compteur de tops du BDA (0040:006C), sans minuterie
; =============================================================================
int1ah:
        BIOS_ENTREE
        push    ds
        mov     bx, 40h
        mov     ds, bx
        cmp     ah, 00h
        jne     .pas_0
        cli                             ; (IRQ0 avance le compteur)
        mov     ax, [6Ch]
        mov     [bp + R_DX], ax
        mov     ax, [6Eh]
        mov     [bp + R_CX], ax
        mov     al, [70h]
        mov     [bp + R_AX], al
        mov     byte [70h], 0
        sti
        pop     ds
        jmp     bios_cf0
.pas_0: cmp     ah, 01h
        jne     .non
        cli
        mov     [6Ch], dx
        mov     [6Eh], cx
        mov     byte [70h], 0
        sti
        pop     ds
        jmp     bios_cf0
.non:   pop     ds                      ; horloge temps reel (AT) : absente
        jmp     bios_cf1
