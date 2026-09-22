;============================================================
; bridge.asm
; Commandes du 8088 pour le PONT (Arduino/STM32) sur le canal PB_CHAN_CMD (3) et
; reponses en retour (etiquette PC1 = 1, tampon BRIDGE_RX_*). Sert a l'horloge
; temps reel (RTC) et au DISQUE (systeme de fichiers FAT sur la flash SPI) du pont
; STM32 (voir breadboard/arduino/8088_bridge_stm32): TIMER/TIME$/DATE$, SAVE/LOAD/
; MERGE/FILES/KILL/FORMAT du BASIC.
;
; PROTOCOLE (octets envoyes par arduino_send, canal 3, dans l'ordre):
;   00h                     PING           -> B1h, version (3), capacites
;                                             (bit 0 = RTC, bit 1 = disque)
;   01h                     LIRE l'heure   -> 8 octets: annee (bas, haut), mois,
;                                             jour, heures, minutes, secondes, centiemes
;   02h + 7 octets          REGLER l'heure: annee (2), mois, jour, h, min, s (pas de reponse)
;   Disque (fichiers a la racine, noms 8.3; un seul fichier ouvert a la fois; OPEN
;   ferme le fichier precedent):
;   10h                     STATUT         -> octet d'etat (FSE_*)
;   11h                     FORMATER       -> etat   (DETRUIT tout; long)
;   12h mode nlen nom...    OUVRIR (mode 0 lecture, 1 ecriture/creation, 2 ajout) -> etat
;   13h n                   LIRE n octets (1-32) -> longueur (0 = fin de fichier,
;                                             0FFh = erreur), puis les octets
;   14h n octets...         ECRIRE n octets (1-32) -> etat
;   15h                     FERMER         -> etat
;   16h                     REPERTOIRE: debut -> etat
;   17h                     entree suivante -> longueur du nom (0 = fin, 0FFh = erreur),
;                                             nom, taille (4 octets)
;   18h nlen nom...         SUPPRIMER      -> etat
;   19h                     ESPACE LIBRE   -> 4 octets (octets libres)
;   Secteurs (acces direct a la flash, secteurs de 512 octets, LBA 32 bits; passe par un
;   tampon de 512 octets du pont; ferme le fichier ouvert; le volume est remonte ensuite):
;   20h                     NOMBRE de secteurs -> 4 octets (0 = pas de disque)
;   21h lba(4)              LIRE le secteur dans le tampon du pont -> etat
;   22h i                   OBTENIR le bloc i (0-15) du tampon -> 32 octets
;   23h i + 32 octets       DEPOSER le bloc i (0-15) dans le tampon -> etat
;   24h lba(4)              ECRIRE le tampon dans le secteur -> etat
;   25h                     USB ON: le PC prend le disque (lecteur de masse USB); le 8088 recoit
;                           FSE_NOTREADY pour toute commande disque tant que c'est actif -> etat
;   26h                     USB OFF: le pont reprend le disque -> etat (FSE_NOSUPPORT: pas d'USB)
;   Image de disquette (un fichier de la racine sert de lecteur A:; ecritures dans le fichier):
;   27h nlen nom...         MONTER l'image -> etat, puis taille du fichier (4 octets, 0 si erreur)
;   28h                     DEMONTER -> etat
;   29h lba(4)              LIRE le secteur lba de l'image dans le tampon du pont -> etat (puis 22h)
;   2Ah lba(4)              ECRIRE le tampon (deposer par 23h) dans le secteur lba de l'image -> etat
;   2Bh                     SOMME du tampon du pont (512 octets, mot de 16 bits) -> 2 octets (poids faible d'abord):
;                           le 8088 la compare a celle des 512 octets recus et rend FSE_BADSUM si elles different
;   2Ch action              HORLOGE du 8088 (PWM materiel du pont STM32 - remplace l'Arduino UNO R4 separe
;                           de projets/Clock-8088): action 0 = lire (ne rien changer), 1 = +1 MHz, 2 = -1 MHz
;                           (1-10 MHz), 3 = aller a 4,77 MHz (defaut au demarrage du pont), 4 = aller a 8 MHz
;                           -> 4 octets: la frequence resultante en Hz (poids faible d'abord)
; La RTC du STM32 ne gere que 2000-2099. Un pont sans ces commandes (UNO) ne repond
; pas: les routines rendent CF = 1 apres le delai (environ 0,5 s a 4,77 MHz par
; unite de delai).
;
; Toutes les routines supposent SS = VAR_SEG (le tampon est adresse par BP) et les
; interruptions AUTORISEES (la reponse arrive par irq1_arduino_handler).
;
; Inclus par solution-01.asm et lib/basic.asm - garde requise.
;============================================================
%ifndef BRIDGE_ASM
%define BRIDGE_ASM

%include "include/hardware.inc"
%include "lib/common.asm"

BR_CMD_PING     equ     00h
BR_CMD_GET_TIME equ     01h
BR_CMD_SET_TIME equ     02h
FS_STATUS       equ     10h
FS_FORMAT       equ     11h
FS_OPEN         equ     12h
FS_READ         equ     13h
FS_WRITE        equ     14h
FS_CLOSE        equ     15h
FS_DIR_FIRST    equ     16h
FS_DIR_NEXT     equ     17h
FS_DELETE       equ     18h
FS_FREE         equ     19h
FS_SEC_INFO     equ     20h
FS_SEC_READ     equ     21h
FS_SEC_GET      equ     22h
FS_SEC_PUT      equ     23h
FS_SEC_WRITE    equ     24h
FS_USB_ON       equ     25h
FS_USB_OFF      equ     26h
FS_IMG_MOUNT    equ     27h
FS_IMG_UMOUNT   equ     28h
FS_IMG_READ     equ     29h
FS_IMG_WRITE    equ     2Ah
FS_SEC_SUM      equ     2Bh
FS_CLOCK        equ     2Ch

FSE_OK          equ     0
FSE_NOTREADY    equ     1               ; pas de flash ou pas de systeme de fichiers
FSE_NOTFOUND    equ     2
FSE_EXISTS      equ     3
FSE_IO          equ     4
FSE_BADNAME     equ     5
FSE_OPEN        equ     6
FSE_NOTOPEN     equ     7
FSE_FULL        equ     8
FSE_NOSUPPORT   equ     9               ; commande non geree par ce pont (USB ON/OFF)
FSE_BADSUM      equ     10              ; (cote 8088) somme de controle d'un secteur lu fausse: octets perdus ou alteres

FS_MODE_READ    equ     0
FS_MODE_WRITE   equ     1
FS_MODE_APPEND  equ     2

BR_TIMEOUT      equ     0C000h          ; tours de scrutation par unite de delai
FS_WAIT         equ     6               ; delai des commandes disque (unites, ~ 2,8 s)
FS_WAIT_FMT     equ     80              ; delai du formatage (~ 37 s)

; bridge_rx_push: AL = octet de reponse -> tampon. Appelee par l'ISR. Preserve tout.
bridge_rx_push:
        push    bx
        xor     bh, bh
        mov     bl, [BRIDGE_RX_TAIL_OFF]        ; BL = queue actuelle (DS = VAR_SEG: ISR)
        mov     [BRIDGE_RX_BUF_OFF + bx], al
        inc     bl
        and     bl, 3Fh                 ; enroulement (taille = 64)
        mov     [BRIDGE_RX_TAIL_OFF], bl
        pop     bx
        ret

; bridge_rx_flush: jette les reponses en attente (avant une nouvelle commande)
bridge_rx_flush:
        push    bp
        push    ax
        mov     bp, BRIDGE_RX_TAIL_OFF
        mov     al, [bp]
        mov     bp, BRIDGE_RX_HEAD_OFF
        mov     [bp], al
        pop     ax
        pop     bp
        ret

; bridge_rx_get_t: attend un octet de reponse -> AL, pendant au plus DX unites de delai.
; CF = 1 si delai depasse. Preserve BX, CX, DX, BP.
bridge_rx_get_t:
        push    bx
        push    cx
        push    dx
        push    bp
.outer:
        mov     cx, BR_TIMEOUT
.w:
        mov     bp, BRIDGE_RX_HEAD_OFF
        mov     al, [bp]
        mov     bp, BRIDGE_RX_TAIL_OFF
        cmp     al, [bp]
        jne     .got
        loop    .w
        dec     dx
        jnz     .outer
        stc
        jmp     .out
.got:
        mov     bl, al                  ; BL = tete
        xor     bh, bh
        mov     bp, BRIDGE_RX_BUF_OFF
        add     bp, bx
        mov     al, [bp]
        inc     bl
        and     bl, 3Fh
        mov     bp, BRIDGE_RX_HEAD_OFF
        mov     [bp], bl
        clc
.out:
        pop     bp
        pop     dx
        pop     cx
        pop     bx
        ret

; bridge_rx_get: comme bridge_rx_get_t avec un delai de 1 unite
bridge_rx_get:
        push    dx
        mov     dx, 1
        call    bridge_rx_get_t
        pop     dx
        ret

; bridge_tx: envoie AL au pont sur le canal des commandes. Preserve tout.
bridge_tx:
        push    bx
        mov     bl, PB_CHAN_CMD
        call    arduino_send
        pop     bx
        ret

; bridge_expect: BRIDGE_EXPECT_OFF <- AL (1 = reponse attendue, 0 = non). Preserve tout.
; L'ISR ne classe un octet comme reponse (PC1 = 1) que pendant cet intervalle.
bridge_expect:
        push    bp
        mov     bp, BRIDGE_EXPECT_OFF
        mov     [bp], al
        pop     bp
        ret

; rtc_get: lit l'heure dans les 8 octets a ES:DI (annee lo, annee hi, mois, jour,
; heures, minutes, secondes, centiemes). CF = 1 si le pont ne repond pas.
rtc_get:
        push    ax
        push    cx
        push    di
        call    bridge_rx_flush
        mov     al, 1
        call    bridge_expect
        mov     al, BR_CMD_GET_TIME
        call    bridge_tx
        mov     cx, 8
.l:
        call    bridge_rx_get
        jc      .done                   ; CF = 1 conserve
        stosb
        loop    .l
        clc
.done:
        pushf
        xor     al, al
        call    bridge_expect           ; plus de reponse attendue
        popf
        pop     di
        pop     cx
        pop     ax
        ret

; rtc_set: regle l'heure avec les 7 octets a DS:SI (annee lo, annee hi, mois,
; jour, heures, minutes, secondes). Pas de reponse (le pont applique dans l'ordre).
rtc_set:
        push    ax
        push    cx
        push    si
        mov     al, BR_CMD_SET_TIME
        call    bridge_tx
        mov     cx, 7
.l:
        lodsb
        call    bridge_tx
        loop    .l
        pop     si
        pop     cx
        pop     ax
        ret

; ------------------------------------------------------------
; Disque (fichiers du pont). Convention: CF = 1 si le pont ne repond pas (delai);
; sinon AL = etat (FSE_OK = 0). Les registres non cites sont preserves.
; ------------------------------------------------------------
; fs_begin: jette les reponses perimees et attend une reponse. Preserve AX.
fs_begin:
        call    bridge_rx_flush
        push    ax
        mov     al, 1
        call    bridge_expect
        pop     ax
        ret

; fs_end: fin de commande. Preserve AX et les indicateurs.
fs_end:
        pushf
        push    ax
        xor     al, al
        call    bridge_expect
        pop     ax
        popf
        ret

; fs_getb: octet de reponse -> AL (delai FS_WAIT). CF = 1: delai depasse.
fs_getb:
        push    dx
        mov     dx, FS_WAIT
        call    bridge_rx_get_t
        pop     dx
        ret

; fs_name_send: nom a DS:SI (zero final) -> longueur puis caracteres. Preserve SI.
fs_name_send:
        push    cx
        push    si
        xor     cx, cx
.n:
        cmp     byte [si], 0
        je      .e
        inc     si
        inc     cx
        jmp     .n
.e:
        pop     si
        mov     al, cl
        call    bridge_tx
        push    si
        jcxz    .r
.s:
        lodsb
        call    bridge_tx
        loop    .s
.r:
        pop     si
        pop     cx
        ret

; fs_cmd0: AL = code d'operation sans argument -> AL = etat
fs_cmd0:
        call    fs_begin
        call    bridge_tx
        call    fs_getb
        jmp     fs_end

fs_status:
        mov     al, FS_STATUS
        jmp     fs_cmd0
fs_close:
        mov     al, FS_CLOSE
        jmp     fs_cmd0
fs_dir_first:
        mov     al, FS_DIR_FIRST
        jmp     fs_cmd0

; fs_format: formate le disque (DETRUIT tout) -> AL = etat
fs_format:
        push    dx
        call    fs_begin
        mov     al, FS_FORMAT
        call    bridge_tx
        mov     dx, FS_WAIT_FMT
        call    bridge_rx_get_t
        pop     dx
        jmp     fs_end

; fs_open: AL = mode (FS_MODE_*), nom a DS:SI (zero final) -> AL = etat
fs_open:
        push    bx
        mov     bl, al
        call    fs_begin
        mov     al, FS_OPEN
        call    bridge_tx
        mov     al, bl
        call    bridge_tx
        call    fs_name_send
        call    fs_getb
        pop     bx
        jmp     fs_end

; fs_delete: nom a DS:SI -> AL = etat
fs_delete:
        call    fs_begin
        mov     al, FS_DELETE
        call    bridge_tx
        call    fs_name_send
        call    fs_getb
        jmp     fs_end

; fs_read: CX = nombre maximal d'octets (1-32), destination ES:DI. Retour: CX = octets
; lus (0 = fin de fichier). CF = 1: erreur ou delai.
fs_read:
        push    ax
        call    fs_begin
        mov     al, FS_READ
        call    bridge_tx
        mov     al, cl
        call    bridge_tx
        call    fs_getb
        jc      .err
        cmp     al, 0FFh
        je      .err
        xor     ch, ch
        mov     cl, al
        jcxz    .ok
        push    cx
.l:
        call    fs_getb
        jc      .err2
        stosb
        loop    .l
        pop     cx
.ok:
        clc
        jmp     .out
.err2:
        pop     cx
.err:
        stc
.out:
        call    fs_end
        pop     ax
        ret

; fs_write: CX octets a DS:SI -> AL = etat (0 = tout ecrit). CF = 1: delai.
fs_write:
        push    dx
.chunk:
        jcxz    .done
        mov     dx, cx
        cmp     dx, 32
        jbe     .c
        mov     dx, 32
.c:
        call    fs_begin
        mov     al, FS_WRITE
        call    bridge_tx
        mov     al, dl
        call    bridge_tx
        push    cx
        mov     cx, dx
.s:
        lodsb
        call    bridge_tx
        loop    .s
        pop     cx
        sub     cx, dx
        call    fs_getb
        jc      .to
        call    fs_end
        or      al, al
        jnz     .out                    ; etat d'erreur: CF = 0
        jmp     .chunk
.done:
        xor     al, al
        clc
        jmp     .out
.to:
        stc
        call    fs_end
.out:
        pop     dx
        ret

; fs_dir_next: entree suivante du repertoire -> ES:DI = nom (zero final) puis taille
; (4 octets). Retour: AL = longueur du nom (0 = fin). CF = 1: erreur ou delai.
fs_dir_next:
        push    bx
        push    cx
        call    fs_begin
        mov     al, FS_DIR_NEXT
        call    bridge_tx
        call    fs_getb
        jc      .err
        cmp     al, 0FFh
        je      .err
        or      al, al
        jz      .end
        mov     bl, al
        xor     ch, ch
        mov     cl, al
.n:
        call    fs_getb
        jc      .err
        stosb
        loop    .n
        xor     al, al
        stosb
        mov     cx, 4
.z:
        call    fs_getb
        jc      .err
        stosb
        loop    .z
        mov     al, bl
.end:
        clc
        jmp     .out
.err:
        stc
.out:
        pop     cx
        pop     bx
        jmp     fs_end

; fs_cmd4: AL = code d'operation sans argument, reponse de 4 octets -> DX:AX (poids
; faible d'abord). CF = 1: delai.
fs_cmd4:
        push    cx
        push    ax
        call    fs_begin
        pop     ax
        call    bridge_tx
        call    fs_getb
        jc      .err
        mov     cl, al                  ; octet 0
        call    fs_getb
        jc      .err
        mov     ch, al                  ; octet 1
        call    fs_getb
        jc      .err
        mov     dl, al                  ; octet 2
        call    fs_getb
        jc      .err
        mov     dh, al                  ; octet 3
        mov     ax, cx
        clc
        jmp     .out
.err:
        stc
.out:
        pop     cx
        jmp     fs_end

; fs_clock_cmd: DL = code d'action pour l'horloge du 8088 (0 lire, 1 +1 MHz, 2 -1 MHz,
; 3 -> 4,77 MHz, 4 -> 8 MHz) -> DX:AX = frequence resultante en Hz (poids faible
; d'abord, meme convention que fs_cmd4 ci-dessus - mais avec un octet d'ARGUMENT en
; plus, donc pas une simple variante de fs_cmd4). CF = 1: delai (pont sans cette
; commande, ou muet).
fs_clock_cmd:
        push    cx
        push    dx
        call    fs_begin
        pop     dx
        mov     al, FS_CLOCK
        call    bridge_tx
        mov     al, dl                  ; l'action
        call    bridge_tx
        call    fs_getb
        jc      .cerr
        mov     cl, al                  ; octet 0
        call    fs_getb
        jc      .cerr
        mov     ch, al                  ; octet 1
        call    fs_getb
        jc      .cerr
        mov     dl, al                  ; octet 2
        call    fs_getb
        jc      .cerr
        mov     dh, al                  ; octet 3
        mov     ax, cx
        clc
        jmp     .cout
.cerr:
        stc
.cout:
        pop     cx
        jmp     fs_end

; fs_free: espace libre -> DX:AX (octets). CF = 1: delai.
fs_free:
        mov     al, FS_FREE
        jmp     fs_cmd4

; fs_sec_info: nombre de secteurs de 512 octets -> DX:AX (0 = pas de disque). CF = 1: delai.
fs_sec_info:
        mov     al, FS_SEC_INFO
        jmp     fs_cmd4

; fs_sec_lba: envoie le numero de secteur DX:AX (poids faible d'abord). Preserve tout.
fs_sec_lba:
        call    bridge_tx               ; octet 0 (AL)
        push    ax
        mov     al, ah
        call    bridge_tx               ; octet 1
        mov     al, dl
        call    bridge_tx               ; octet 2
        mov     al, dh
        call    bridge_tx               ; octet 3
        pop     ax
        ret

; fs_sec_read: lit le secteur DX:AX (LBA) dans les 512 octets a ES:DI. Retour: AL = etat
; (FSE_OK = 0), CF = 1: delai.  ES est libre (arduino_send le sauve).
fs_sec_read:
        push    bx
        mov     bh, FS_SEC_READ
        call    fs_blk_read
        pop     bx
        ret

; fs_img_read: comme fs_sec_read, mais le secteur est lu dans l'IMAGE de disquette montee
fs_img_read:
        push    bx
        mov     bh, FS_IMG_READ
        call    fs_blk_read
        pop     bx
        ret

; fs_blk_read: BH = code d'operation (FS_SEC_READ ou FS_IMG_READ); reste: voir fs_sec_read
fs_blk_read:
        push    bx
        push    cx
        push    dx
        push    ax
        call    fs_begin
        mov     al, bh
        call    bridge_tx
        pop     ax
        call    fs_sec_lba
        call    fs_getb                 ; etat de la lecture dans le tampon du pont
        jc      .to
        or      al, al
        jnz     .st
        xor     bl, bl                  ; BL = numero du bloc (0-15)
        xor     dx, dx                  ; DX = somme des octets recus (le numero de secteur n'est plus utile)
.blk:
        mov     al, FS_SEC_GET
        call    bridge_tx
        mov     al, bl
        call    bridge_tx
        mov     cx, 32
.b:
        call    fs_getb
        jc      .to
        stosb
        xor     ah, ah
        add     dx, ax                  ; somme de controle
        loop    .b
        inc     bl
        cmp     bl, 16
        jb      .blk
        mov     al, FS_SEC_SUM          ; le pont donne sa somme: elle doit etre egale a la notre
        call    bridge_tx
        call    fs_getb
        jc      .to
        mov     cl, al
        call    fs_getb
        jc      .to
        mov     ch, al
        xor     al, al
        cmp     cx, dx
        je      .st
        mov     al, FSE_BADSUM
.st:
        clc
        jmp     .out
.to:
        stc
.out:
        pop     dx
        pop     cx
        pop     bx
        jmp     fs_end

; fs_sec_write: ecrit les 512 octets a ES:SI dans le secteur DX:AX (LBA). Retour: AL = etat
; (FSE_OK = 0), CF = 1: delai. (Lit la source par ES: DS reste VAR_SEG.)
fs_sec_write:
        push    bx
        mov     bh, FS_SEC_WRITE
        call    fs_blk_write
        pop     bx
        ret

; fs_img_write: comme fs_sec_write, mais dans l'IMAGE de disquette montee
fs_img_write:
        push    bx
        mov     bh, FS_IMG_WRITE
        call    fs_blk_write
        pop     bx
        ret

; fs_blk_write: BH = code d'operation (FS_SEC_WRITE ou FS_IMG_WRITE); reste: voir fs_sec_write
fs_blk_write:
        push    bx
        push    cx
        push    dx
        push    ax                      ; poids faible du numero de secteur
        call    fs_begin
        xor     bl, bl                  ; BL = numero du bloc (0-15)
.blk:
        mov     al, FS_SEC_PUT
        call    bridge_tx
        mov     al, bl
        call    bridge_tx
        mov     cx, 32
.b:
        es lodsb
        call    bridge_tx
        loop    .b
        call    fs_getb
        jc      .to
        or      al, al
        jnz     .st
        inc     bl
        cmp     bl, 16
        jb      .blk
        mov     al, bh                  ; FS_SEC_WRITE / FS_IMG_WRITE (BH n'a pas bouge: seul BL sert de compteur)
        call    bridge_tx
        pop     ax
        push    ax
        call    fs_sec_lba
        call    fs_getb
        jc      .to
.st:
        add     sp, 2
        clc
        jmp     .out
.to:
        add     sp, 2
        stc
.out:
        pop     dx
        pop     cx
        pop     bx
        jmp     fs_end

; fs_img_mount: DS:SI = nom (zero final, 1-12 caracteres) -> AL = etat, DX:CX = taille du fichier (si AL = 0),
; CF = 1: delai. Un seul fichier monte a la fois (le precedent est ferme par le pont). Detruit CX, DX.
fs_img_mount:
        push    bx
        call    fs_begin
        mov     al, FS_IMG_MOUNT
        call    bridge_tx
        call    fs_name_send
        call    fs_getb                 ; etat
        jc      .err
        mov     bl, al
        call    fs_getb                 ; taille: 4 octets, toujours envoyes
        jc      .err
        mov     cl, al
        call    fs_getb
        jc      .err
        mov     ch, al
        call    fs_getb
        jc      .err
        mov     dl, al
        call    fs_getb
        jc      .err
        mov     dh, al
        mov     al, bl
        clc
        jmp     .out
.err:
        stc
.out:
        pop     bx
        jmp     fs_end

; fs_img_umount: demonte l'image -> AL = etat, CF = delai
fs_img_umount:
        mov     al, FS_IMG_UMOUNT
        jmp     fs_cmd0

%endif ; BRIDGE_ASM
