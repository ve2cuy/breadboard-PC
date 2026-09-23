; ============================================================
; bios.asm - couche "BIOS PC" pour un DOS: INT 11h, 12h, 13h, 14h, 15h, 16h, 17h, 19h, 1Ah et
; les fonctions standard de INT 10h (teletype, mode video...), plus la zone de donnees du BIOS
; (0040:0000) et la memoire annoncee au DOS.
;
; PRINCIPE. Un DOS a sa propre pile et ses propres segments: le micrologiciel, lui, suppose
; SS = DS = VAR_SEG (tampons du pont et du clavier adresses par BP). Chaque service BIOS qui
; en a besoin (INT 13h, 16h, 1Ah, 19h) commence donc par BASCULER sur une pile privee de VAR_SEG
; (BIOS_ENTER), sauve TOUS les registres dans un cadre, travaille avec DS = VAR_SEG, ecrit ses
; resultats dans le cadre, puis restaure la pile du programme (bios_return) et fait IRET avec
; CF/ZF poses dans les indicateurs empiles. L'ISR (lib/isr.asm) est independante de la pile.
;
; DISQUE. Un seul disque dur, DL = 80h: la flash du pont, vue comme des secteurs de 512 octets
; (commandes 20h-24h du pont, fs_sec_* de lib/bridge.asm). Geometrie CHS 255 tetes x 63 secteurs
; (celle que SdFat ecrit dans le BPB), cylindres = secteurs / 16065 (arrondi vers le haut);
; l'acces etendu (INT 13h AH=41h-48h, LBA 32 bits) est aussi fourni. Pas de disquette: INT 11h
; annonce 0 lecteur.
;
; MEMOIRE. Le DOS recoit la RAM de 0000:0500 a 1000:F7FF (126 Ko, INT 12h); 1000:F800-FFFF reste
; au micrologiciel (tampons du pont, pile privee du BIOS).
;
; Inclus par solution-01.asm et tests/bios_test.asm apres lib/bridge.asm, lib/ps2.asm et
; lib/uart.asm - garde requise.
; ============================================================
%ifndef BIOS_ASM
%define BIOS_ASM

BIOS_MEM_KB     equ     126             ; RAM annoncee: 0000:0000-1000:F7FF (126 Ko)
%ifndef BIOS_HIDE_HD
BIOS_HIDE_HD    equ     0                       ; 1 = INT 13h refuse tout disque DL >= 80h (le DOS ne voit pas la flash comme disque dur C:; diagnostic)
%endif
%ifndef BIOS_TRACE
BIOS_TRACE      equ     0                       ; 1 (`make trace`): trace ACTIVE des le demarrage + carte memoire (bios_memmap)
                                                ; au 5e INT 1Ah AH=00. La trace elle-meme est TOUJOURS dans la ROM: Ctrl-]
                                                ; (UART) ou Ctrl-Echap (PS/2) la bascule (BIOS_TRC_ON, lib/isr.asm)
%endif
BIOS_SHOW_PATCH equ     1               ; 1 = '+' sur l'UART a chaque instruction OUT neutralisee (diagnostic)
BIOS_SHOW_RETRY equ     1               ; 1 = '!' sur l'UART a chaque lecture de secteur refaite (somme de controle fausse)
BIOS_STACK_TOP  equ     0FF00h          ; pile privee: 1000:FE00-FEFF (256 octets)
BIOS_SEC_PER_TRACK equ  63
BIOS_HEADS      equ     255

; cadre de registres empiles par BIOS_FRAME (offsets depuis BP)
FR_ES           equ     0
FR_DI           equ     2
FR_SI           equ     4
FR_BP           equ     6
FR_BX           equ     8
FR_DX           equ     10
FR_CX           equ     12
FR_AX           equ     14
FR_ALH          equ     15              ; AH dans le cadre

; ------------------------------------------------------------
; BIOS_ENTER: a placer en TOUT DEBUT d'un gestionnaire (IF = 0 apres l'INT). Sauve DS sur la pile du
; programme, charge DS = VAR_SEG, memorise SS:SP (pointant sur le DS sauve) et passe sur la pile
; privee. AX (et tous les autres registres) sont INTACTS.
; ------------------------------------------------------------
%macro BIOS_ENTER 0
        push    ds
        push    ax
        mov     ax, VAR_SEG
        mov     ds, ax
        pop     ax
        mov     [BIOS_SP_OFF], sp
        mov     [BIOS_SS_OFF], ss
        push    ds
        pop     ss                      ; SS = VAR_SEG (IF = 0: pas d'interruption entre les deux)
        mov     sp, BIOS_STACK_TOP
%endmacro

; BIOS_FRAME: empile tous les registres (cadre FR_*) et fixe BP; les registres vivants ne changent pas
%macro BIOS_FRAME 0
        push    ax
        push    cx
        push    dx
        push    bx
        push    bp
        push    si
        push    di
        push    es
        mov     bp, sp
        mov     byte [BIOS_RETF_OFF], 0
        cld                             ; (les routines du pont utilisent STOSB/LODSB)
        sti                             ; les reponses du pont arrivent par l'ISR
%endmacro

; ------------------------------------------------------------
; bios_return: fin d'un service. BIOS_RETF_OFF: bit 0 = CF, bit 6 = ZF a renvoyer. Les registres
; a renvoyer ont ete ecrits dans le cadre. Restaure le cadre et la pile du programme, IRET.
; ------------------------------------------------------------
bios_return:
        cmp     byte [BIOS_TRC], 0      ; appel trace par bios_trace_in (meme si la trace a ete coupee depuis:
        je      .nt                     ; la ligne commencee est terminee)
        call    bios_trace_out
.nt:
        cli
        mov     es, [BIOS_SS_OFF]
        mov     bx, [BIOS_SP_OFF]
        mov     al, [BIOS_RETF_OFF]
        mov     ah, [es:bx + 6]         ; octet bas des indicateurs empiles par INT
        and     ah, 0BEh                ; efface CF (bit 0) et ZF (bit 6)
        or      ah, al
        mov     [es:bx + 6], ah
        pop     es
        pop     di
        pop     si
        pop     bp
        pop     bx
        pop     dx
        pop     cx
        pop     ax
        mov     sp, [BIOS_SP_OFF]
        mov     ss, [BIOS_SS_OFF]
        pop     ds
        iret

; bios_trace_in: AL = numero de l'INT; ecrit "<nn AX BX CX DX ES" (cadre BIOS: BP). bios_trace_out: "-AX CX DX CF" (+ pour
; INT 1Ah les 8 octets recus du pont). Preservent tous les registres. Servent a comparer les appels vus par le
; materiel et par le banc d'essai. (SS = VAR_SEG dans le BIOS: les variables s'adressent par SS:, DS reste libre.)
bios_trace_in:
        mov     [ss:BIOS_TRC], al       ; numero de l'INT tracee (bios_return: 0 = pas de trace)
        push    ds
        push    cs
        pop     ds
        push    ax
        push    bx
        push    ax
        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte
        mov     al, '<'
        call    uart_tx_byte
        pop     ax
        call    uart_tx_hex_byte
        mov     al, ' '
        call    uart_tx_byte
        mov     ax, [bp + FR_AX]
        call    uart_tx_hex_word
        mov     al, ' '
        call    uart_tx_byte
        mov     ax, [bp + FR_BX]
        call    uart_tx_hex_word
        mov     al, ' '
        call    uart_tx_byte
        mov     ax, [bp + FR_CX]
        call    uart_tx_hex_word
        mov     al, ' '
        call    uart_tx_byte
        mov     ax, [bp + FR_DX]
        call    uart_tx_hex_word
        mov     al, ' '
        call    uart_tx_byte
        mov     ax, [bp + FR_ES]
        call    uart_tx_hex_word
        pop     bx
        pop     ax
        pop     ds
%if BIOS_TRACE
        cmp     byte [ss:BIOS_TRC], 1Ah         ; 5e appel INT 1Ah AH=00 avec BX=0306 CX=0006 DX=0000: la lecture de l'heure
        jne     .nomm                           ; qui suit "Current date is" (memes 4 appels avant, sur le banc et le materiel)
        cmp     word [bp + FR_AX], 0
        jne     .nomm
        cmp     word [bp + FR_BX], 0306h
        jne     .nomm
        cmp     word [bp + FR_CX], 6
        jne     .nomm
        cmp     word [bp + FR_DX], 0
        jne     .nomm
        inc     word [ss:BIOS_TRC2]
        cmp     word [ss:BIOS_TRC2], 5
        jne     .nomm
        call    bios_memmap
.nomm:
%endif
        ret

%if BIOS_TRACE
; bios_memmap: carte de la RAM (128 Ko): une ligne "Mbbbb: s s s ..." par 16 blocs de 256 octets; s = somme de controle du bloc
; (SOMME = rol(SOMME,1) xor mot, sur les 128 mots). A comparer avec le banc d'essai au meme point du programme.
bios_memmap:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    ds
        xor     dx, dx                  ; DX = numero de bloc (0-511)
.row:
        push    cs
        pop     ds
        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte
        mov     al, 'M'
        call    uart_tx_byte
        mov     ax, dx
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     cx, 16
.blk:
        push    cx
        mov     ax, dx
        mov     cl, 4
        shl     ax, cl                  ; segment du bloc = numero * 16
        mov     ds, ax
        xor     si, si
        xor     bx, bx
        mov     cx, 128
.w:
        lodsw
        rol     bx, 1
        xor     bx, ax
        loop    .w
        pop     cx
        push    cs
        pop     ds
        mov     al, ' '
        call    uart_tx_byte
        mov     ax, bx
        call    uart_tx_hex_word
        inc     dx
        loop    .blk
        cmp     dx, 512
        jb      .row
        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte
        pop     ds
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
%endif

