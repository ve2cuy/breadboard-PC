; =============================================================================
; fs_s02.inc - fichiers du BASIC sur la disquette A: (BIOS 2.0). Remplace l'API de fichiers
; du pont STM32 de Solution-01 (Solution-01/lib/bridge.asm : memes noms, memes contrats) par
; un petit systeme FAT12 (racine seulement) sur INT 13h, lecteur 0 : l'image .IMG de la carte
; SD montee en A: (Load DOS, Ctrl+Alt+Inser, BOOT "NOM.IMG") ou, sinon, la disquette en ROM
; (lecture seule : ecrire donne "Disk I/O error").
;
; Convention (bridge.asm) : AL = etat FSE_* (0 = OK), CF = 0 ; CF = 1 seulement pour fs_read,
; fs_dir_next et fs_free en erreur. Les registres non cites sont preserves. Un seul fichier
; ouvert a la fois (comme le pont).
;
; Donnees en FS_SEG (2000h, libre sans DOS ; le BASIC est en 1000h) : FAT entiere (12
; secteurs au plus), racine entiere (16 secteurs au plus), un tampon de secteur de donnees.
; La disquette est relue (BPB, FAT, racine) a la premiere operation et apres un changement
; (INT 13h AH=16h : Ctrl+Alt+Inser, AH=F0h). La FAT et la racine modifiees sont reecrites
; (secteurs marques seulement, toutes les copies de la FAT) a la fermeture, a l'effacement
; et au formatage.
; =============================================================================
FS_SEG          equ     2000h
FS_FAT          equ     0000h           ; 12 x 512
FS_RAC          equ     1800h           ; 16 x 512
FS_TAMPON       equ     3800h           ; secteur de donnees
FS_BOOT         equ     3A00h           ; secteur d'amorce (BPB)
FS_TRAVAIL      equ     3C00h           ; 512 o : copie des octets de l'appelant
FS_V            equ     3E00h           ; variables
fv_monte        equ     FS_V + 0        ; 1 = BPB, FAT et racine en memoire
fv_spc          equ     FS_V + 1
fv_nfat         equ     FS_V + 2
fv_res          equ     FS_V + 4
fv_nrac         equ     FS_V + 6        ; entrees de la racine
fv_fatsz        equ     FS_V + 8
fv_tot          equ     FS_V + 10
fv_spt          equ     FS_V + 12
fv_tetes        equ     FS_V + 14
fv_raclba       equ     FS_V + 16
fv_racsz        equ     FS_V + 18
fv_datalba      equ     FS_V + 20
fv_namas        equ     FS_V + 22       ; dernier amas + 1
fv_fatsale      equ     FS_V + 24       ; bit n : secteur n de la FAT a reecrire
fv_racsale      equ     FS_V + 26       ; bit n : secteur n de la racine a reecrire
ff_ouvert       equ     FS_V + 28       ; 0 ferme, 1 lecture, 2 ecriture
ff_ent          equ     FS_V + 30       ; entree de la racine (decalage dans FS_SEG)
ff_prem         equ     FS_V + 32       ; premier amas (0 : vide)
ff_taille       equ     FS_V + 34       ; (dd)
ff_pos          equ     FS_V + 38       ; (dd)
ff_amas         equ     FS_V + 42       ; amas courant (0 : a chercher depuis le debut)
ff_aidx         equ     FS_V + 44       ; son rang dans la chaine
ft_lba          equ     FS_V + 46       ; secteur dans FS_TAMPON (FFFFh : aucun)
ft_sale         equ     FS_V + 48       ; 1 = FS_TAMPON a reecrire
fd_idx          equ     FS_V + 50       ; FILES : entree suivante
fv_nom          equ     FS_V + 52       ; (11 o) nom 8.3
fv_err          equ     FS_V + 64       ; erreur d'E/S pendant l'operation
fk_n            equ     FS_V + 66       ; clavier : octets en attente (sequence ANSI)
fk_buf          equ     FS_V + 68       ; (4 o)
fw_n            equ     FS_V + 72       ; fs_write : octets restants
fw_si           equ     FS_V + 74       ;            source (DS de l'appelant)

FSE_OK          equ     0
FSE_NOTREADY    equ     1
FSE_NOTFOUND    equ     2
FSE_IO          equ     4
FSE_BADNAME     equ     5
FSE_NOTOPEN     equ     7
FSE_FULL        equ     8
FSE_NOSUPPORT   equ     9

FS_MODE_READ    equ     0
FS_MODE_WRITE   equ     1
FS_MODE_APPEND  equ     2
FS_USB_ON       equ     25h
FS_USB_OFF      equ     26h

; ---- entree / sortie communes : DS = ES = FS_SEG pendant le travail -------------------
%macro FS_ENTREE 0
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        mov     bp, sp
        cld
%endmacro
%macro FS_SORTIE 0
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
%endmacro
FSP_ES          equ     0               ; [bp + ...] : registres de l'appelant
FSP_DS          equ     2
FSP_DI          equ     6
FSP_SI          equ     8
FSP_CX          equ     12

fs_segs:                                ; DS = ES = FS_SEG. Detruit AX.
        mov     ax, FS_SEG
        mov     ds, ax
        mov     es, ax
        ret

; ---- secteurs (INT 13h, lecteur 0) -----------------------------------------------------
; fs_chs : AX = secteur (LBA) -> CX, DH pour INT 13h (geometrie du BPB). Detruit AX, DX.
fs_chs:
        xor     dx, dx
        div     word [fv_spt]           ; AX = piste logique, DX = secteur - 1
        mov     cl, dl
        inc     cl
        xor     dx, dx
        div     word [fv_tetes]         ; AX = cylindre, DX = tete
        mov     dh, dl
        mov     ch, al
        ror     ah, 1
        ror     ah, 1
        and     ah, 0C0h
        or      cl, ah
        ret

; fs_secteur : AH = 02h (lire) ou 03h (ecrire), AX... -> appel : BX = destination/source
; (ES), SI = secteur. 3 essais. CF = 1 : erreur (fv_err = 1, la disquette sera relue).
; Preserve tout sauf AX.
fs_secteur:
        push    cx
        push    dx
        push    di
        mov     di, 3
.essai: push    ax
        mov     ax, si
        call    fs_chs
        pop     ax
        push    ax
        mov     al, 1
        xor     dl, dl
        int     13h
        pop     ax
        jnc     .ok
        push    ax
        xor     ax, ax
        xor     dl, dl
        int     13h
        pop     ax
        dec     di
        jnz     .essai
        push    ds
        push    ax
        mov     ax, FS_SEG
        mov     ds, ax
        mov     byte [fv_err], 1
        mov     byte [fv_monte], 0
        pop     ax
        pop     ds
        stc
.ok:    pop     di
        pop     dx
        pop     cx
        ret

; ---- montage : BPB, FAT, racine ---------------------------------------------------------
; fs_monte : (DS = ES = FS_SEG) disquette prete. AL = etat. Si un fichier est ouvert, rien.
fs_monte:
        cmp     byte [ff_ouvert], 0
        jne     .ok
        mov     ah, 16h                 ; disquette changee (Ctrl+Alt+Inser, AH=F0h) ?
        xor     dl, dl
        int     13h
        jnc     .meme
        cmp     ah, 06h
        jne     .meme
        mov     byte [fv_monte], 0
.meme:  cmp     byte [fv_monte], 0
        jne     .ok
        mov     word [ft_lba], 0FFFFh
        mov     byte [ft_sale], 0
        mov     word [fv_fatsale], 0
        mov     word [fv_racsale], 0
        mov     word [fv_spt], 1        ; secteur 0 : C0 T0 S1 quelle que soit la geometrie
        mov     word [fv_tetes], 1
        mov     bx, FS_BOOT
        xor     si, si
        mov     ah, 02h
        call    fs_secteur
        jc      .pas_pret
        cmp     word [FS_BOOT + 11], 512        ; BPB plausible ?
        jne     .pas_pret
        mov     al, [FS_BOOT + 13]
        or      al, al
        jz      .pas_pret
        mov     [fv_spc], al
        mov     ax, [FS_BOOT + 14]
        mov     [fv_res], ax
        mov     al, [FS_BOOT + 16]
        mov     [fv_nfat], al
        mov     ax, [FS_BOOT + 17]
        mov     [fv_nrac], ax
        mov     ax, [FS_BOOT + 19]
        mov     [fv_tot], ax
        mov     ax, [FS_BOOT + 22]
        or      ax, ax
        jz      .pas_pret
        cmp     ax, 12
        ja      .pas_pret
        mov     [fv_fatsz], ax
        mov     ax, [FS_BOOT + 24]
        or      ax, ax
        jz      .pas_pret
        mov     [fv_spt], ax
        mov     ax, [FS_BOOT + 26]
        or      ax, ax
        jz      .pas_pret
        mov     [fv_tetes], ax
        mov     ax, [fv_nrac]           ; secteurs de la racine
        add     ax, 15
        mov     cl, 4
        shr     ax, cl
        or      ax, ax
        jz      .pas_pret
        cmp     ax, 16
        ja      .pas_pret
        mov     [fv_racsz], ax
        mov     al, [fv_nfat]
        xor     ah, ah
        mul     word [fv_fatsz]
        add     ax, [fv_res]
        mov     [fv_raclba], ax
        add     ax, [fv_racsz]
        mov     [fv_datalba], ax
        mov     cx, ax
        mov     ax, [fv_tot]            ; amas = (total - donnees) / spc + 2
        sub     ax, cx
        jbe     .pas_pret
        xor     dx, dx
        mov     cl, [fv_spc]
        xor     ch, ch
        div     cx
        add     ax, 2
        mov     [fv_namas], ax
        mov     cx, [fv_fatsz]          ; FAT (1re copie)
        mov     si, [fv_res]
        mov     bx, FS_FAT
.f:     mov     ah, 02h
        call    fs_secteur
        jc      .pas_pret
        add     bx, 512
        inc     si
        loop    .f
        mov     cx, [fv_racsz]          ; racine
        mov     si, [fv_raclba]
        mov     bx, FS_RAC
.r:     mov     ah, 02h
        call    fs_secteur
        jc      .pas_pret
        add     bx, 512
        inc     si
        loop    .r
        mov     byte [fv_monte], 1
.ok:    xor     al, al
        ret
.pas_pret:
        mov     byte [fv_monte], 0
        mov     al, FSE_NOTREADY
        ret

; fs_meta : reecrit les secteurs marques de la FAT (toutes les copies) et de la racine.
; AL = etat.
fs_meta:
        mov     byte [fv_err], 0
        xor     cx, cx                  ; CX = secteur de la FAT
.f:     cmp     cx, [fv_fatsz]
        jae     .rac
        mov     ax, 1
        shl     ax, cl
        test    [fv_fatsale], ax
        jz      .fs
        mov     bx, cx                  ; BX = FS_FAT + 512 x CX
        push    cx
        mov     cl, 9
        shl     bx, cl
        pop     cx
        mov     si, [fv_res]
        add     si, cx
        mov     dl, [fv_nfat]
.copie: mov     ah, 03h
        call    fs_secteur
        jc      .err
        add     si, [fv_fatsz]
        dec     dl
        jnz     .copie
.fs:    inc     cx
        jmp     .f
.rac:   xor     cx, cx
.r:     cmp     cx, [fv_racsz]
        jae     .fin
        mov     ax, 1
        shl     ax, cl
        test    [fv_racsale], ax
        jz      .rs
        mov     bx, cx
        push    cx
        mov     cl, 9
        shl     bx, cl
        pop     cx
        add     bx, FS_RAC
        mov     si, [fv_raclba]
        add     si, cx
        mov     ah, 03h
        call    fs_secteur
        jc      .err
.rs:    inc     cx
        jmp     .r
.fin:   mov     word [fv_fatsale], 0
        mov     word [fv_racsale], 0
        xor     al, al
        ret
.err:   mov     al, FSE_IO
        ret

; ---- FAT12 ----------------------------------------------------------------------------
; fs_fat_lit : AX = amas -> AX = valeur. Detruit BX, CX.
fs_fat_lit:
        mov     bx, ax
        shr     bx, 1
        add     bx, ax                  ; BX = n x 3 / 2
        test    al, 1
        mov     ax, [FS_FAT + bx]
        jz      .pair
        mov     cl, 4
        shr     ax, cl
        ret
.pair:  and     ax, 0FFFh
        ret

; fs_fat_ecrit : AX = amas, DX = valeur. Marque les secteurs. Detruit BX, CX.
fs_fat_ecrit:
        mov     bx, ax
        shr     bx, 1
        add     bx, ax
        test    al, 1
        jz      .pair
        mov     cx, dx
        push    cx
        mov     cl, 4
        pop     dx
        shl     dx, cl
        and     word [FS_FAT + bx], 000Fh
        or      [FS_FAT + bx], dx
        mov     dx, cx
        jmp     .marque
.pair:  and     word [FS_FAT + bx], 0F000h
        and     dx, 0FFFh
        or      [FS_FAT + bx], dx
.marque:
        push    ax
        mov     ax, bx                  ; secteurs de BX et BX + 1
        mov     cl, 9
        shr     ax, cl
        mov     cl, al
        mov     ax, 1
        shl     ax, cl
        or      [fv_fatsale], ax
        mov     ax, bx
        inc     ax
        mov     cl, 9
        shr     ax, cl
        mov     cl, al
        mov     ax, 1
        shl     ax, cl
        or      [fv_fatsale], ax
        pop     ax
        ret

; fs_libere : libere la chaine qui commence a l'amas AX. Detruit AX, BX, CX, DX.
fs_libere:
.l:     cmp     ax, 2
        jb      .fin
        cmp     ax, 0FF8h
        jae     .fin
        cmp     ax, [fv_namas]
        jae     .fin
        push    ax
        call    fs_fat_lit
        mov     dx, ax                  ; suivant
        pop     ax
        push    dx
        xor     dx, dx
        call    fs_fat_ecrit
        pop     ax
        jmp     .l
.fin:   ret

; fs_alloue : AX = amas libre, marque fin de chaine (FFFh). CF = 1 : disque plein.
; Detruit BX, CX, DX.
fs_alloue:
        mov     ax, 2
.l:     cmp     ax, [fv_namas]
        jae     .plein
        push    ax
        call    fs_fat_lit
        or      ax, ax
        pop     ax
        jz      .libre
        inc     ax
        jmp     .l
.libre: push    ax
        mov     dx, 0FFFh
        call    fs_fat_ecrit
        pop     ax
        clc
        ret
.plein: stc
        ret

; fs_amas_lba : AX = amas -> AX = 1er secteur. Detruit DX.
fs_amas_lba:
        sub     ax, 2
        mov     dl, [fv_spc]
        xor     dh, dh
        mul     dx
        add     ax, [fv_datalba]
        ret

; ---- racine ---------------------------------------------------------------------------
; fs_nom : nom DS:SI de l'appelant (zero final, 1-12 caracteres) -> fv_nom (8 + 3, espaces).
; A appeler AVANT fs_segs (DS = celui de l'appelant). CF = 1 : nom invalide. Detruit AX,
; CX, SI, DI, ES.
fs_nom:
        mov     ax, FS_SEG
        mov     es, ax
        mov     di, fv_nom
        mov     cx, 11
        mov     al, ' '
        rep     stosb
        mov     di, fv_nom
        mov     cx, 8
.b:     lodsb
        or      al, al
        jz      .fin_base
        cmp     al, '.'
        je      .ext
        jcxz    .non
        cmp     al, ' '
        jbe     .non
        stosb
        dec     cx
        jmp     .b
.ext:   cmp     di, fv_nom
        je      .non
        mov     di, fv_nom + 8
        mov     cx, 3
.e:     lodsb
        or      al, al
        jz      .oui
        jcxz    .non
        cmp     al, '.'
        je      .non
        cmp     al, ' '
        jbe     .non
        stosb
        dec     cx
        jmp     .e
.fin_base:
        cmp     di, fv_nom
        je      .non
.oui:   clc
        ret
.non:   stc
        ret

; fs_cherche : fv_nom dans la racine -> BX = entree (CF = 0) ; CF = 1 : absent, DI = 1re
; entree libre (0 : aucune). Detruit AX, CX, SI.
fs_cherche:
        mov     bx, FS_RAC
        xor     di, di
        mov     cx, [fv_nrac]
.l:     mov     al, [bx]
        or      al, al
        jz      .vide
        cmp     al, 0E5h
        je      .libre
        test    byte [bx + 11], 18h     ; ni etiquette ni repertoire
        jnz     .s
        push    cx
        push    di
        mov     si, fv_nom
        mov     di, bx
        mov     cx, 11
        repe    cmpsb
        pop     di
        pop     cx
        je      .trouve
        jmp     .s
.libre: or      di, di
        jnz     .s
        mov     di, bx
.s:     add     bx, 32
        loop    .l
        stc
        ret
.vide:  or      di, di
        jnz     .absent
        mov     di, bx
.absent:
        stc
        ret
.trouve:
        clc
        ret

; fs_rac_sale : l'entree BX a change : marque son secteur. Detruit AX, CX.
fs_rac_sale:
        mov     ax, bx
        sub     ax, FS_RAC
        mov     cl, 9
        shr     ax, cl
        mov     cl, al
        mov     ax, 1
        shl     ax, cl
        or      [fv_racsale], ax
        ret

; fs_date : AX = date DOS (date du BASIC, DSEG:0C60h ; 1980-01-01 si jamais reglee).
; Detruit CX.
fs_date:
        push    ds
        mov     ax, 7F00h
        mov     ds, ax
        mov     ax, [0C60h]             ; annee
        mov     cx, [0C62h]             ; CL = mois, CH = jour
        pop     ds
        cmp     ax, 1980
        jb      .defaut
        sub     ax, 1980
        push    cx
        mov     cl, 9
        shl     ax, cl
        pop     cx
        push    ax
        mov     al, cl
        xor     ah, ah
        mov     cl, 5
        shl     ax, cl
        mov     cl, ch
        xor     ch, ch
        or      ax, cx
        pop     cx
        or      ax, cx
        ret
.defaut:
        mov     ax, (1 << 5) | 1
        ret

; ---- tampon de donnees ----------------------------------------------------------------
fs_vide_tampon:                         ; CF = 1 : erreur d'ecriture. Detruit AX.
        cmp     byte [ft_sale], 0
        je      .ok
        push    bx
        push    si
        mov     bx, FS_TAMPON
        mov     si, [ft_lba]
        mov     ah, 03h
        call    fs_secteur
        pop     si
        pop     bx
        jc      .err
        mov     byte [ft_sale], 0
.ok:    clc
.err:   ret

; fs_charge : AX = secteur dans FS_TAMPON (ecrit l'ancien s'il a change). CF = 1 : erreur.
; DL = 1 : secteur neuf (rempli de zeros, pas de lecture).
fs_charge:
        cmp     ax, [ft_lba]
        je      .ok
        push    ax
        call    fs_vide_tampon
        pop     ax
        jc      .err
        mov     [ft_lba], ax
        or      dl, dl
        jz      .lire
        push    cx
        push    di
        push    ax
        mov     di, FS_TAMPON
        mov     cx, 256
        xor     ax, ax
        rep     stosw
        pop     ax
        pop     di
        pop     cx
        clc
        ret
.lire:  push    bx
        push    si
        mov     si, ax
        mov     bx, FS_TAMPON
        mov     ah, 02h
        call    fs_secteur
        pop     si
        pop     bx
        jnc     .ok
        mov     word [ft_lba], 0FFFFh
.err:   stc
        ret
.ok:    clc
        ret

; fs_position : secteur de l'octet ff_pos -> AX = secteur (LBA), BX = decalage dans le
; secteur. DL = 1 (ecriture) : alloue les amas manquants (le secteur d'un amas neuf : DH = 1).
; CF = 1 : erreur ou disque plein (AL = FSE_*). Detruit CX, SI.
fs_position:
        mov     dh, 0
        push    dx
        mov     ax, [ff_pos]
        mov     dx, [ff_pos + 2]
        mov     bx, ax
        and     bx, 511                 ; BX = octet dans le secteur
        mov     cx, 9
.s:     shr     dx, 1
        rcr     ax, 1
        loop    .s                      ; AX = rang du secteur dans le fichier
        mov     cl, [fv_spc]
        xor     ch, ch
        xor     dx, dx
        div     cx                      ; AX = rang de l'amas, DX = secteur dans l'amas
        mov     si, ax
        pop     cx                      ; CL = 1 : ecriture
        push    dx
        push    bx
        cmp     word [ff_prem], 0       ; fichier vide : 1er amas
        jne     .a1
        or      cl, cl
        jz      .eof
        push    cx
        call    fs_alloue
        pop     cx
        jc      .plein
        mov     [ff_prem], ax
        mov     ch, 1                   ; amas neuf
        mov     word [ff_amas], 0
.a1:    mov     ax, [ff_amas]
        or      ax, ax
        jz      .debut
        cmp     si, [ff_aidx]
        jae     .avance
.debut: mov     ax, [ff_prem]
        mov     [ff_amas], ax
        mov     word [ff_aidx], 0
.avance:
        cmp     si, [ff_aidx]
        je      .la
        push    cx
        mov     ax, [ff_amas]
        call    fs_fat_lit
        pop     cx
        cmp     ax, 0FF8h
        jb      .suiv
        or      cl, cl                  ; fin de chaine : lecture -> fin ; ecriture -> amas
        jz      .eof
        push    cx
        call    fs_alloue
        pop     cx
        jc      .plein
        push    ax
        push    cx
        mov     dx, ax
        mov     ax, [ff_amas]
        call    fs_fat_ecrit
        pop     cx
        pop     ax
        mov     ch, 1
.suiv:  mov     [ff_amas], ax
        inc     word [ff_aidx]
        jmp     .avance
.la:    mov     ax, [ff_amas]
        call    fs_amas_lba
        pop     bx
        pop     dx
        add     ax, dx
        mov     dh, ch                  ; DH = 1 : amas neuf
        clc
        ret
.eof:   pop     bx
        pop     dx
        mov     al, FSE_IO
        stc
        ret
.plein: pop     bx
        pop     dx
        mov     al, FSE_FULL
        stc
        ret

; ---- API (bridge.asm) -----------------------------------------------------------------
; fs_open : AL = mode (FS_MODE_*), nom a DS:SI -> AL = etat. Un fichier deja ouvert est
; d'abord ferme.
fs_open:
        FS_ENTREE
        mov     dl, al
        call    fs_nom
        mov     al, FSE_BADNAME
        jc      .fin
        call    fs_segs
        push    dx
        call    fs_ferme
        call    fs_monte
        pop     dx
        or      al, al
        jnz     .fin
        call    fs_cherche
        jnc     .existe
        cmp     dl, FS_MODE_READ
        mov     al, FSE_NOTFOUND
        je      .fin
        or      di, di                  ; creation
        mov     al, FSE_FULL
        jz      .fin
        mov     bx, di
        mov     si, fv_nom
        mov     cx, 11
        rep     movsb
        mov     byte [bx + 11], 20h     ; archive
        mov     di, bx
        add     di, 12
        xor     ax, ax
        mov     cx, 10
        rep     stosb
        mov     word [bx + 22], 0       ; heure
        call    fs_date
        mov     [bx + 24], ax
        mov     word [bx + 26], 0       ; amas
        mov     word [bx + 28], 0       ; taille
        mov     word [bx + 30], 0
        call    fs_rac_sale
        jmp     .ouvre
.existe:
        cmp     dl, FS_MODE_WRITE       ; ecriture : le fichier est vide
        jne     .ouvre
        mov     ax, [bx + 26]
        push    bx
        push    dx
        call    fs_libere
        pop     dx
        pop     bx
        mov     word [bx + 26], 0
        mov     word [bx + 28], 0
        mov     word [bx + 30], 0
        call    fs_rac_sale
.ouvre: mov     [ff_ent], bx
        mov     ax, [bx + 26]
        mov     [ff_prem], ax
        mov     ax, [bx + 28]
        mov     [ff_taille], ax
        mov     ax, [bx + 30]
        mov     [ff_taille + 2], ax
        xor     ax, ax
        mov     [ff_pos], ax
        mov     [ff_pos + 2], ax
        mov     [ff_amas], ax
        mov     [ff_aidx], ax
        mov     byte [ff_ouvert], 1
        cmp     dl, FS_MODE_READ
        je      .ok
        mov     byte [ff_ouvert], 2
        cmp     dl, FS_MODE_APPEND
        jne     .ok
        mov     ax, [ff_taille]         ; ajout : a la fin
        mov     [ff_pos], ax
        mov     ax, [ff_taille + 2]
        mov     [ff_pos + 2], ax
.ok:    xor     al, al
.fin:   FS_SORTIE
        clc
        ret

; fs_ferme : (FS_SEG) ferme le fichier ouvert : tampon, entree, FAT, racine. AL = etat.
fs_ferme:
        mov     al, [ff_ouvert]
        mov     byte [ff_ouvert], 0
        cmp     al, 2
        jne     .rien
        mov     byte [fv_err], 0
        call    fs_vide_tampon
        mov     bx, [ff_ent]
        mov     ax, [ff_prem]
        mov     [bx + 26], ax
        mov     ax, [ff_taille]
        mov     [bx + 28], ax
        mov     ax, [ff_taille + 2]
        mov     [bx + 30], ax
        call    fs_date
        mov     [bx + 24], ax
        call    fs_rac_sale
        call    fs_meta
        cmp     byte [fv_err], 0
        je      .r
        mov     al, FSE_IO
.r:     ret
.rien:  xor     al, al
        ret

fs_close:
        FS_ENTREE
        call    fs_segs
        call    fs_ferme
        FS_SORTIE
        clc
        ret

; fs_read : CX = nombre maximal d'octets, destination ES:DI -> CX = octets lus (0 = fin).
; CF = 1 : erreur. Preserve AX.
fs_read:
        push    ax
        FS_ENTREE
        call    fs_segs
        cmp     byte [ff_ouvert], 1
        jne     .err
        mov     cx, [bp + FSP_CX]
        cmp     cx, 512
        jbe     .n
        mov     cx, 512
.n:     mov     di, FS_TRAVAIL
        xor     bp, bp                  ; BP = octets lus
.l:     jcxz    .copie
        mov     ax, [ff_pos]            ; fin du fichier ?
        mov     dx, [ff_pos + 2]
        cmp     dx, [ff_taille + 2]
        jb      .lit
        ja      .copie
        cmp     ax, [ff_taille]
        jae     .copie
.lit:   push    cx
        xor     dl, dl
        call    fs_position
        pop     cx
        jc      .err
        xor     dl, dl
        call    fs_charge
        jc      .err
        mov     al, [FS_TAMPON + bx]
        stosb
        inc     bp
        add     word [ff_pos], 1
        adc     word [ff_pos + 2], 0
        dec     cx
        jmp     .l
.copie: mov     cx, bp
        mov     bp, sp
        mov     es, [bp + FSP_ES]       ; vers ES:DI de l'appelant
        mov     di, [bp + FSP_DI]
        mov     si, FS_TRAVAIL
        mov     [bp + FSP_CX], cx
        rep     movsb
        FS_SORTIE
        pop     ax
        clc
        ret
.err:   mov     bp, sp
        mov     word [bp + FSP_CX], 0
        FS_SORTIE
        pop     ax
        stc
        ret

; fs_write : CX octets a DS:SI -> AL = etat.
fs_write:
        FS_ENTREE
        mov     ax, FS_SEG
        mov     es, ax
        mov     [es:fw_n], cx
        mov     [es:fw_si], si
.bloc:  mov     ax, FS_SEG
        mov     ds, ax
        mov     es, ax
        mov     cx, [fw_n]
        or      cx, cx
        jnz     .reste
        jmp     .ok0
.reste: cmp     cx, 512
        jbe     .c
        mov     cx, 512
.c:     sub     [fw_n], cx
        mov     si, [fw_si]             ; octets de l'appelant -> FS_TRAVAIL
        add     [fw_si], cx
        mov     ds, [bp + FSP_DS]
        mov     di, FS_TRAVAIL
        push    cx
        rep     movsb
        pop     cx
        call    fs_segs
        cmp     byte [ff_ouvert], 2
        mov     al, FSE_NOTOPEN
        jne     .fin
        mov     si, FS_TRAVAIL
.l:     push    cx
        push    si
        mov     dl, 1
        call    fs_position
        pop     si
        jc      .err_p
        mov     dl, dh                  ; amas neuf : secteur sans lecture
        or      dl, dl
        jnz     .ch
        mov     dx, [ff_pos]            ; ecrit au-dela de la taille sur un secteur entier :
        and     dx, 511                 ; pas besoin de le lire non plus
        jnz     .ch
        mov     dx, [ff_pos]
        mov     cx, [ff_pos + 2]
        cmp     cx, [ff_taille + 2]
        jb      .lu
        ja      .neuf
        cmp     dx, [ff_taille]
        jb      .lu
.neuf:  mov     dl, 1
        jmp     .ch
.lu:    xor     dl, dl
.ch:    call    fs_charge
        jc      .err_io
        lodsb
        mov     [FS_TAMPON + bx], al
        mov     byte [ft_sale], 1
        add     word [ff_pos], 1
        adc     word [ff_pos + 2], 0
        mov     ax, [ff_pos]            ; taille = max(taille, pos)
        mov     dx, [ff_pos + 2]
        cmp     dx, [ff_taille + 2]
        jb      .t
        ja      .grand
        cmp     ax, [ff_taille]
        jbe     .t
.grand: mov     [ff_taille], ax
        mov     [ff_taille + 2], dx
.t:     pop     cx
        loop    .l
        jmp     .bloc
.ok0:   xor     al, al
.fin:   FS_SORTIE
        clc
        ret
.err_io:
        mov     al, FSE_IO
.err_p: pop     cx
        jmp     .fin

; fs_dir_first : debut de la liste de la racine -> AL = etat.
fs_dir_first:
        FS_ENTREE
        call    fs_segs
        call    fs_monte
        mov     word [fd_idx], 0
        FS_SORTIE
        clc
        ret

; fs_dir_next : entree suivante -> ES:DI = nom (zero final) puis taille (4 octets) ;
; AL = longueur du nom (0 = fin). CF = 1 : erreur.
fs_dir_next:
        FS_ENTREE
        call    fs_segs
        cmp     byte [fv_monte], 0
        je      .err
.l:     mov     ax, [fd_idx]
        cmp     ax, [fv_nrac]
        jae     .fin_liste
        inc     word [fd_idx]
        mov     cl, 5
        shl     ax, cl
        add     ax, FS_RAC
        mov     bx, ax
        mov     al, [bx]
        or      al, al
        jz      .fin_liste
        cmp     al, 0E5h
        je      .l
        test    byte [bx + 11], 1Ah     ; ni cache, ni etiquette, ni repertoire
        jnz     .l
        mov     di, FS_TRAVAIL          ; "NOM.EXT" en clair
        mov     si, bx
        mov     cx, 8
.b:     lodsb
        cmp     al, ' '
        je      .b1
        stosb
.b1:    loop    .b
        cmp     byte [bx + 8], ' '
        je      .sans_ext
        mov     al, '.'
        stosb
        mov     cx, 3
.e:     lodsb
        cmp     al, ' '
        je      .e1
        stosb
.e1:    loop    .e
.sans_ext:
        mov     cx, di
        sub     cx, FS_TRAVAIL          ; CX = longueur
        xor     al, al
        stosb
        mov     ax, [bx + 28]
        stosw
        mov     ax, [bx + 30]
        stosw
        push    cx
        add     cx, 5
        mov     es, [bp + FSP_ES]
        mov     di, [bp + FSP_DI]
        mov     si, FS_TRAVAIL
        rep     movsb
        pop     ax                      ; AL = longueur
        FS_SORTIE
        clc
        ret
.fin_liste:
        xor     al, al
        FS_SORTIE
        clc
        ret
.err:   FS_SORTIE
        stc
        ret

; fs_delete : nom a DS:SI -> AL = etat.
fs_delete:
        FS_ENTREE
        call    fs_nom
        mov     al, FSE_BADNAME
        jc      .fin
        call    fs_segs
        call    fs_monte
        or      al, al
        jnz     .fin
        call    fs_cherche
        mov     al, FSE_NOTFOUND
        jc      .fin
        mov     ax, [bx + 26]
        push    bx
        call    fs_libere
        pop     bx
        mov     byte [bx], 0E5h
        call    fs_rac_sale
        call    fs_meta
.fin:   FS_SORTIE
        clc
        ret

; fs_free : espace libre -> DX:AX (octets). CF = 1 : erreur.
fs_free:
        push    bx
        push    cx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        call    fs_segs
        call    fs_monte
        or      al, al
        jnz     .err
        xor     si, si                  ; SI = amas libres
        mov     ax, 2
.l:     cmp     ax, [fv_namas]
        jae     .fin
        push    ax
        call    fs_fat_lit
        or      ax, ax
        pop     ax
        jnz     .s
        inc     si
.s:     inc     ax
        jmp     .l
.fin:   mov     al, [fv_spc]            ; octets = amas x spc x 512
        xor     ah, ah
        mov     cl, 9
        shl     ax, cl
        mul     si
        clc
        jmp     .r
.err:   stc
.r:     pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     cx
        pop     bx
        ret

; fs_format : vide la disquette (FAT et racine ; le BPB est garde) -> AL = etat.
fs_format:
        FS_ENTREE
        call    fs_segs
        call    fs_ferme
        mov     byte [fv_monte], 0
        call    fs_monte
        or      al, al
        jnz     .fin
        mov     di, FS_FAT
        mov     cx, 12 * 256
        xor     ax, ax
        rep     stosw
        mov     al, [FS_BOOT + 21]      ; descripteur du support
        mov     ah, 0FFh
        mov     [FS_FAT], ax
        mov     byte [FS_FAT + 2], 0FFh
        mov     di, FS_RAC
        mov     cx, 16 * 256
        xor     ax, ax
        rep     stosw
        mov     word [fv_fatsale], 0FFFFh
        mov     word [fv_racsale], 0FFFFh
        call    fs_meta
.fin:   FS_SORTIE
        clc
        ret

; fs_sec_read : secteur DX:AX (LBA) -> 512 octets a ES:DI. AL = etat.
fs_sec_read:
        push    bx
        push    cx
        mov     bx, di
        mov     cl, 02h
        jmp     fs_sec_rw
; fs_sec_write : 512 octets a ES:SI -> secteur DX:AX. AL = etat.
fs_sec_write:
        push    bx
        push    cx
        mov     bx, si
        mov     cl, 03h
fs_sec_rw:
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        mov     si, ax                  ; SI = secteur (DX = 0 : disquette)
        push    bx
        push    cx
        call    fs_segs
        call    fs_monte
        pop     cx                      ; CL = fonction (02h, 03h)
        pop     bx
        or      al, al
        jnz     .fin
        mov     bp, sp
        mov     es, [bp]                ; ES de l'appelant
        mov     ah, cl
        call    fs_secteur
        mov     al, FSE_OK
        jnc     .fin
        mov     al, FSE_IO
.fin:   pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        clc
        ret

; fs_cmd0 : USB ON/OFF du pont : sans objet ici.
fs_cmd0:
        mov     al, FSE_NOSUPPORT
        clc
        ret
