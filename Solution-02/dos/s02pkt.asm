; =============================================================================
; S02PKT.COM - pilote de paquets (Packet Driver Specification 1.09, classe 1 = Ethernet)
; pour Solution-02 : le module Wi-Fi de J13 (esp_slip_router : SLIP, NAT) derriere
; l'ATmega U17, par le BIOS 3.1 (INT 14h DX = 1, AH = 08h / 09h : blocs).
;
; Comme ETHERSL, il presente une carte Ethernet simulee aux programmes (mTCP, WATTCP...) :
;   - envoi d'une trame IPv4 (type 0800h) : en-tete Ethernet retire, paquet IP en SLIP ;
;   - requete ARP (type 0806h) : reponse fabriquee sur place (toute adresse IP demandee a
;     l'adresse MAC du "pair" : tout passe de toute facon par le module) ;
;   - paquet IP recu en SLIP : en-tete Ethernet ajoute, remis au programme abonne.
; Pas d'interruption pour le canal 2 : le module est scrute a chaque INT 1Ch (18,2 Hz), au
; plus 255 octets par tic (~4,6 Ko/s). Le BIOS partage le bus SPI avec la carte SD.
;
;   S02PKT            installe le pilote sur INT 60h (mTCP : PACKETINT 0x60)
;
; Adresses MAC (administrees localement) : carte 02:53:30:32:00:02, pair 02:53:30:32:00:01.
; Construire : nasm -f bin -o S02PKT.COM s02pkt.asm
; =============================================================================
        cpu     8086
        org     100h

VECTEUR         equ     60h
MAX_HANDLES     equ     4
TRAME_MAX       equ     1514            ; en-tete Ethernet (14) + MTU 1500
SLIP_END        equ     0C0h
SLIP_ESC        equ     0DBh
SLIP_ESC_END    equ     0DCh
SLIP_ESC_ESC    equ     0DDh

; codes d'erreur de la specification
BAD_HANDLE      equ     1
NO_CLASS        equ     2
NO_TYPE         equ     3
NO_NUMBER       equ     4
BAD_TYPE        equ     5
NO_SPACE        equ     9
TYPE_INUSE      equ     10
BAD_COMMAND     equ     11
CANT_SEND       equ     12

debut:
        jmp     installe

; ------------------------------------------------------------------ partie residente
; INT 60h : la signature "PKT DRVR" doit etre 3 octets apres le point d'entree
pd_entree:
        jmp     short pd_saut
        nop
        db      'PKT DRVR', 0
pd_saut:
        jmp     pd_traite

nom_pilote:     db      'S02PKT SLIP (Solution-02)', 0
mac_carte:      db      02h, 53h, 30h, 32h, 00h, 02h
mac_pair:       db      02h, 53h, 30h, 32h, 00h, 01h

; abonnes : type (8 octets max), longueur du type, recepteur (far), actif
struc abonne
.type:          resb    8
.lg:            resw    1
.recep:         resd    1
.actif:         resb    1
endstruc
abonnes:        times MAX_HANDLES * abonne_size db 0

ancien_1c:      dd      0
occupe:         db      0               ; scrutation en cours (pas d'imbrication)

; reception SLIP : trame Ethernet en construction (en-tete puis paquet IP)
rx_trame:       times TRAME_MAX db 0
rx_lg:          dw      0               ; octets du paquet IP recus
rx_esc:         db      0
rx_bloc:        times 255 db 0

; reponse ARP en attente (fabriquee a l'envoi, remise au tic suivant)
arp_pret:       db      0
arp_trame:      times 42 db 0

; envoi SLIP : tampon de quelques octets codes, vide par INT 14h AH=09h
tx_bloc:        times 130 db 0
tx_n:           dw      0

; statistiques (get_statistics, AH = 24) : 7 compteurs 32 bits
stats:
st_rx_paquets:  dd      0
st_tx_paquets:  dd      0
st_rx_octets:   dd      0
st_tx_octets:   dd      0
st_erreurs_in:  dd      0
st_erreurs_out: dd      0
st_perdus:      dd      0

pile:           times 256 dw 0
pile_haut:
pile_ss:        dw      0
pile_sp:        dw      0

; ---- cadre des registres de l'appelant (apres les PUSH de pd_traite) ----------
R_ES    equ     0
R_DS    equ     2
R_BP    equ     4
R_DI    equ     6
R_SI    equ     8
R_DX    equ     10
R_CX    equ     12
R_BX    equ     14
R_AX    equ     16
R_FL    equ     22                      ; drapeaux de l'IRET

pd_traite:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        mov     bp, sp
        and     word [bp + R_FL], 0FFFEh        ; CF = 0 par defaut
        push    cs
        pop     ds
        cmp     ah, 1
        je      f_info
        cmp     ah, 2
        je      f_acces
        cmp     ah, 3
        je      f_libere
        cmp     ah, 4
        je      f_envoi
        cmp     ah, 6
        je      f_adresse
        cmp     ah, 7
        je      f_ok                    ; reset_interface : rien a faire
        cmp     ah, 24
        je      f_stats
        cmp     ah, 5                   ; terminate : non (le pilote reste)
        jne     .inconnu
        mov     dh, NO_SPACE
        jmp     f_erreur
.inconnu:
        mov     dh, BAD_COMMAND
        jmp     f_erreur

f_erreur:
        mov     [bp + R_DX + 1], dh
        or      word [bp + R_FL], 1
f_ok:
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

; AH = 1 driver_info : BX version, CH classe, DX type, CL numero, DS:SI nom, AL fonctions
f_info:
        mov     word [bp + R_BX], 1
        mov     byte [bp + R_CX + 1], 1 ; classe 1 : Ethernet (DIX)
        mov     byte [bp + R_CX], 0
        mov     word [bp + R_DX], 0FFFFh
        mov     [bp + R_DS], cs
        mov     word [bp + R_SI], nom_pilote
        mov     byte [bp + R_AX], 1     ; fonctions de base
        jmp     f_ok

; AH = 2 access_type : AL classe, BX type, DL numero, DS:SI type, CX longueur, ES:DI recepteur
f_acces:
        mov     ax, [bp + R_AX]
        cmp     al, 1
        je      .classe
        mov     dh, NO_CLASS
        jmp     f_erreur
.classe:
        mov     cx, [bp + R_CX]
        cmp     cx, 8
        jbe     .lg
        mov     dh, BAD_TYPE
        jmp     f_erreur
.lg:    mov     bx, abonnes
        mov     dx, 1                   ; numero de l'abonne (handle)
.cherche:
        cmp     byte [bx + abonne.actif], 0
        je      .libre
        add     bx, abonne_size
        inc     dx
        cmp     dx, MAX_HANDLES
        jbe     .cherche
        mov     dh, NO_SPACE
        jmp     f_erreur
.libre: mov     [bx + abonne.lg], cx
        mov     ax, [bp + R_DI]
        mov     [bx + abonne.recep], ax
        mov     ax, [bp + R_ES]
        mov     [bx + abonne.recep + 2], ax
        push    ds
        push    es
        push    cs
        pop     es
        lea     di, [bx + abonne.type]
        mov     si, [bp + R_SI]
        mov     ds, [bp + R_DS]
        cld
        rep     movsb
        pop     es
        pop     ds
        mov     byte [bx + abonne.actif], 1
        mov     [bp + R_AX], dx
        jmp     f_ok

; AH = 3 release_type : BX numero
f_libere:
        call    abonne_bx
        jc      .faux
        mov     byte [bx + abonne.actif], 0
        jmp     f_ok
.faux:  mov     dh, BAD_HANDLE
        jmp     f_erreur

; abonne_bx : BX (numero 1..MAX) de l'appelant -> BX = entree active ; CF = 1 sinon
abonne_bx:
        mov     ax, [bp + R_BX]
        dec     ax
        cmp     ax, MAX_HANDLES
        jae     .faux
        mov     bx, abonne_size
        mul     bx
        add     ax, abonnes
        mov     bx, ax
        cmp     byte [bx + abonne.actif], 0
        je      .faux
        clc
        ret
.faux:  stc
        ret

; AH = 6 get_address : ES:DI, CX longueur -> CX = 6
f_adresse:
        cmp     word [bp + R_CX], 6
        jae     .ok
        mov     dh, NO_SPACE
        jmp     f_erreur
.ok:    mov     es, [bp + R_ES]
        mov     di, [bp + R_DI]
        mov     si, mac_carte
        mov     cx, 6
        cld
        rep     movsb
        mov     word [bp + R_CX], 6
        jmp     f_ok

; AH = 24 get_statistics : DS:SI = compteurs
f_stats:
        mov     [bp + R_DS], cs
        mov     word [bp + R_SI], stats
        jmp     f_ok

; AH = 4 send_pkt : DS:SI trame Ethernet, CX longueur
f_envoi:
        mov     cx, [bp + R_CX]
        mov     si, [bp + R_SI]
        mov     ds, [bp + R_DS]
        cmp     cx, 14 + 20
        jb      .court
        cmp     word [si + 12], 0008h   ; type 0800h (IPv4), octets dans l'ordre du reseau
        je      .ip
        cmp     word [si + 12], 0608h   ; type 0806h (ARP)
        je      .arp
        jmp     f_ok                    ; autre : ignore
.court: cmp     cx, 14 + 28
        jb      .faux
        cmp     word [si + 12], 0608h
        je      .arp
.faux:  push    cs
        pop     ds
        mov     dh, CANT_SEND
        jmp     f_erreur
.arp:   call    arp_repond
        jmp     f_ok
.ip:    add     si, 14
        sub     cx, 14
        push    cs
        pop     es
        add     word [es:st_tx_paquets], 1
        adc     word [es:st_tx_paquets + 2], 0
        add     word [es:st_tx_octets], cx
        adc     word [es:st_tx_octets + 2], 0
        call    slip_envoie             ; DS:SI paquet IP, CX longueur
        push    cs
        pop     ds
        jmp     f_ok

; arp_repond : DS:SI requete ARP (trame Ethernet, CX >= 42). Requete (op = 1) : reponse
; prete pour le prochain tic (adresse du pair pour toute adresse IP demandee).
arp_repond:
        cmp     word [si + 20], 0100h   ; op = 1 (requete)
        jne     .r
        ; sonde de conflit d'adresse (mTCP au demarrage) : adresse demandee = celle de
        ; l'emetteur, ou emetteur sans adresse (0.0.0.0) : pas de reponse
        mov     ax, [si + 28]
        or      ax, [si + 30]
        jz      .r
        mov     ax, [si + 28]
        cmp     ax, [si + 38]
        jne     .repond
        mov     ax, [si + 30]
        cmp     ax, [si + 40]
        je      .r
.repond:
        push    es
        push    cs
        pop     es
        mov     di, arp_trame
        cld
        ; Ethernet : destination = carte, source = pair, type 0806h
        push    si
        push    ds
        push    cs
        pop     ds
        mov     si, mac_carte
        movsw
        movsw
        movsw
        mov     si, mac_pair
        movsw
        movsw
        movsw
        pop     ds
        pop     si
        mov     ax, 0608h
        stosw
        ; ARP : htype 1, ptype 0800h, hlen 6, plen 4, op 2
        mov     ax, 0100h
        stosw
        mov     ax, 0008h
        stosw
        mov     ax, 0406h
        stosw
        mov     ax, 0200h
        stosw
        ; sha = pair, spa = adresse demandee (tpa de la requete)
        push    si
        push    ds
        push    cs
        pop     ds
        mov     si, mac_pair
        movsw
        movsw
        movsw
        pop     ds
        pop     si
        push    si
        add     si, 38                  ; tpa de la requete
        movsw
        movsw
        pop     si
        ; tha = sha de la requete, tpa = spa de la requete
        push    si
        add     si, 22                  ; sha (6) puis spa (4)
        mov     cx, 5
        rep     movsw
        pop     si
        mov     byte [es:arp_pret], 1
        pop     es
.r:     ret

; slip_envoie : DS:SI paquet IP, CX longueur -> SLIP vers le module (INT 14h DX=1 AH=09h)
slip_envoie:
        push    es
        push    cs
        pop     es
        mov     word [es:tx_n], 0
        mov     al, SLIP_END
        call    tx_octet
        jcxz    .fin
.b:     lodsb
        cmp     al, SLIP_END
        jne     .pas_end
        mov     al, SLIP_ESC
        call    tx_octet
        mov     al, SLIP_ESC_END
        jmp     .ecrit
.pas_end:
        cmp     al, SLIP_ESC
        jne     .ecrit
        call    tx_octet
        mov     al, SLIP_ESC_ESC
.ecrit: call    tx_octet
        loop    .b
.fin:   mov     al, SLIP_END
        call    tx_octet
        call    tx_vide
        pop     es
        ret

; tx_octet : AL dans tx_bloc (ES = CS) ; plein : vide. Preserve CX, SI.
tx_octet:
        mov     di, [es:tx_n]
        mov     [es:tx_bloc + di], al
        inc     di
        mov     [es:tx_n], di
        cmp     di, 128
        jb      .r
        call    tx_vide
.r:     ret

; tx_vide : envoie tx_bloc au module. ES = CS. Preserve CX, SI.
tx_vide:
        push    cx
        push    si
        push    ds
        mov     cx, [es:tx_n]
        jcxz    .r
        mov     bx, tx_bloc
        mov     dx, 1
        mov     ah, 09h
        int     14h                     ; ES:BX, CX -> CX envoyes
        cmp     cx, [es:tx_n]
        je      .r
        add     word [es:st_erreurs_out], 1
        adc     word [es:st_erreurs_out + 2], 0
.r:     mov     word [es:tx_n], 0
        pop     ds
        pop     si
        pop     cx
        ret

; ------------------------------------------------------------------ INT 1Ch : reception
nouveau_1c:
        cmp     byte [cs:occupe], 0
        jne     .chaine
        mov     byte [cs:occupe], 1
        mov     [cs:pile_ss], ss                ; pile privee (celle du programme
        mov     [cs:pile_sp], sp                ; interrompu peut etre courte)
        cli
        push    cs
        pop     ss
        mov     sp, pile_haut
        sti
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        push    cs
        pop     ds
        push    cs
        pop     es
        cld
        cmp     byte [arp_pret], 0      ; reponse ARP en attente
        je      .lit
        mov     byte [arp_pret], 0
        mov     si, arp_trame
        mov     cx, 42
        call    remet
        mov     al, [blocs_tic]         ; blocs de 255 octets par tic : 1 (ATmega),
        mov     [blocs_reste], al       ; 16 (Pico W : ~1 ms le bloc)
.lit:   mov     bx, rx_bloc             ; octets recus du module (255 au plus)
        mov     cx, 255
        mov     dx, 1
        mov     ah, 08h
        int     14h
        cmp     ah, 0
        jne     .fin
        mov     si, rx_bloc
        jcxz    .fin
        push    cx
.o:     lodsb
        call    rx_octet
        loop    .o
        pop     cx
        cmp     cx, 255                 ; bloc plein : il en reste peut-etre
        jne     .fin
        dec     byte [blocs_reste]
        jnz     .lit
.fin:   pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        cli
        mov     ss, [cs:pile_ss]
        mov     sp, [cs:pile_sp]
        mov     byte [cs:occupe], 0
.chaine:
        jmp     far [cs:ancien_1c]

; rx_octet : AL, octet SLIP recu. Fin de paquet : remis aux abonnes. DS = ES = CS.
; Preserve CX, SI.
rx_octet:
        cmp     al, SLIP_END
        je      .fin
        cmp     byte [rx_esc], 0
        je      .pas_esc
        mov     byte [rx_esc], 0
        cmp     al, SLIP_ESC_END
        jne     .e2
        mov     al, SLIP_END
        jmp     .range
.e2:    cmp     al, SLIP_ESC_ESC
        jne     .range
        mov     al, SLIP_ESC
        jmp     .range
.pas_esc:
        cmp     al, SLIP_ESC
        jne     .range
        mov     byte [rx_esc], 1
        ret
.range: mov     di, [rx_lg]
        cmp     di, TRAME_MAX - 14
        jae     .trop
        mov     [rx_trame + 14 + di], al
        inc     word [rx_lg]
        ret
.trop:  mov     word [rx_lg], 0FFFFh    ; paquet trop long : ignore jusqu'au END
        ret
.fin:   mov     di, [rx_lg]
        mov     word [rx_lg], 0
        mov     byte [rx_esc], 0
        cmp     di, 20                  ; trame vide (END de debut) ou trop courte
        jb      .r
        cmp     di, 0FFFFh
        je      .perdu
        cmp     byte [rx_trame + 14], 45h       ; IPv4 sans options... ou avec
        jb      .perdu
        push    cx
        push    si
        mov     cx, di
        add     cx, 14
        mov     di, rx_trame            ; en-tete : destination = carte, source = pair,
        mov     si, mac_carte           ; type 0800h
        movsw
        movsw
        movsw
        mov     si, mac_pair
        movsw
        movsw
        movsw
        mov     ax, 0008h
        stosw
        mov     si, rx_trame
        add     word [st_rx_paquets], 1
        adc     word [st_rx_paquets + 2], 0
        add     word [st_rx_octets], cx
        adc     word [st_rx_octets + 2], 0
        call    remet
        pop     si
        pop     cx
.r:     ret
.perdu: add     word [st_erreurs_in], 1
        adc     word [st_erreurs_in + 2], 0
        ret

; remet : trame DS:SI (DS = CS), CX octets -> premier abonne dont le type correspond.
; Protocole de la specification : appel 1 (AX = 0, BX = numero, CX = longueur) -> ES:DI
; tampon (0:0 = refus) ; copie ; appel 2 (AX = 1, DS:SI = tampon rempli, CX = longueur).
remet:
        mov     bx, abonnes
        mov     dx, 1
.cherche:
        cmp     byte [bx + abonne.actif], 0
        je      .suivant
        push    cx
        mov     cx, [bx + abonne.lg]    ; type de longueur 0 : tout
        push    si
        lea     di, [bx + abonne.type]
        add     si, 12
        xor     ax, ax                  ; ZF = 1 (reste tel quel si CX = 0)
        repe    cmpsb
        pop     si
        pop     cx
        je      .trouve
.suivant:
        add     bx, abonne_size
        inc     dx
        cmp     dx, MAX_HANDLES
        jbe     .cherche
        add     word [st_perdus], 1     ; personne pour ce type
        adc     word [st_perdus + 2], 0
        ret
.trouve:
        push    bx
        push    cx
        push    si
        push    ds
        mov     ax, [bx + abonne.recep]
        mov     [recep_off], ax
        mov     ax, [bx + abonne.recep + 2]
        mov     [recep_seg], ax
        mov     bx, dx                  ; numero
        xor     ax, ax
        push    bx
        push    cx
        call    far [recep_off]         ; -> ES:DI
        pop     cx
        pop     bx
        mov     ax, es
        or      ax, di
        jz      .refus
        pop     ds
        pop     si
        push    si
        push    ds
        push    cx
        push    di
        rep     movsb
        pop     si                      ; DS:SI = tampon de l'abonne, rempli
        pop     cx
        push    es
        pop     ds
        mov     ax, 1
        call    far [cs:recep_off]
        jmp     .fini
.refus: add     word [cs:st_perdus], 1
        adc     word [cs:st_perdus + 2], 0
.fini:  pop     ds
        pop     si
        pop     cx
        pop     bx
        push    cs
        pop     es
        ret

blocs_tic:      db      1
blocs_reste:    db      0
recep_off:      dw      0
recep_seg:      dw      0

fin_residente:

; ------------------------------------------------------------------ installation
installe:
        mov     dx, txt_titre
        mov     ah, 09h
        int     21h
        ; BIOS 3.1 et ATmega v3 : lecture vide d'un bloc par INT 14h DX=1 -> AH = 0
        push    ds
        pop     es
        mov     bx, rx_bloc
        xor     cx, cx
        mov     dx, 1
        mov     ah, 08h
        int     14h
        cmp     ah, 0
        je      .bios_ok
        mov     dx, txt_bios
        jmp     .erreur
.bios_ok:
        ; BIOS 3.3 avec le Pico W : INT 14h DX=1 AH=0Ah rend AL = 50h (sinon 30h : etat)
        mov     dx, 1
        mov     ah, 0Ah
        int     14h
        cmp     al, 50h
        jne     .lien_ok
        mov     byte [blocs_tic], 16
        mov     dx, txt_pico
        mov     ah, 09h
        int     21h
.lien_ok:
        ; INT 60h deja pris par un pilote de paquets ?
        mov     ax, 3500h + VECTEUR
        int     21h                     ; ES:BX
        cmp     word [es:bx + 3], 'PK'
        jne     .libre
        cmp     word [es:bx + 5], 'T '
        jne     .libre
        mov     dx, txt_deja
        jmp     .erreur
.libre:
        mov     ax, 351Ch
        int     21h
        mov     [ancien_1c], bx
        mov     [ancien_1c + 2], es
        mov     dx, pd_entree
        mov     ax, 2500h + VECTEUR
        int     21h
        mov     dx, nouveau_1c
        mov     ax, 251Ch
        int     21h
        ; environnement libere
        mov     es, [2Ch]
        mov     ah, 49h
        int     21h
        mov     dx, txt_ok
        mov     ah, 09h
        int     21h
        mov     dx, (fin_residente - debut + 100h + 15) / 16
        mov     ax, 3100h
        int     21h
.erreur:
        mov     ah, 09h
        int     21h
        mov     ax, 4C01h
        int     21h

txt_titre:  db  'S02PKT - pilote de paquets SLIP (module Wi-Fi de Solution-02)', 13, 10, '$'
txt_pico:   db  'Lien : Pico W (BIOS 3.3, ports 50h-57h), 16 blocs par tic', 13, 10, '$'
txt_bios:   db  'Module absent : BIOS 3.1 et ATmega v3 ou plus requis.', 13, 10, '$'
txt_deja:   db  'Un pilote de paquets occupe deja INT 60h.', 13, 10, '$'
txt_ok:     db  'Installe sur INT 60h (classe Ethernet), MAC 02:53:30:32:00:02.', 13, 10
            db  'mTCP : PACKETINT 0x60, IPADDR 192.168.240.2, GATEWAY 192.168.240.1,', 13, 10
            db  '       NETMASK 255.255.255.0, NAMESERVER 8.8.8.8, MTU 576', 13, 10, '$'