bios_trace_out:
        push    ds
        push    ax
        push    bx
        push    cx
        push    si
        push    cs
        pop     ds
        mov     al, '-'
        call    uart_tx_byte
        mov     ax, [bp + FR_AX]
        call    uart_tx_hex_word
        mov     al, ' '
        call    uart_tx_byte
        mov     ax, [bp + FR_CX]
        call    uart_tx_hex_word
        mov     al, ' '
        call    uart_tx_byte
        mov     ax, [bp + FR_DX]
        call    uart_tx_hex_word
        mov     al, ' '
        call    uart_tx_byte
        mov     al, [ss:BIOS_RETF_OFF]
        and     al, 1
        add     al, '0'
        call    uart_tx_byte
        cmp     byte [ss:BIOS_TRC], 1Ah
        jne     .nr
        mov     al, ' '
        call    uart_tx_byte
        mov     si, BIOS_RTC_OFF        ; octets bruts de la RTC du pont (annee lo/hi, mois, jour, h, min, s, cs)
        mov     cx, 8
.r:
        mov     al, [ss:si]
        call    uart_tx_hex_byte
        inc     si
        loop    .r
.nr:
        mov     al, '>'
        call    uart_tx_byte
        mov     byte [ss:BIOS_TRC], 0
        pop     si
        pop     cx
        pop     bx
        pop     ax
        pop     ds
        ret

; bios_dot: un '.' sur l'UART par lecture INT 13h pendant l'amorcage (BIOS_DOTS, pose par int19h_handler,
; retire au premier affichage du DOS: bios_dots_end). Pas de point si la trace est active (ses lignes
; montrent deja la progression). DS = VAR_SEG. Preserve tout.
bios_dot:
        cmp     byte [BIOS_DOTS], 0
        je      .r
        cmp     byte [BIOS_TRC_ON], 0
        jne     .r
        push    ax
        mov     al, '.'
        call    uart_tx_byte
        pop     ax
.r:
        ret

; bios_dots_end: fin des points de progression (premier INT 10h du DOS, ou echec de l'amorcage): passe
; a la ligne si des points etaient affiches. Independante de DS. Preserve tout.
bios_dots_end:
        push    ds
        push    ax
        mov     ax, VAR_SEG
        mov     ds, ax
        cmp     byte [BIOS_DOTS], 0
        je      .r
        mov     byte [BIOS_DOTS], 0
        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte
.r:
        pop     ax
        pop     ds
        ret

; bios_flags_cf: CF -> BIOS_RETF_OFF bit 0 (les MOV ne modifient pas les indicateurs)
bios_ret_cf:
        mov     byte [BIOS_RETF_OFF], 0
        jnc     .r
        mov     byte [BIOS_RETF_OFF], 1
.r:
        jmp     bios_return

; ------------------------------------------------------------
; INT 11h (equipement: 1 disquette si une image est montee) et INT 12h (memoire): utilisables sur n'importe quelle pile
; ------------------------------------------------------------
int11h_handler:
        push    ds
        mov     ax, VAR_SEG
        mov     ds, ax
        mov     ax, 0220h               ; pas de disquette, 1 port serie, video 80x25
        cmp     byte [BIOS_FLOP_OFF], 0
        je      .r
        mov     ax, 0221h               ; une image montee = 1 lecteur de disquette
.r:
        pop     ds
        iret

int12h_handler:
        mov     ax, BIOS_MEM_KB
        iret

; INT 14h (serie) et INT 17h (imprimante): absents ("delai depasse")
int14h_handler:
        mov     ah, 80h
        iret

int17h_handler:
        mov     ah, 01h
        iret

; INT 15h: services systeme. AH=88h: memoire etendue (aucune). Autres: non geres (CF = 1, AH = 86h)
int15h_handler:
        cmp     ah, 88h
        jne     .no
        xor     ax, ax
        push    bp
        mov     bp, sp
        and     word [bp + 6], 0FFFEh   ; CF = 0 dans les indicateurs empiles
        pop     bp
        iret
.no:
        mov     ah, 86h
        push    bp
        mov     bp, sp
        or      word [bp + 6], 1        ; CF = 1
        pop     bp
        iret

; ------------------------------------------------------------
; INT 13h - disque. DL = 80h: le disque dur (la flash du pont). DL = 0: la DISQUETTE A: quand une image est
; montee (fichier .IMG de la flash, voir AH = F0h): geometrie deduite de la taille du fichier (160, 180, 320,
; 360, 720 Ko, 1,2 ou 1,44 Mo). Fonctions de disque dur et de disquette: 00h reinitialisation, 01h etat,
; 02h/03h/04h lecture/ecriture/verification CHS, 05h formatage (ignore), 08h parametres, 15h type,
; 16h changement de disquette (jamais). Disque dur seulement: acces etendu 41h/42h/43h/44h/48h (LBA 32 bits).
; Fonctions PROPRES a ce projet: AH = F0h MONTER l'image DS:SI (nom, zero final) -> AH = etat (0 = OK), CX:DX =
; taille; AH = F1h DEMONTER.
; ------------------------------------------------------------
; Etats renvoyes dans AH (CF = 1 si <> 0)
BIOSD_OK        equ     00h
BIOSD_BADCMD    equ     01h
BIOSD_NOTFOUND  equ     04h
BIOSD_TIMEOUT   equ     80h
BIOSD_NOTREADY  equ     0AAh
BIOSD_FAIL      equ     20h
; AH = F0h: 0E0h + etat du pont (0E1h pas de disque, 0E2h fichier introuvable, 0E5h nom invalide...); 0EFh = taille
; d'image non reconnue
BIOSM_BADSIZE   equ     0EFh

int13h_handler:
        BIOS_ENTER
        BIOS_FRAME
        cmp     byte [BIOS_TRC_ON], 0   ; trace basculee par Ctrl-] / Ctrl-Echap (lib/isr.asm)
        je      .trc_skip
        mov     al, 13h
        call    bios_trace_in
.trc_skip:
%if BIOS_HIDE_HD
        cmp     byte [bp + FR_DX], 80h  ; DL >= 80h: pas de disque dur pour le DOS (AH=01: fonction invalide)
        jb      .hd_ok
        cmp     byte [bp + FR_ALH], 0F0h
        jae     .hd_ok                  ; (F0h/F1h = montage d'image, DL sans objet)
        mov     byte [bp + FR_ALH], 01h
        mov     byte [BIOS_RETF_OFF], 1
        jmp     bios_return
.hd_ok:
%endif
        mov     ah, [bp + FR_ALH]       ; fonction (AH d'origine)
        cmp     ah, 0F0h
        je      .mount
        cmp     ah, 0F1h
        je      .umount
        cmp     ah, 41h
        jae     .ext
        cmp     ah, 00h
        je      .reset
        cmp     ah, 01h
        je      .getstat
        cmp     ah, 08h
        je      .params
        cmp     ah, 15h
        je      .dtype
        cmp     ah, 05h                 ; formatage d'une piste (ignore)
        je      .ok_only
        cmp     ah, 0Ch                 ; recherche de cylindre (ignoree)
        je      .ok_only
        cmp     ah, 0Dh                 ; reinitialisation des controleurs
        je      .ok_only
        cmp     ah, 10h                 ; unite prete?
        je      .ok_only
        cmp     ah, 11h                 ; recalibrage
        je      .ok_only
        cmp     ah, 16h                 ; changement de disquette: non
        je      .ok_only
        cmp     ah, 02h
        je      .chs_read
        cmp     ah, 03h
        je      .chs_write
        cmp     ah, 04h
        je      .chs_verify
        jmp     .badcmd

.ext:
        cmp     ah, 41h
        je      .extchk
        cmp     ah, 42h
        je      .ext_read
        cmp     ah, 43h
        je      .ext_write
        cmp     ah, 44h
        je      .ext_verify
        cmp     ah, 48h
        je      .extparams
        jmp     .badcmd

; --- retours communs ---
.ok_only:
        call    .drive
        jmp     .status
.badcmd:
        mov     ah, BIOSD_BADCMD
.status:                                ; AH = etat -> AH du cadre, CF = (AH <> 0)
        mov     [bp + FR_ALH], ah
        mov     [BIOS_STAT_OFF], ah
        or      ah, ah
        jz      .cf0
        mov     byte [BIOS_RETF_OFF], 1
.cf0:
        jmp     bios_return

; .drive: choisit le lecteur DL du cadre. Retour AH = 0 (BIOS_DRV_OFF, BIOS_GH_OFF, BIOS_GS_OFF poses) ou l'etat
; d'erreur (disquette absente: 80h; disque dur inexistant: 01h). Detruit AL, DL.
.drive:
        mov     dl, [bp + FR_DX]
        cmp     dl, 80h
        je      .d_hd
        ja      .d_bad
        or      dl, dl                  ; 0 = A:
        jnz     .d_none
        cmp     byte [BIOS_FLOP_OFF], 0
        je      .d_none
        mov     byte [BIOS_DRV_OFF], 1
        mov     al, [BIOS_FHEADS_OFF]
        xor     ah, ah
        mov     [BIOS_GH_OFF], ax
        mov     al, [BIOS_FSPT_OFF]
        xor     ah, ah
        mov     [BIOS_GS_OFF], ax
        ret                             ; AH = 0
.d_hd:
        mov     byte [BIOS_DRV_OFF], 0
        mov     word [BIOS_GH_OFF], BIOS_HEADS
        mov     word [BIOS_GS_OFF], BIOS_SEC_PER_TRACK
        xor     ah, ah
        ret
.d_none:
        mov     ah, BIOSD_TIMEOUT       ; disquette absente: delai depasse
        ret
.d_bad:
        mov     ah, BIOSD_BADCMD        ; disque dur inexistant
        ret

.reset:
        call    .drive
        jmp     .status

.getstat:
        mov     ah, [BIOS_STAT_OFF]
        mov     [bp + FR_ALH], ah
        mov     byte [BIOS_STAT_OFF], 0
        jmp     bios_return

; --- AH=08h: parametres du lecteur ---
.params:
        call    .drive
        or      ah, ah
        jnz     .status
        cmp     byte [BIOS_DRV_OFF], 1
        je      .params_fl
        call    bios_nsec               ; DX:AX = nombre de secteurs (0 = pas de disque)
        jc      .tmo
        mov     bx, ax
        or      bx, dx
        jz      .nodisk
        call    bios_cylmax             ; AX = dernier cylindre (0-1023)
        mov     [bp + FR_CX + 1], al    ; CH = cylindre, bits 0-7
        mov     bl, ah
        and     bl, 3
        mov     cl, 6
        shl     bl, cl                  ; bits 6-7 de CL = bits 8-9 du cylindre
        or      bl, BIOS_SEC_PER_TRACK
        mov     [bp + FR_CX], bl        ; CL = secteurs par piste + cylindre haut
        mov     byte [bp + FR_DX + 1], BIOS_HEADS - 1   ; DH = derniere tete
        mov     byte [bp + FR_DX], 1    ; DL = nombre de disques durs
        mov     byte [bp + FR_BX], 0    ; BL = type
        xor     ah, ah
        jmp     .status
.params_fl:                             ; disquette
        mov     ax, [BIOS_FCYL_OFF]
        dec     ax
        mov     [bp + FR_CX + 1], al    ; CH = dernier cylindre
        mov     al, [BIOS_FSPT_OFF]
        mov     [bp + FR_CX], al        ; CL = secteurs par piste
        mov     al, [BIOS_FHEADS_OFF]
        dec     al
        mov     [bp + FR_DX + 1], al    ; DH = derniere tete
        mov     byte [bp + FR_DX], 1    ; DL = un lecteur
        mov     al, [BIOS_FTYPE_OFF]
        mov     [bp + FR_BX], al        ; BL = type de lecteur
        mov     word [bp + FR_DI], bios_dpt     ; ES:DI = table des parametres de disquette (en ROM)
        mov     [bp + FR_ES], cs
        xor     ah, ah
        jmp     .status
.tmo:
        mov     ah, BIOSD_TIMEOUT
        jmp     .status
.nodisk:
        mov     ah, BIOSD_NOTREADY
        jmp     .status

; --- AH=15h: type de disque ---
.dtype:
        call    .drive
        or      ah, ah
        jnz     .status
        cmp     byte [BIOS_DRV_OFF], 1
        jne     .dtype_hd
        mov     byte [bp + FR_ALH], 1   ; AH = 1: disquette sans detection de changement
        mov     byte [BIOS_STAT_OFF], 0
        jmp     bios_return
.dtype_hd:
        call    bios_nsec
        jc      .tmo
        mov     [bp + FR_CX], dx        ; CX:DX = nombre de secteurs
        mov     [bp + FR_DX], ax
        mov     byte [bp + FR_ALH], 3   ; AH = 3: disque fixe (pas de CF)
        mov     byte [BIOS_STAT_OFF], 0
        jmp     bios_return

; --- AH=02h/03h/04h: lecture / ecriture / verification CHS ---
.chs_read:
        call    bios_dot                ; progression de l'amorcage (BIOS_DOTS)
        xor     bx, bx
        jmp     .chs_rw
.chs_write:
        mov     bx, 1
        jmp     .chs_rw
.chs_verify:
        mov     bx, 2
.chs_rw:
        call    .drive
        or      ah, ah
        jnz     .status
        mov     [BIOS_OP_OFF], bl       ; 0 lecture, 1 ecriture, 2 verification
        mov     cx, [bp + FR_CX]
        mov     dx, [bp + FR_DX]
        call    bios_chs_lba            ; DX:AX = LBA
        jc      .nf
        mov     [BIOS_LBA_OFF], ax
        mov     [BIOS_LBA_OFF + 2], dx
        mov     cl, [bp + FR_AX]        ; AL = nombre de secteurs
        xor     ch, ch
        mov     di, [bp + FR_BX]        ; tampon ES:BX (ES = ES d'origine, encore vivant)
        mov     si, di
        call    bios_xfer               ; AH = etat, CX = secteurs faits
        mov     [bp + FR_AX], cl        ; AL = secteurs transferes
        jmp     .status
.nf:
        mov     byte [bp + FR_AX], 0    ; AL = 0 secteur transfere
        mov     ah, BIOSD_NOTFOUND
        jmp     .status

; --- acces etendu (disque dur seulement) ---
.extchk:
        call    .drive
        or      ah, ah
        jnz     .status
        cmp     byte [BIOS_DRV_OFF], 0
        jne     .badcmd
        cmp     word [bp + FR_BX], 55AAh
        jne     .badcmd
        mov     word [bp + FR_BX], 0AA55h
        mov     byte [bp + FR_ALH], 21h ; version 2.1
        mov     word [bp + FR_CX], 1    ; acces etendu par paquet (DAP)
        mov     byte [BIOS_STAT_OFF], 0
        jmp     bios_return

.ext_read:
        call    bios_dot
        xor     bx, bx
        jmp     .ext_rw
.ext_write:
        mov     bx, 1
        jmp     .ext_rw
.ext_verify:
        mov     bx, 2
.ext_rw:
        call    .drive
        or      ah, ah
        jnz     .status
        cmp     byte [BIOS_DRV_OFF], 0
        jne     .badcmd
        mov     [BIOS_OP_OFF], bl
        ; DS d'origine (sur la pile du programme) -> ES; DAP = ES:SI (SI d'origine, encore vivant)
        push    es
        mov     es, [BIOS_SS_OFF]
        mov     bx, [BIOS_SP_OFF]
        mov     ax, [es:bx]             ; DS du programme
        pop     es
        mov     es, ax
        cmp     byte [es:si], 10h       ; taille du paquet >= 16
        jb      .badcmd
        cmp     word [es:si + 12], 0    ; LBA de 32 bits seulement
        jne     .nf
        cmp     word [es:si + 14], 0
        jne     .nf
        mov     ax, [es:si + 8]
        mov     [BIOS_LBA_OFF], ax
        mov     ax, [es:si + 10]
        mov     [BIOS_LBA_OFF + 2], ax
        mov     cx, [es:si + 2]         ; nombre de secteurs
        mov     di, [es:si + 4]         ; tampon (deplacement)
        mov     ax, [es:si + 6]         ; tampon (segment)
        mov     es, ax
        mov     si, di
        call    bios_xfer
        jmp     .status

.extparams:
        call    .drive
        or      ah, ah
        jnz     .status
        cmp     byte [BIOS_DRV_OFF], 0
        jne     .badcmd
        ; tampon de resultat DS:SI (DS d'origine): taille 1Ah
        push    es
        mov     es, [BIOS_SS_OFF]
        mov     bx, [BIOS_SP_OFF]
        mov     ax, [es:bx]
        pop     es
        mov     es, ax
        call    bios_nsec
        jc      .tmo
        mov     word [es:si], 1Ah
        mov     word [es:si + 2], 0     ; indicateurs
        mov     [BIOS_LBA_OFF], ax      ; (reutilise comme variables locales)
        mov     [BIOS_LBA_OFF + 2], dx
        call    bios_cylmax
        inc     ax
        mov     [es:si + 4], ax         ; cylindres
        mov     word [es:si + 6], 0
        mov     word [es:si + 8], BIOS_HEADS
        mov     word [es:si + 10], 0
        mov     word [es:si + 12], BIOS_SEC_PER_TRACK
        mov     word [es:si + 14], 0
        mov     ax, [BIOS_LBA_OFF]
        mov     [es:si + 16], ax        ; secteurs au total (64 bits)
        mov     ax, [BIOS_LBA_OFF + 2]
        mov     [es:si + 18], ax
        mov     word [es:si + 20], 0
        mov     word [es:si + 22], 0
        mov     word [es:si + 24], 512  ; octets par secteur
        xor     ah, ah
        jmp     .status

; --- AH=F0h: monter l'image de disquette DS:SI (le nom est dans le DS de l'appelant) ---
.mount:
        mov     es, [BIOS_SS_OFF]
        mov     bx, [BIOS_SP_OFF]
        mov     ax, [es:bx]             ; DS du programme
        mov     es, ax
        mov     di, BIOS_NAME_OFF
        xor     cx, cx
.cp:
        mov     al, [es:si]
        mov     [di], al
        inc     si
        inc     di
        inc     cx
        or      al, al
        jz      .cpd
        cmp     cx, 13
        jb      .cp
        mov     byte [di - 1], 0        ; nom trop long: tronque (le pont refusera un nom de plus de 12 caracteres)
.cpd:
        push    ds
        pop     es
        mov     si, BIOS_NAME_OFF
        call    fs_img_mount            ; AL = etat, DX:CX = taille
        jc      .tmo
        or      al, al
        jnz     .mnterr
        call    bios_img_geom           ; geometrie d'apres la taille; CF = 1: non reconnue
        jc      .badsize
        mov     byte [BIOS_FLOP_OFF], 1
        mov     [bp + FR_CX], dx        ; CX:DX = taille en octets (poids fort dans CX)
        mov     [bp + FR_DX], cx
        mov     ax, 0221h               ; equipement: 1 disquette
        call    bios_equip
        xor     ah, ah
        jmp     .status
.mnterr:
        or      al, 0E0h
        mov     ah, al
        jmp     .status
.badsize:
        call    fs_img_umount           ; taille inconnue: on ne garde pas l'image
        mov     ah, BIOSM_BADSIZE
        jmp     .status

.umount:
        call    fs_img_umount
        mov     byte [BIOS_FLOP_OFF], 0
        mov     ax, 0220h
        call    bios_equip
        xor     ah, ah
        jmp     .status

; bios_equip: AX = mot d'equipement -> zone de donnees du BIOS 0040:0010. Detruit ES.
bios_equip:
        push    ds
        xor     bx, bx
        mov     ds, bx
        mov     [0410h], ax
        pop     ds
        ret

; bios_img_geom: DX:CX = taille de l'image -> BIOS_FCYL/FHEADS/FSPT/FTYPE. CF = 1: taille non reconnue.
bios_img_geom:
        mov     bx, bios_flop_types
.l:
        cmp     word [cs:bx], 0
        jne     .c
        cmp     word [cs:bx + 2], 0
        je      .none
.c:
        cmp     cx, [cs:bx]
        jne     .n
        cmp     dx, [cs:bx + 2]
        jne     .n
        mov     ax, [cs:bx + 4]
        mov     [BIOS_FCYL_OFF], ax
        mov     al, [cs:bx + 6]
        mov     [BIOS_FHEADS_OFF], al
        mov     al, [cs:bx + 7]
        mov     [BIOS_FSPT_OFF], al
        mov     al, [cs:bx + 8]
        mov     [BIOS_FTYPE_OFF], al
        clc
        ret
.n:
        add     bx, 9
        jmp     .l
.none:
        stc
        ret

; images de disquette reconnues (taille, cylindres, tetes, secteurs par piste, type INT 13h AH=08h); fin: 0
bios_flop_types:
        dd      163840
        dw      40
        db      1, 8, 1                 ; 160 Ko
        dd      184320
        dw      40
        db      1, 9, 1                 ; 180 Ko
        dd      327680
        dw      40
        db      2, 8, 1                 ; 320 Ko
        dd      368640
        dw      40
        db      2, 9, 1                 ; 360 Ko
        dd      737280
        dw      80
        db      2, 9, 3                 ; 720 Ko
        dd      1228800
        dw      80
        db      2, 15, 2                ; 1,2 Mo
        dd      1474560
        dw      80
        db      2, 18, 4                ; 1,44 Mo
        dd      0

; table des parametres de disquette (INT 1Eh): 11 octets, valeurs du BIOS d'origine (360 Ko)
bios_dpt:
        db      0DFh, 02h, 25h, 02h, 09h, 2Ah, 0FFh, 50h, 0F6h, 0Fh, 02h

; bios_xfer: BIOS_OP_OFF (0 lecture, 1 ecriture, 2 verification), BIOS_DRV_OFF (0 disque dur, 1 image de
; disquette), CX = nombre de secteurs, ES:DI (lecture) ou ES:SI (ecriture) = tampon, LBA dans BIOS_LBA_OFF
; (dword). Retour: AH = etat INT 13h, CX = secteurs faits. Detruit AX, DX.
bios_xfer:
        mov     word [BIOS_DONE_OFF], 0
        mov     byte [BIOS_TRY], 0
.n:
        or      cx, cx
        jz      .ok
        mov     al, [BIOS_OP_OFF]
        cmp     al, 2
        je      .vf
        mov     ax, [BIOS_LBA_OFF]
        mov     dx, [BIOS_LBA_OFF + 2]
        cmp     byte [BIOS_OP_OFF], 0
        jne     .w
        cmp     byte [BIOS_DRV_OFF], 0
        jne     .ir
        call    fs_sec_read             ; AL = etat du pont, CF = delai
        jmp     .r
.ir:
        call    fs_img_read
        jmp     .r
.w:
        cmp     byte [BIOS_DRV_OFF], 0
        jne     .iw
        call    fs_sec_write
        jmp     .r
.iw:
        call    fs_img_write
.r:
        jc      .to
        or      al, al
        jnz     .err
        cmp     byte [BIOS_OP_OFF], 0
        jne     .vf
        call    bios_patch_sector       ; lecture: neutralise les OUT parasites du code lu
.vf:
        mov     byte [BIOS_TRY], 0      ; secteur suivant: on repart a zero tentative
        add     word [BIOS_LBA_OFF], 1
        adc     word [BIOS_LBA_OFF + 2], 0
        inc     word [BIOS_DONE_OFF]
        dec     cx
        jmp     .n
.ok:
        xor     ah, ah
        jmp     .done
.to:
        mov     ah, BIOSD_TIMEOUT
        jmp     .done
.err:
        cmp     al, FSE_BADSUM
        je      .badsum
        mov     ah, BIOSD_NOTFOUND      ; FSE_IO (LBA hors du disque / de l'image...)
        cmp     al, 4
        je      .done
        mov     ah, BIOSD_NOTREADY      ; FSE_NOTREADY (USB ON: le PC a le disque)
        cmp     al, 1
        je      .done
        mov     ah, BIOSD_TIMEOUT       ; FSE_NOTOPEN (image demontee par le pont)
        cmp     al, 7
        je      .done
        mov     ah, BIOSD_FAIL
.badsum:                                ; somme de controle fausse: on relit le meme secteur (3 essais)
        inc     word [BIOS_BADSUM]
%if BIOS_SHOW_RETRY
        mov     al, '!'                 ; repere visible: une lecture a ete refaite
        call    uart_tx_byte
%endif
        inc     byte [BIOS_TRY]
        cmp     byte [BIOS_TRY], 3
        jae     .sumfail
        sub     di, 512                 ; la lecture a avance DI de 512: on le remet
        jmp     .n
.sumfail:
        mov     ah, BIOSD_FAIL          ; toujours fausse: erreur (le DOS l'affichera) plutot que des donnees fausses
.done:
        mov     cx, [BIOS_DONE_OFF]
        ret

; bios_patch_sector: ES:DI = fin du secteur de 512 octets qui vient d'etre lu. Le decodage d'adresses du 8255 est
; partiel (A7 = 1 suffit: 80h-0FFh, 180h-1FFh... tout le bloc d'E/S le selectionne), alors que sur un vrai PC ces ports
; n'existent pas: MS-DOS 3.30 (IO.SYS) ecrit 0FFh sur les ports 2F2h-2F7h ("mov dx,2F2h / out dx,al / inc dx" x6, puis
; idem en 2F6h) et cela reprogramme le 8255 (registre de mode = 0FFh, ports A/B/C ecrits) en plein amorcage: le pont
; est perdu et des interruptions parasites arrivent. On remplace donc chaque OUT (EEh) de ces deux suites par un NOP
; (90h) dans le secteur lu. Motif: BAh F2h {02h|06h} EEh puis une suite d'octets EEh/42h (OUT DX,AL / INC DX).
; Preserve tous les registres (BIOS_NPATCH compte les OUT neutralises).
bios_patch_sector:
        push    ax
        push    bx
        push    cx
        push    si
        push    di
        sub     di, 512                 ; debut du secteur (les offsets bouclent comme la lecture)
        mov     cx, 512
        cld
.f:
        mov     al, 0BAh                ; MOV DX, imm16
        repne   scasb
        jne     .end                    ; plus de BAh dans le secteur
        cmp     cx, 16                  ; il faut de la place pour le motif (jamais a cheval sur deux secteurs)
        jb      .end
        cmp     byte [es:di], 0F2h
        jne     .f
        mov     al, [es:di + 1]
        cmp     al, 02h                 ; ports 2F2h... ou 2F6h...
        je      .m
        cmp     al, 06h
        jne     .f
.m:
        cmp     byte [es:di + 2], 0EEh  ; ... suivi de OUT DX, AL
        jne     .f
        lea     si, [di + 2]
        mov     bx, 16                  ; au plus 16 octets de suite
.q:
        mov     al, [es:si]
        cmp     al, 42h                 ; INC DX: on garde
        je      .nx
        cmp     al, 0EEh                ; OUT DX, AL: NOP
        jne     .f
        mov     byte [es:si], 90h
        inc     word [BIOS_NPATCH]
%if BIOS_SHOW_PATCH
        mov     al, '+'
        call    uart_tx_byte
%endif
.nx:
        inc     si
        dec     bx
        jnz     .q
        jmp     .f
.end:
        pop     di
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

; bios_nsec: nombre de secteurs du disque -> DX:AX (mis en cache); CF = 1: le pont ne repond pas
bios_nsec:
        mov     ax, [BIOS_NSEC_OFF]
        mov     dx, [BIOS_NSEC_OFF + 2]
        mov     cx, ax
        or      cx, dx
        jnz     .ok
        push    es
        push    ds
        pop     es
        call    fs_sec_info             ; DX:AX
        pop     es
        jc      .r
        mov     cx, ax
        or      cx, dx
        jz      .ok                     ; 0: pas de disque (on ne le memorise pas)
        mov     [BIOS_NSEC_OFF], ax
        mov     [BIOS_NSEC_OFF + 2], dx
.ok:
        clc
.r:
        ret

; bios_cylmax: (DX:AX = secteurs) -> AX = dernier numero de cylindre (secteurs / 16065 arrondi vers le
; haut, moins 1), plafonne a 1023. Detruit BX, CX, DX.
bios_cylmax:
        mov     bx, 16065               ; 255 * 63
        ; quotient de DX:AX / BX
        mov     cx, ax
        mov     ax, dx
        xor     dx, dx
        div     bx                      ; AX = poids fort du quotient
        or      ax, ax
        jnz     .big
        mov     ax, cx
        div     bx                      ; AX = quotient, DX = reste (DX:CX / BX)
        or      dx, dx
        jz      .exact
        inc     ax                      ; arrondi vers le haut
.exact:
        dec     ax
        jns     .cap
        xor     ax, ax
.cap:
        cmp     ax, 1023
        jbe     .r
.big:
        mov     ax, 1023
.r:
        ret

; bios_chs_lba: CX = (CH cylindre bas, CL = bits 6-7 cylindre haut + secteur), DH = tete ->
; DX:AX = LBA = (cyl * tetes + tete) * secteurs_par_piste + secteur - 1, avec BIOS_GH_OFF / BIOS_GS_OFF (le
; lecteur choisi par .drive). CF = 1 si le secteur vaut 0 ou depasse la geometrie, si la tete est trop haute
; ou (disquette) si le cylindre est hors de l'image. Detruit BX, CX.
bios_chs_lba:
        mov     al, cl
        and     al, 3Fh
        jz      .bad
        cmp     al, [BIOS_GS_OFF]
        ja      .bad                    ; secteur > secteurs par piste
        mov     bl, al                  ; BL = secteur (1-63)
        cmp     dh, [BIOS_GH_OFF]
        jae     .bad                    ; tete >= nombre de tetes
        mov     bh, dh                  ; BH = tete
        mov     al, cl
        and     al, 0C0h
        mov     cl, 6
        shr     al, cl                  ; AL = bits 8-9 du cylindre
        mov     ah, al
        mov     al, ch                  ; AX = cylindre
        cmp     byte [BIOS_DRV_OFF], 0
        je      .go
        cmp     ax, [BIOS_FCYL_OFF]
        jae     .bad                    ; disquette: cylindre hors de l'image
.go:
        push    bx
        mov     cx, [BIOS_GH_OFF]
        mul     cx                      ; DX:AX = cyl * tetes
        pop     bx
        mov     cl, bh
        xor     ch, ch
        add     ax, cx
        adc     dx, 0                   ; + tete
        push    bx                      ; secteur
        push    ax                      ; poids faible
        mov     ax, dx
        mov     cx, [BIOS_GS_OFF]
        mul     cx                      ; AX = poids fort * secteurs par piste
        mov     bx, ax
        pop     ax
        mul     cx                      ; DX:AX = poids faible * secteurs par piste
        add     dx, bx
        pop     bx
        xor     bh, bh
        dec     bx                      ; secteur - 1
        add     ax, bx
        adc     dx, 0
        clc
        ret
.bad:
        stc
        ret

; ------------------------------------------------------------
; INT 1Ah - horloge (RTC du pont): AH=00h ticks, 02h/03h heure, 04h/05h date
; ------------------------------------------------------------
int1ah_handler:
        BIOS_ENTER
        BIOS_FRAME
        cmp     byte [BIOS_TRC_ON], 0
        je      .trc_skip
        mov     al, 1Ah
        call    bios_trace_in
.trc_skip:
        mov     ah, [bp + FR_ALH]
        cmp     ah, 00h
        je      .ticks
        cmp     ah, 02h
        je      .gettime
        cmp     ah, 04h
        je      .getdate
        cmp     ah, 03h
        je      .settime
        cmp     ah, 05h
        je      .setdate
        cmp     ah, 01h                 ; regler le compteur de ticks: sans objet (l'heure vient de la RTC)
        je      .okret
        mov     byte [BIOS_RETF_OFF], 1
        jmp     bios_return
.okret:
        jmp     bios_return

; lit l'heure du pont dans BIOS_RTC_OFF (8 octets); CF = 1 si muet
.rtc:
        push    es
        push    ds
        pop     es
        mov     di, BIOS_RTC_OFF
        call    rtc_get
        pop     es
        ret

.fail:
        mov     byte [BIOS_RETF_OFF], 1
        jmp     bios_return

.ticks:
        call    .rtc
        jc      .fail
        ; secondes du jour * 100 + centiemes -> DX:AX, puis * 91 / 500 (= 18,2 ticks/s)
        mov     al, [BIOS_RTC_OFF + 4]  ; heures
        xor     ah, ah
        mov     cx, 3600
        mul     cx                      ; DX:AX = h * 3600
        mov     bx, ax
        mov     si, dx
        mov     al, [BIOS_RTC_OFF + 5]  ; minutes
        xor     ah, ah
        mov     cx, 60
        mul     cx
        add     bx, ax
        adc     si, dx
        mov     al, [BIOS_RTC_OFF + 6]  ; secondes
        xor     ah, ah
        add     bx, ax
        adc     si, 0                   ; SI:BX = secondes du jour
        mov     ax, bx
        mov     dx, si
        mov     cx, 100
        ; DX:AX * 100 (32 bits)
        push    ax
        mov     ax, dx
        mul     cx
        mov     si, ax                  ; poids fort * 100 (bits 16-31)
        pop     ax
        mul     cx                      ; DX:AX = poids faible * 100
        add     dx, si
        mov     bl, [BIOS_RTC_OFF + 7]  ; centiemes
        xor     bh, bh
        add     ax, bx
        adc     dx, 0                   ; DX:AX = centiemes du jour
        ; * 91
        mov     cx, 91
        push    ax
        mov     ax, dx
        mul     cx
        mov     si, ax
        pop     ax
        mul     cx
        add     dx, si                  ; DX:AX = centiemes * 91
        ; / 500
        mov     bx, 500
        mov     cx, ax
        mov     ax, dx
        xor     dx, dx
        div     bx                      ; AX = quotient haut, DX = reste
        xchg    ax, cx                  ; CX = quotient haut, AX = poids faible
        div     bx                      ; AX = quotient bas
        mov     [bp + FR_DX], ax        ; DX = ticks bas
        mov     [bp + FR_CX], cx        ; CX = ticks haut
        mov     byte [bp + FR_AX], 0    ; AL = 0: pas de passage de minuit
        mov     bx, [BIOS_LASTTICK + 2] ; un compteur PLUS PETIT que la lecture precedente = minuit est passe
        cmp     cx, bx
        ja      .noroll
        jb      .roll
        cmp     ax, [BIOS_LASTTICK]
        jae     .noroll
.roll:
        mov     byte [bp + FR_AX], 1    ; AL = 1: le DOS incremente la date
.noroll:
        mov     [BIOS_LASTTICK], ax
        mov     [BIOS_LASTTICK + 2], cx
        jmp     bios_return

.gettime:
        call    .rtc
        jc      .fail
        mov     al, [BIOS_RTC_OFF + 4]
        call    bios_tobcd
        mov     [bp + FR_CX + 1], al    ; CH = heures
        mov     al, [BIOS_RTC_OFF + 5]
        call    bios_tobcd
        mov     [bp + FR_CX], al        ; CL = minutes
        mov     al, [BIOS_RTC_OFF + 6]
        call    bios_tobcd
        mov     [bp + FR_DX + 1], al    ; DH = secondes
        mov     byte [bp + FR_DX], 0    ; DL = heure d'ete: non
        jmp     bios_return

.getdate:
        call    .rtc
        jc      .fail
        mov     byte [bp + FR_CX + 1], 20h      ; CH = siecle (BCD): 20
        mov     ax, [BIOS_RTC_OFF]      ; annee (2000-2099)
        sub     ax, 2000
        call    bios_tobcd
        mov     [bp + FR_CX], al        ; CL = annee
        mov     al, [BIOS_RTC_OFF + 2]
        call    bios_tobcd
        mov     [bp + FR_DX + 1], al    ; DH = mois
        mov     al, [BIOS_RTC_OFF + 3]
        call    bios_tobcd
        mov     [bp + FR_DX], al        ; DL = jour
        jmp     bios_return

.settime:
        call    .rtc
        jc      .fail
        mov     al, [bp + FR_CX + 1]
        call    bios_frombcd
        mov     [BIOS_RTC_OFF + 4], al
        mov     al, [bp + FR_CX]
        call    bios_frombcd
        mov     [BIOS_RTC_OFF + 5], al
        mov     al, [bp + FR_DX + 1]
        call    bios_frombcd
        mov     [BIOS_RTC_OFF + 6], al
        jmp     .put

.setdate:
        call    .rtc
        jc      .fail
        mov     al, [bp + FR_CX + 1]    ; siecle
        call    bios_frombcd
        xor     ah, ah
        mov     cx, 100
        mul     cx
        mov     bx, ax
        mov     al, [bp + FR_CX]        ; annee
        call    bios_frombcd
        xor     ah, ah
        add     ax, bx
        mov     [BIOS_RTC_OFF], ax
        mov     al, [bp + FR_DX + 1]
        call    bios_frombcd
        mov     [BIOS_RTC_OFF + 2], al
        mov     al, [bp + FR_DX]
        call    bios_frombcd
        mov     [BIOS_RTC_OFF + 3], al
.put:
        mov     si, BIOS_RTC_OFF        ; annee (2), mois, jour, h, min, s: l'ordre de rtc_set
        call    rtc_set
        jmp     bios_return

; bios_tobcd: AL (0-99) -> AL en BCD. bios_frombcd: l'inverse.
bios_tobcd:
        xor     ah, ah
        mov     cl, 10
        div     cl                      ; AL = dizaines, AH = unites
        mov     cl, 4
        shl     al, cl
        or      al, ah
        ret

bios_frombcd:
        mov     ah, al
        and     al, 0Fh
        mov     cl, 4
        shr     ah, cl                  ; AH = dizaines
        push    bx
        mov     bl, al
        mov     al, ah
        mov     ah, 10
        mul     ah                      ; AX = dizaines * 10
        add     al, bl
        pop     bx
        ret

; ------------------------------------------------------------
; INT 16h - clavier: AH=00h/10h lire (bloquant), 01h/11h consulter (ZF = 1: rien), 02h/12h
; indicateurs. La source est le TERMINAL UART (octets bruts: minuscules, ponctuation, Ctrl-lettre;
; DEL = retour arriere; sequences ESC [ ... / ESC O ... = touches etendues, AL = 0). Le clavier PS/2
; n'est pas gere (le BASIC ne l'utilise pas non plus). La touche en attente (AH = scan code, AL = ASCII)
; est gardee dans BIOS_KEY_OFF/BIOS_KEYF_OFF pour que la consultation ne la consomme pas.
; ------------------------------------------------------------
int16h_handler:
        BIOS_ENTER
        BIOS_FRAME
        mov     ah, [bp + FR_ALH]
        and     ah, 0EFh                ; 10h/11h/12h = 00h/01h/02h
        cmp     ah, 02h
        je      .flags
        cmp     ah, 01h
        je      .peek
        or      ah, ah
        jnz     .bad
.read:
        call    bios_key                ; AX = touche (attend)
        mov     [bp + FR_AX], ax
        jmp     bios_return
.peek:
        call    bios_trykey
        jc      .none
        mov     [bp + FR_AX], ax
        jmp     bios_return             ; ZF = 0 (touche disponible)
.none:
        mov     byte [BIOS_RETF_OFF], 40h       ; ZF = 1
        jmp     bios_return
.flags:
        mov     byte [bp + FR_AX], 0    ; AL = indicateurs: aucun
        jmp     bios_return
.bad:
        mov     byte [BIOS_RETF_OFF], 1
        jmp     bios_return

; bios_trykey: touche disponible? -> CF = 0 et AX = touche (sans la consommer); CF = 1: rien
bios_trykey:
        cmp     byte [BIOS_KEYF_OFF], 0
        jne     .have
.uart:
        call    uart_rx_available       ; CF = 1: rien
        jc      .none
        call    uart_rx_byte            ; AL
        cmp     al, 1Bh
        je      .esc
        cmp     al, 7Fh
        jne     .plain
        mov     al, 8                   ; DEL -> retour arriere
.plain:
        call    bios_ascii_scan         ; AX = scan:ascii
.store:
        mov     [BIOS_KEY_OFF], ax
        mov     byte [BIOS_KEYF_OFF], 1
.have:
        mov     ax, [BIOS_KEY_OFF]
        clc
        ret
.none:
        stc
        ret
.esc:
        call    uart_wait_byte          ; octet suivant (delai court), CF = 1: Echap seul
        jc      .esc_alone
        cmp     al, '['
        je      .csi
        cmp     al, 'O'
        je      .ss3
        stc                             ; ESC + autre octet: ignore
        ret
.esc_alone:
        mov     ax, 011Bh
        jmp     .store
.csi:
        xor     bx, bx                  ; BL = premier parametre numerique
.csil:
        call    uart_wait_byte
        jc      .ignore
        cmp     al, 40h
        jae     .final
        cmp     al, '0'
        jb      .csil
        cmp     al, '9'
        ja      .csil
        sub     al, '0'
        mov     bl, al                  ; (un seul chiffre suffit: 1-6)
        jmp     .csil
.ss3:
        call    uart_wait_byte
        jc      .ignore
        xor     bx, bx
.final:
        mov     dx, bx                  ; DL = parametre
        mov     bx, bios_ext_keys
.f:
        cmp     byte [cs:bx], 0
        je      .ignore
        mov     ah, [cs:bx]
        cmp     al, ah                  ; octet final
        jne     .fn
        mov     ah, [cs:bx + 1]
        cmp     ah, 0FFh                ; 0FFh = tout parametre
        je      .fhit
        cmp     ah, dl
        je      .fhit
.fn:
        add     bx, 3
        jmp     .f
.fhit:
        mov     ah, [cs:bx + 2]         ; scan code de la touche etendue
        xor     al, al
        jmp     .store
.ignore:
        stc
        ret

; touches etendues: octet final, parametre (0FFh = tout), scan code; fin 0
bios_ext_keys:
        db      'A', 0FFh, 48h          ; haut
        db      'B', 0FFh, 50h          ; bas
        db      'C', 0FFh, 4Dh          ; droite
        db      'D', 0FFh, 4Bh          ; gauche
        db      'H', 0FFh, 47h          ; debut
        db      'F', 0FFh, 4Fh          ; fin
        db      '~', 1, 47h             ; debut
        db      '~', 2, 52h             ; inser
        db      '~', 3, 53h             ; suppr
        db      '~', 4, 4Fh             ; fin
        db      '~', 5, 49h             ; page haut
        db      '~', 6, 51h             ; page bas
        db      'P', 0FFh, 3Bh          ; F1 (ESC O P)
        db      'Q', 0FFh, 3Ch          ; F2
        db      'R', 0FFh, 3Dh          ; F3
        db      'S', 0FFh, 3Eh          ; F4
        db      0

; bios_key: attend une touche et la consomme -> AX
bios_key:
.w:
        call    bios_trykey
        jc      .w
        mov     byte [BIOS_KEYF_OFF], 0
        ret

; bios_ascii_scan: AL = ASCII -> AX = scan code (approximatif, clavier QWERTY) : ASCII
bios_ascii_scan:
        mov     ah, 0
        cmp     al, 0Dh
        jne     .n1
        mov     ah, 1Ch
        ret
.n1:
        cmp     al, 08h
        jne     .n2
        mov     ah, 0Eh
        ret
.n2:
        cmp     al, 09h
        jne     .n3
        mov     ah, 0Fh
        ret
.n3:
        cmp     al, 20h
        jne     .n4
        mov     ah, 39h
        ret
.n4:
        push    bx
        cmp     al, '1'
        jb      .l
        cmp     al, '9'
        ja      .zero
        mov     ah, al
        sub     ah, '1' - 02h           ; '1' = 02h ... '9' = 0Ah
        jmp     .r
.zero:
        cmp     al, '0'
        jne     .l
        mov     ah, 0Bh
        jmp     .r
.l:
        mov     bl, al                  ; lettre (majuscule, minuscule ou Ctrl-lettre 01h-1Ah)?
        cmp     bl, 'a'
        jb      .up
        cmp     bl, 'z'
        ja      .r
        sub     bl, 'a' - 'A'
.up:
        cmp     bl, 'A'
        jb      .ctl
        cmp     bl, 'Z'
        ja      .r
        sub     bl, 'A'
        jmp     .lookup
.ctl:
        cmp     bl, 1
        jb      .r
        cmp     bl, 1Ah
        ja      .r
        dec     bl                      ; Ctrl-A = 01h -> lettre 0
.lookup:
        xor     bh, bh
        mov     ah, [cs:bios_scan_az + bx]
.r:
        pop     bx
        ret

; scan codes des lettres A-Z (clavier QWERTY)
bios_scan_az:
        db      1Eh, 30h, 2Eh, 20h, 12h, 21h, 22h, 23h, 17h, 24h, 25h, 26h, 32h
        db      31h, 18h, 19h, 10h, 13h, 1Fh, 14h, 16h, 2Fh, 11h, 2Dh, 15h, 2Ch

; ------------------------------------------------------------
; INT 19h - amorcage: lit le secteur 0 (MBR) de la flash, en tire la partition active (ou la
; premiere partition FAT), charge son premier secteur en 0000:7C00 et l'execute avec DL = 80h.
; Si le secteur 0 n'a pas de table de partitions (jmp EB/E9 + BPB), il est lui-meme le secteur
; d'amorcage. Ne revient que sur ECHEC (CF = 1, message sur l'UART).
; ------------------------------------------------------------
int19h_handler:
        BIOS_ENTER
        BIOS_FRAME
        cmp     byte [BIOS_FLOP_OFF], 0
        jne     .floppy
        mov     si, bios_msg_boot
        call    bios_puts
        mov     byte [BIOS_DOTS], 1     ; un '.' par lecture INT 13h jusqu'au premier affichage du DOS
        ; --- secteur 0 -> 0000:7C00 ---
        xor     ax, ax
        mov     es, ax
        mov     di, 7C00h
        xor     dx, dx                  ; LBA 0
        call    fs_sec_read
        jc      .tmo
        or      al, al
        jnz     .nodisk
        cmp     word [es:7DFEh], 0AA55h
        jne     .nosig
        ; --- table de partitions: entree active, sinon la premiere entree FAT ---
        mov     bx, 7C00h + 1BEh
        mov     cx, 4
        xor     si, si                  ; SI = premiere entree FAT vue
.p:
        mov     al, [es:bx + 4]         ; type
        cmp     al, 01h
        je      .fat
        cmp     al, 04h
        je      .fat
        cmp     al, 06h
        je      .fat
        cmp     al, 0Bh
        je      .fat
        cmp     al, 0Ch
        je      .fat
        cmp     al, 0Eh
        jne     .nextp
.fat:
        test    byte [es:bx], 80h
        jnz     .found
        or      si, si
        jnz     .nextp
        mov     si, bx
.nextp:
        add     bx, 16
        loop    .p
        or      si, si
        jz      .super                  ; aucune partition: le secteur 0 est peut-etre l'amorce
        mov     bx, si
.found:
        mov     ax, [es:bx + 8]         ; LBA de depart (32 bits)
        mov     dx, [es:bx + 10]
        mov     di, 7C00h
        call    fs_sec_read             ; le VBR ecrase le MBR en 0000:7C00
        jc      .tmo
        or      al, al
        jnz     .nodisk
        cmp     word [es:7DFEh], 0AA55h
        jne     .nosig
.go:
        mov     bl, 80h
.jump:
        ; --- saut a l'amorce: DL = BL (80h disque dur, 0 disquette), DS = ES = 0, pile 0000:7C00, interruptions ---
        cli
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 7C00h
        mov     dl, bl
        sti
        jmp     0000h:7C00h
.floppy:
        ; --- image montee: on amorce la DISQUETTE A: (secteur 0 de l'image, sans signature 55AA exigee: les
        ; disquettes DOS 1.x-2.x n'en portent pas toujours) ---
        mov     si, bios_msg_bootA
        call    bios_puts
        mov     byte [BIOS_DOTS], 1
        xor     ax, ax
        mov     es, ax
        mov     di, 7C00h
        xor     dx, dx                  ; LBA 0
        call    fs_img_read
        jc      .tmo
        or      al, al
        jnz     .nodisk
        xor     bl, bl                  ; DL = 0
        jmp     .jump
.super:
        cmp     byte [es:7C00h], 0EBh   ; pas de table: le secteur 0 est-il lui-meme une amorce?
        je      .go
        cmp     byte [es:7C00h], 0E9h
        je      .go
.nosig:
        mov     si, bios_msg_nosig
        jmp     .fail
.nodisk:
        mov     si, bios_msg_nodisk
        jmp     .fail
.tmo:
        mov     si, bios_msg_tmo
.fail:
        call    bios_dots_end           ; (points deja affiches: nouvelle ligne pour le message)
        call    bios_puts
        mov     byte [BIOS_RETF_OFF], 1
        jmp     bios_return

; bios_puts: chaine ROM (CS:SI, zero final) -> UART (etat de la pile independant)
bios_puts:
        push    ax
        push    si
.l:
        mov     al, [cs:si]
        or      al, al
        jz      .r
        call    uart_tx_byte
        inc     si
        jmp     .l
.r:
        pop     si
        pop     ax
        ret

; ---- Bilinguisme FR/EN (Manifest.md, meme mecanisme que
; ---- solution-01.asm - voir sa section donnees): ces messages
; ---- etaient DEJA en anglais uniquement (aucune version francaise
; ---- n'existait) - desormais dupliques, anglais dans %ifdef LANG_EN,
; ---- francais par defaut (%else), memes etiquettes ----
%ifdef LANG_EN
bios_msg_boot:  db      13, 10, 'Boot: flash disk...  (Ctrl-\ = back to the menu)', 13, 10, 0
bios_msg_bootA: db      13, 10, 'Boot: floppy image (A:)...  (Ctrl-\ = back to the menu)', 13, 10, 0
bios_msg_nosig: db      'Boot: no boot signature (55AA)', 13, 10, 0
bios_msg_nodisk: db     'Boot: disk not ready / read error', 13, 10, 0
bios_msg_tmo:   db      'Boot: bridge does not answer', 13, 10, 0
%else
bios_msg_boot:  db      13, 10, 'Amorce: disque flash...  (Ctrl-\ = retour au menu)', 13, 10, 0
bios_msg_bootA: db      13, 10, 'Amorce: image disquette (A:)...  (Ctrl-\ = retour au menu)', 13, 10, 0
bios_msg_nosig: db      'Amorce: signature de demarrage absente (55AA)', 13, 10, 0
bios_msg_nodisk: db     'Amorce: disque non pret / erreur de lecture', 13, 10, 0
bios_msg_tmo:   db      'Amorce: le pont ne repond pas', 13, 10, 0
%endif

; bios_puts_ds: chaine en RAM (DS:SI, zero final) -> UART
bios_puts_ds:
        push    ax
        push    si
.l:
        mov     al, [si]
        or      al, al
        jz      .r
        call    uart_tx_byte
        inc     si
        jmp     .l
.r:
        pop     si
        pop     ax
        ret

; ------------------------------------------------------------
; dos_menu: option "5) DOS" du menu principal. Liste les fichiers .IMG de la racine du disque (9 au plus),
; demande lequel monter comme disquette A: (touche 1-9, Echap = annuler), le monte (INT 13h AH = F0h) puis
; amorce (INT 19h). Ne revient que si on annule ou en cas d'echec (message affiche). Appelee du menu
; (DS = CS, SS = VAR_SEG); preserve tout.
; ------------------------------------------------------------
DM_SLOTS        equ     EDIT_BUFFER_OFF                 ; 9 noms de 16 octets (tampon d'edition du moniteur: libre ici)
DM_ENTRY        equ     EDIT_BUFFER_OFF + 200h          ; entree de repertoire en cours de lecture

dos_menu:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        mov     ax, VAR_SEG
        mov     ds, ax
        mov     es, ax
        cld
        mov     si, dm_title
        call    bios_puts
        call    fs_dir_first
        jc      .tmo
        or      al, al
        jnz     .nodisk
        xor     bp, bp                  ; BP = nombre d'images trouvees
.next:
        cmp     bp, 9
        jae     .show
        mov     di, DM_ENTRY
        call    fs_dir_next             ; AL = longueur du nom (0 = fin), nom, zero, taille
        jc      .tmo
        or      al, al
        jz      .show
        cmp     al, 5
        jb      .next                   ; trop court pour "X.IMG"
        xor     ah, ah
        mov     si, DM_ENTRY
        add     si, ax                  ; SI = zero final du nom
        mov     al, [si - 4]
        cmp     al, '.'
        jne     .next
        mov     al, [si - 3]
        or      al, 20h
        cmp     al, 'i'
        jne     .next
        mov     al, [si - 2]
        or      al, 20h
        cmp     al, 'm'
        jne     .next
        mov     al, [si - 1]
        or      al, 20h
        cmp     al, 'g'
        jne     .next
        mov     di, bp                  ; ranger le nom dans la case BP (16 octets)
        mov     cl, 4
        shl     di, cl
        add     di, DM_SLOTS
        mov     si, DM_ENTRY
        mov     cx, 13
        rep     movsb
        inc     bp
        jmp     .next
.show:
        or      bp, bp
        jz      .none
        xor     bx, bx
.l:
        mov     si, dm_sp
        call    bios_puts
        mov     al, bl
        add     al, '1'
        call    uart_tx_byte
        mov     al, ')'
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte
        mov     si, bx
        mov     cl, 4
        shl     si, cl
        add     si, DM_SLOTS
        call    bios_puts_ds
        mov     si, dm_crlf
        call    bios_puts
        inc     bx
        cmp     bx, bp
        jb      .l
        mov     si, dm_prompt
        call    bios_puts
.key:
        push    ds
        push    cs
        pop     ds                      ; ps2_get_char (uart_get_key) lit sa table de touches par DS = CS
        call    ps2_get_char            ; AL = touche
        pop     ds
        cmp     al, 27
        je      .cancel
        xor     ah, ah
        sub     ax, '1'
        jb      .key
        cmp     ax, bp
        jae     .key
        mov     si, ax
        mov     cl, 4
        shl     si, cl
        add     si, DM_SLOTS            ; DS:SI = nom de l'image choisie
        mov     ax, 0F000h
        int     13h                     ; monter l'image comme disquette A:
        jc      .mnterr
        int     19h                     ; amorcer A: - ne revient qu'en cas d'echec
        jmp     .done
.cancel:
        mov     si, dm_cancel
        call    bios_puts
        jmp     .done
.mnterr:
        mov     si, dm_e_size
        cmp     ah, BIOSM_BADSIZE
        je      .msg
        mov     si, dm_e_nf
        cmp     ah, 0E2h
        je      .msg
        mov     si, dm_e_mount
        jmp     .msg
.none:
        mov     si, dm_none
        jmp     .msg
.nodisk:
        mov     si, dm_e_disk
        jmp     .msg
.tmo:
        mov     si, dm_e_tmo
.msg:
        call    bios_puts
.done:
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ---- Bilinguisme FR/EN (Manifest.md) - meme mecanisme, memes
; ---- etiquettes dans les 2 branches; dm_sp/dm_crlf PARTAGES (pas de
; ---- texte, juste separateur/CRLF) ----
dm_sp:          db      '  ', 0
dm_crlf:        db      13, 10, 0
%ifdef LANG_EN
dm_title:       db      13, 10, 27, '[36m', '--- DOS: boot from a disk image (.IMG on the flash disk) ---', 27, '[0m', 13, 10, 0
dm_prompt:      db      'Image number (Esc = cancel): ', 0
dm_cancel:      db      13, 10, 'Cancelled.', 13, 10, 0
dm_none:        db      'No .IMG file found on the disk.', 13, 10, 0
dm_e_disk:      db      'Disk not ready.', 13, 10, 0
dm_e_tmo:       db      'The bridge does not answer.', 13, 10, 0
dm_e_size:      db      13, 10, 'Unsupported image size (160K, 180K, 320K, 360K, 720K, 1.2M or 1.44M expected).', 13, 10, 0
dm_e_nf:        db      13, 10, 'Image not found.', 13, 10, 0
dm_e_mount:     db      13, 10, 'Cannot mount the image.', 13, 10, 0
%else
dm_title:       db      13, 10, 27, '[36m', '--- DOS: demarrer depuis une image disquette (.IMG sur la flash) ---', 27, '[0m', 13, 10, 0
dm_prompt:      db      'Numero d', 27h, 'image (Echap = annuler): ', 0
dm_cancel:      db      13, 10, 'Annule.', 13, 10, 0
dm_none:        db      'Aucun fichier .IMG trouve sur le disque.', 13, 10, 0
dm_e_disk:      db      'Disque non pret.', 13, 10, 0
dm_e_tmo:       db      'Le pont ne repond pas.', 13, 10, 0
dm_e_size:      db      13, 10, 'Taille d', 27h, 'image non supportee (160K, 180K, 320K, 360K, 720K, 1,2M ou 1,44M attendue).', 13, 10, 0
dm_e_nf:        db      13, 10, 'Image introuvable.', 13, 10, 0
dm_e_mount:     db      13, 10, 'Impossible de monter l', 27h, 'image.', 13, 10, 0
%endif

; ------------------------------------------------------------
; INT 10h - fonctions STANDARD (teletype, mode video...) sur le terminal UART. Appelee (JMP) par
; int10h_handler pour les fonctions qui ne sont pas celles de l'interface "LCD" du projet.
; AH=00h mode (sans effet), 01h forme du curseur (sans effet), 02h positionner le curseur (page 0:
; ESC [ l ; c H), 03h lire le curseur (0,0), 06h/07h defilement (AL = 0: efface l'ecran; sinon
; sans effet), 08h lire le caractere (espace), 09h/0Ah ecrire un caractere (CX fois), 0Eh TELETYPE, 0Fh mode
; courant (80 colonnes, mode 3, page 0). Retour par IRET (sans toucher la pile: aucun acces memoire).
; Fonction inconnue: ignoree.
; ------------------------------------------------------------
bios_int10_std:
        call    bios_dots_end           ; premier affichage du DOS: fin des points de l'amorcage
        cmp     ah, 0Eh
        je      .tty
        cmp     ah, 0Fh
        je      .getmode
        cmp     ah, 03h
        je      .getcur
        cmp     ah, 02h
        je      .setcur
        cmp     ah, 06h
        je      .scroll
        cmp     ah, 07h
        je      .scroll
        cmp     ah, 08h
        je      .readchar
        cmp     ah, 0Ah
        je      .writechar
        cmp     ah, 09h
        je      .writechar
        iret                            ; 00h, 01h, 05h, ...: sans objet
.tty:
        call    uart_tx_byte            ; AL = caractere: BEL, BS, CR, LF passent tels quels
        iret
.writechar:
        cmp     cx, 0
        je      .wr0
        push    cx
.wl:
        call    uart_tx_byte
        loop    .wl
        pop     cx
.wr0:
        iret
.getmode:
        mov     ax, 5003h               ; AH = 80 colonnes, AL = mode 3
        xor     bh, bh                  ; page 0
        iret
.getcur:
        xor     dx, dx
        mov     cx, 0607h
        iret
.readchar:
        mov     ax, 0720h
        iret
.setcur:
        or      bh, bh
        jnz     .r                      ; seule la page 0 (le terminal)
        push    ax
        inc     dh                      ; ANSI: lignes et colonnes numerotees depuis 1
        inc     dl
        call    uart_ansi_goto
        dec     dh
        dec     dl
        pop     ax
.r:
        iret
.scroll:
        or      al, al
        jnz     .r
        push    ax
        mov     al, 27
        call    uart_tx_byte
        mov     al, '['
        call    uart_tx_byte
        mov     al, '2'
        call    uart_tx_byte
        mov     al, 'J'
        call    uart_tx_byte
        mov     al, 27
        call    uart_tx_byte
        mov     al, '['
        call    uart_tx_byte
        mov     al, 'H'
        call    uart_tx_byte
        pop     ax
        iret

; ------------------------------------------------------------
; INTERRUPTIONS NON IMPLEMENTEES. init_ivt_not_implemented peuple les 256 entrees de l'IVT AVANT nos vecteurs
; (start:), chacune avec SON propre gestionnaire de int_stubs: "push ax / mov al, n / jmp near int_not_implemented"
; (6 octets, 1,5 Ko en tout). int_not_implemented affiche sur l'UART le NUMERO de l'interruption, l'AH de
; l'appelant (la fonction) et l'adresse de l'appelant, puis retourne (IRET, registres intacts):
;   *** Interruption non implementee: INT 15h, AH=86h, appelee depuis 0070:1A2B ***
; Elle ne depend d'aucune pile ni segment (appels directs a l'UART).
; ------------------------------------------------------------
INT_STUB_SIZE   equ     6

init_ivt_not_implemented:
        push    ax
        push    bx
        push    cx
        push    di
        push    es
        xor     ax, ax
        mov     es, ax                  ; ES = 0000h (IVT)
        xor     di, di
        mov     bx, int_stubs
        mov     cx, 100h                ; 256 entrees
.next:
        mov     [es:di], bx
        mov     [es:di + 2], cs
        add     di, 4
        add     bx, INT_STUB_SIZE
        loop    .next
        pop     es
        pop     di
        pop     cx
        pop     bx
        pop     ax
        ret

; int_not_implemented: AL = numero de l'interruption (pose par le petit gestionnaire), pile: AX de l'appelant,
; IP, CS, FLAGS. Retourne par IRET avec tous les registres de l'appelant intacts.
int_not_implemented:
        push    bx
        push    si
        push    ds
        push    cx
        push    bp
        mov     bp, sp                  ; [bp]=BP [bp+2]=CX [bp+4]=DS [bp+6]=SI [bp+8]=BX [bp+10]=AX [bp+12]=IP [bp+14]=CS
        push    cs
        pop     ds                      ; DS = CS: les messages sont en ROM
        mov     cl, al                  ; CL = numero de l'interruption
        mov     ch, [bp + 11]           ; CH = AH de l'appelant
        mov     si, txt_ini_1
        call    uart_tx_string
        mov     al, cl
        call    uart_tx_hex_byte
        mov     si, txt_ini_2
        call    uart_tx_string
        mov     al, ch
        call    uart_tx_hex_byte
        mov     si, txt_ini_3
        call    uart_tx_string
        mov     ax, [bp + 14]
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, [bp + 12]
        call    uart_tx_hex_word
        mov     si, txt_ini_5           ; ", code "
        call    uart_tx_string
        push    dx                      ; les 8 octets qui PRECEDENT l'adresse de retour (dont l'instruction INT n)
        mov     dx, [bp + 12]           ; DX = adresse de l'octet suivant (dans le segment de l'appelant)
        sub     dx, 8
        mov     cx, 8
.cb:
        mov     ds, [bp + 14]           ; DS = segment de l'appelant, le temps de lire l'octet seulement:
        mov     si, dx                  ; uart_tx_hex_byte lit sa table de chiffres par DS (ROM)
        lodsb
        inc     dx
        push    cs
        pop     ds
        call    uart_tx_hex_byte
        mov     al, ' '
        call    uart_tx_byte
        loop    .cb
        pop     dx
        mov     si, txt_ini_4
        call    uart_tx_string
        pop     bp
        pop     cx
        pop     ds
        pop     si
        pop     bx
        pop     ax
        iret

; ---- Bilinguisme FR/EN (Manifest.md) - seuls txt_ini_1/3 contiennent
; ---- du texte a traduire; txt_ini_2/4/5 sont PARTAGES (mnemoniques/
; ---- ponctuation/ANSI, deja identiques dans les 2 langues) ----
%ifdef LANG_EN
txt_ini_1:      db      27, '[31m', '*** Interrupt not implemented: INT ', 0
txt_ini_3:      db      'h, called from ', 0
%else
txt_ini_1:      db      27, '[31m', '*** Interruption non implementee: INT ', 0
txt_ini_3:      db      'h, appelee depuis ', 0
%endif
txt_ini_2:      db      'h, AH=', 0
txt_ini_4:      db      '***', 27, '[0m', 13, 10, 0
txt_ini_5:      db      ', code ', 0

int_stubs:
%assign INT_STUB_N 0
%rep 256
        push    ax
        mov     al, INT_STUB_N
        jmp     near int_not_implemented
%assign INT_STUB_N INT_STUB_N + 1
%endrep
int_stubs_end:

; ------------------------------------------------------------
; bios_init: installe les vecteurs (IVT en 0000:0000) et remplit la zone de donnees du BIOS
; (0040:0000). Appelee au demarrage (setup_bios_interrupts). Preserve tout.
; ------------------------------------------------------------
bios_init:
        push    ax
        push    bx
        push    di
        push    es
%if BIOS_TRACE
        mov     ax, VAR_SEG             ; `make trace`: trace active des le demarrage (sinon: Ctrl-] / Ctrl-Echap)
        mov     es, ax
        mov     byte [es:BIOS_TRC_ON], 1
%endif
        xor     ax, ax
        mov     es, ax
        ; vecteurs (offset puis segment = CS de la ROM)
        mov     di, 11h * 4
        mov     bx, int11h_handler
        call    .vec
        mov     di, 12h * 4
        mov     bx, int12h_handler
        call    .vec
        mov     di, 13h * 4
        mov     bx, int13h_handler
        call    .vec
        mov     di, 14h * 4
        mov     bx, int14h_handler
        call    .vec
        mov     di, 15h * 4
        mov     bx, int15h_handler
        call    .vec
        mov     di, 16h * 4
        mov     bx, int16h_handler
        call    .vec
        mov     di, 17h * 4
        mov     bx, int17h_handler
        call    .vec
        mov     di, 19h * 4
        mov     bx, int19h_handler
        call    .vec
        mov     di, 1Ah * 4
        mov     bx, int1ah_handler
        call    .vec
        mov     di, 1Eh * 4                     ; table des parametres de disquette (en ROM)
        mov     bx, bios_dpt
        call    .vec
        ; zone de donnees du BIOS 0040:0000 (physique 00400h)
        mov     word [es:0410h], 0220h          ; equipement (INT 11h)
        mov     word [es:0413h], BIOS_MEM_KB    ; memoire (INT 12h)
        mov     byte [es:0449h], 3              ; mode video 3
        mov     word [es:044Ah], 80             ; colonnes
        mov     byte [es:0484h], 24             ; lignes - 1
        mov     word [es:0460h], 0607h          ; forme du curseur
        mov     byte [es:0475h], 1              ; disques durs
        mov     word [es:041Ah], 041Eh          ; tampon clavier: tete, queue, debut, fin
        mov     word [es:041Ch], 041Eh
        mov     word [es:0480h], 041Eh
        mov     word [es:0482h], 043Eh
        ; etat du BIOS dans VAR_SEG
        mov     ax, VAR_SEG
        mov     es, ax
        xor     ax, ax
        mov     [es:BIOS_KEYF_OFF], al
        mov     [es:BIOS_STAT_OFF], al
        mov     [es:BIOS_NSEC_OFF], ax
        mov     [es:BIOS_NSEC_OFF + 2], ax
        mov     [es:BIOS_FLOP_OFF], al          ; aucune image montee
        mov     [es:BIOS_DRV_OFF], al
        pop     es
        pop     di
        pop     bx
        pop     ax
        ret
.vec:
        mov     [es:di], bx
        mov     [es:di + 2], cs
        ret

%endif ; BIOS_ASM
