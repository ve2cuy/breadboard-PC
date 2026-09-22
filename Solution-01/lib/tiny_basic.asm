; ============================================================
; tiny_basic.asm
; Interpreteur TINY BASIC (Palo Alto Tiny BASIC) pour le 8088, lance par
; l'option "3) Tiny Basic" du menu principal (solution-01.asm) et
; pilote depuis le TERMINAL UART du PC (entree ET sortie).
;
; Ce fichier est une ADAPTATION de PATB86 (Palo Alto Tiny BASIC porte sur
; x86 par Amand Tihon, 2019 - https://codeberg.org/alrj/patb86, licence
; MIT), lui-meme base sur le Tiny BASIC 8080 de Li-Chen Wang (1976,
; "copyleft"). Le coeur de l'interpreteur (analyse, expressions, FOR/NEXT,
; GOSUB, INPUT, PRINT, LIST...) est conserve tel quel, avec ses
; commentaires d'origine; SEULS CHANGENT (voir plus bas): les entrees/
; sorties, la disposition memoire, le prefixe "tb_" de tous les noms (pour
; eviter tout conflit avec le reste du firmware), l'acces aux tables en ROM
; par CS, la commande BYE, la graine du generateur aleatoire et une
; comparaison non signee sur la pile.
;
; ---- LICENCES (a conserver dans toute copie) ---------------------------
;
; PATB86 - MIT License - Copyright (c) 2019 Amand Tihon
;
; Permission is hereby granted, free of charge, to any person obtaining a
; copy of this software and associated documentation files (the
; "Software"), to deal in the Software without restriction, including
; without limitation the rights to use, copy, modify, merge, publish,
; distribute, sublicense, and/or sell copies of the Software, and to
; permit persons to whom the Software is furnished to do so, subject to
; the following conditions:
;
; The above copyright notice and this permission notice shall be included
; in all copies or substantial portions of the Software.
;
; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
; OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
; IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
; CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
; TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
; SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
;
; L'oeuvre originale dont PATB86 est derive:
;     *********************************
;     TINY BASIC FOR INTEL 8080
;           VERSION 2.0
;         BY LI-CHEN WANG
;      MODIFIED AND TRANSLATED
;        TO INTEL MNEMONICS
;         BY ROGER RAUSKOLB
;          10 OCTOBER,1976
;            @COPYLEFT
;       ALL WRONGS RESERVED
;     *********************************
; Cette licence peut s'appliquer a une partie du logiciel, en particulier
; aux commentaires du code source copies textuellement.
; ------------------------------------------------------------------------
;
; ADAPTATIONS A CE PROJET
; -----------------------
; 1. SEGMENT DE TRAVAIL. PATB86 est un .COM DOS (DS=ES=SS=CS). Ici, la ROM
;    est en CS (et DS=CS en permanence dans le reste du firmware); tiny_basic
;    bascule donc DS=ES=SS=VAR_SEG (1000h) pour la duree de l'interpreteur
;    - comme un .COM, toutes les donnees et la pile vivent dans UN segment
;    de RAM - et restaure tout a la sortie. Les TABLES de commandes restent
;    en ROM et sont lues par CS ([cs:bx]); les messages (courts) sont copies
;    en RAM a l'entree pour que tb_prtstg (DS:SI) les affiche.
; 2. DISPOSITION du segment 1000h (voir les constantes tb_* ci-dessous):
;      0000h-00FFh  code injecte par Edit+Run RAM (jamais touche ici)
;      0100h-7DFFh  zone de texte du programme BASIC (32000 octets)
;      7E00h...     garde, tampon de ligne, variables A-Z, etat, messages
;      F000h-F410h  pile de l'interpreteur
;      F800h-FFFFh  variables du firmware (tampon d'edition, tampons
;                   circulaires PS/2 et UART, pile du menu...) - NON TOUCHE
;    La zone de texte est limitee a 32000 octets (comme l'original) pour
;    que SIZE reste positif en entier signe 16 bits.
; 3. ENTREES/SORTIES = TERMINAL UART UNIQUEMENT (le clavier PS/2 ne sert
;    pas: il n'a pas les lettres/symboles du BASIC). tb_outch -> uart_tx_byte
;    (CR est suivi d'un LF); tb_chkio -> uart_rx_available/uart_rx_byte
;    (Ctrl-C = retour a "Ok", Ctrl-X = retour au MENU); tb_getln = saisie de
;    ligne avec echo et retour arriere (BS ou DEL); LF et les autres
;    caracteres de controle sont ignores. Entree = CR.
; 4. PAS DE "HLT": l'original attend une interruption (tick BIOS 18,2 Hz)
;    dans sa boucle de saisie; ici aucune interruption periodique n'est
;    garantie (un octet deja recu ne reveillerait jamais un HLT) - tb_getln
;    scrute simplement le tampon UART. Le temps d'attente sert de graine au
;    generateur aleatoire (RND) - pas d'horloge materielle.
; 5. BYE (commande directe) et Ctrl-X quittent vers le menu principal.
; ============================================================
%ifndef TINY_BASIC_ASM
%define TINY_BASIC_ASM

%include "include/hardware.inc"
%ifndef TB_TEST                         ; le banc d'essai (tests/) fournit ses propres
%include "lib/uart.asm"                 ; uart_tx_byte / uart_rx_available / uart_rx_byte
%endif

%define TB_GOOD_RND 1                   ; generateur suggere par Trixter (voir tb_rnd)

; --- disposition du segment de travail (voir l'en-tete) ---
TB_SEG          equ     VAR_SEG                 ; 1000h
tb_txtbgn       equ     0100h                   ; debut du texte du programme
tb_txtend       equ     tb_txtbgn + 32000       ; fin (7E00h); le tableau @() descend depuis ici
tb_buffer       equ     tb_txtend + 4           ; tampon de ligne: 4 octets de garde (@(0) y tombe)
tb_bufend       equ     tb_buffer + 128
tb_varbgn       equ     tb_bufend + 4           ; 26 variables (A-Z), 1 mot chacune
tb_txtunf       equ     tb_varbgn + 52          ; mot: fin utilisee de la zone de texte
tb_currnt       equ     tb_txtunf + 2           ; mot: ligne courante
tb_stkgos       equ     tb_currnt + 2           ; mot: SP sauve par GOSUB
tb_varnxt       equ     tb_stkgos + 2           ; mot: temporaire
tb_stkinp       equ     tb_varnxt + 2           ; mot: SP sauve par INPUT
tb_lopvar       equ     tb_stkinp + 2           ; zone de sauvegarde FOR: variable
tb_lopinc       equ     tb_lopvar + 2           ;   increment
tb_loplmt       equ     tb_lopinc + 2           ;   limite
tb_lopln        equ     tb_loplmt + 2           ;   numero de ligne
tb_loppt        equ     tb_lopln + 2            ;   pointeur de texte
tb_ranseed      equ     tb_loppt + 2            ; double mot: graine de RND
tb_savsp        equ     tb_ranseed + 4          ; mot: SP de l'appelant (restaure a la sortie)
tb_escst        equ     tb_savsp + 2            ; octet: etat de l'analyse ESC de tb_getln (0/1/2)
tb_msg          equ     tb_escst + 2            ; messages (copies de la ROM, voir tb_rom_msg)
tb_stklmt       equ     0F000h                  ; limite basse de la pile
tb_stack        equ     0F410h                  ; sommet de la pile (1 Ko sous F800h)

; ============================================================
; tiny_basic
; Point d'entree (appele depuis le menu principal, DS=CS). Sauve tous les
; registres et segments, bascule en DS=ES=SS=TB_SEG avec une pile a
; TB_STACK, efface la memoire de programme (NEW) et les variables, affiche
; la banniere puis passe la main a l'interpreteur (tb_rstart, "Ok"/">").
; Retour au menu par BYE ou Ctrl-X (tb_exit).
; ============================================================
tiny_basic:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push es
    push ds
    cld

    mov ax, TB_SEG
    mov es, ax
    mov si, tb_rom_msg          ; messages ROM -> RAM (DS=CS a ce stade)
    mov di, tb_msg
    mov cx, tb_rom_end - tb_rom_msg
    rep movsb

    mov ds, ax                  ; DS = ES = SS = TB_SEG des maintenant
    mov [tb_savsp], sp          ; SP de l'appelant (SS est deja TB_SEG)
    mov sp, tb_stack

    mov di, tb_varbgn           ; variables A-Z remises a 0
    mov cx, 26
    xor ax, ax
    rep stosw
    mov word [tb_ranseed], 0ACE1h       ; graine initiale (non nulle), brassee
    mov word [tb_ranseed+2], 5A5Ah      ; ensuite par le temps d'attente de tb_getln
    sti                         ; l'UART recu arrive par interruption (IR1)

tb_purge:
    mov word [tb_txtunf], tb_txtbgn     ; Purge text area

tb_tell:
    xor ah, ah
    mov si, tb_msg
    call tb_prtstg              ; Tell user.
    mov si, tb_hint
    call tb_prtstg

; ------------------------------------------------------------------------
; Direct command / Text collecter (le reste est le code de PATB86)
; ------------------------------------------------------------------------
tb_rstart:
    xor ax, ax
    mov sp, tb_stack               ; Stack is cleared
    mov [tb_currnt], ax            ; Current line # = 0
    mov [tb_lopvar], ax            ; Loop params are cleared
    mov [tb_stkgos], ax            ; Gosub return address is cleard
    
    mov si, tb_ok
    call tb_prtstg                 ; Print "Ok"
    
    
tb_prompt_loop:
    mov al, '>'                 ; Prompt > and
    call tb_getln                  ; read a line. di -> end of line
    
    mov si, tb_buffer              ; si -> beginning of line
    call tb_tstnum                 ; test if it is a number
    push ax
    call tb_ignblnk
    pop ax                      ; ax = value of # or 0 if no # was found
    or cl, cl                   ; any digits ?
    jz tb_direct                   ; if not, it's a direct command/statement
    
    ; At this point, we have a numbered line to store in the text area.
    ; ax contains the line number.
    ; si points to the first char of the statement to store
    ; di still points to the end of the line (after the CR)
    dec si
    dec si                      ; move si back two bytes
    mov [si], ax                ; and prepend value of line number there
    mov bx, si                  ; bx -> begin, including line #
    mov dx, di                  ; dx -> line end
    call tb_fndln                  ; find this line in save 
    push si                     ; area, si-> save area
    jnz .insert_line            ; NZ: line was not found, insert it
    
    push si                     ; Z: found the line, delete it
    call tb_fndnxt                 ; si -> start of line to keep
    pop di                      ; di-> line to be deleted
    mov cx, [tb_txtunf]            ; to the end of the save area
    sub cx, si                  ; how many bytes to move ?
    rep movsb                   ; move them
    mov [tb_txtunf], di            ; update value

.insert_line:                   ; get ready to insert
    pop ax                      ; ax-> start of line to move down
    sub dx, bx                  ; first check if lenght of line is 3 (# and CR)
    cmp dx, 3                   ; Then, do not insert, only delete and
    je tb_rstart                   ; clear the stack.
    
    mov cx, [tb_txtunf]
    mov si, cx
    sub cx, ax                  ; cx=amount of bytes to move down
    
    mov di, si
    dec si                      ; si-> current last byte of text save area
    add di, dx                  ; di-> new txtunf
    cmp di, tb_txtend              ; check if there is enough space
    jae tb_qsorry                  ; sorry, no room for it
    mov [tb_txtunf], di            ; ok, update it
    dec di                      ; di-> new last byte of text save area
    std                         ; Move backward !
    rep movsb                   ; move all the bytes
    cld                         ; restore forward direction
    
    mov cx, dx                  ; dx was still the length of the buffer line
    mov di, ax                  ; ax was still the place to insert it
    mov si, bx                  ; bx was still pointing to the text to insert
    rep movsb                   ; finally store the new line
    
    jmp tb_prompt_loop


;========================================================================
; Direct and exec
;
; This section of the code tests a string against a table. When a
; match is found, control is transfered to the section of code
; according to the table.
;
; At 'exec', si should point to the string and bx should point to the table.
; At 'direct', si should point to the string and bx will be set up to point to
; 'table1', which is the table of all direct and statements commands.
;
; A '.' in the string will terminate the test and the partial match will be 
; considered as a match, e.g. 'P.', 'PR.', 'PRI.', 'PRIN.', or 'PRINT' will all
; match 'PRINT'.
;
; The table consists of any number of items, each item is a null-terminated 
; string, and a pointer to a jump address.
;
; End of table is an empty string with a jump address. If the string does not
; match any of the other items, it will match this null item as default.

tb_direct:
    mov bx, tb_table1              ; Direct command execution

tb_exec:
    call tb_ignblnk

.ex_loop:
    push si                     ; save pointer
    
.ex_testchar:
    lodsb                       ; if found '.' in string before any mismatch
    cmp al, '.'                 ; we declare a match.
    je .ex_partial_match

    mov ah, [cs:bx]
    inc bx
    or al, 20h                  ; lowercase al
    
    cmp al, ah                  ; Characters are still matching ?
    je .ex_testchar             ; then test next one
    
    or ah, ah                   ; else, see if we checked against the whole
    jz .ex_match                ; table item. Yes? then we have a match.
    
.ex_skip:                       ; else, match failed, bump to next table entry
    mov ah, [cs:bx]             ;
    inc bx                      ; Find the end of this non-matching string
    or ah, ah                   ; 
    jnz .ex_skip                ; 
    inc bx
    inc bx                      ; Get past the jump address
    pop si                      ; Restore string pointer
    jmp .ex_loop                ; Test against next item.
    
.ex_partial_match:              ; Partial match.
    mov ah, [cs:bx]             ; Find jump address which is after the null
    inc bx
    or ah, ah                   ; byte terminating the string
    jnz .ex_partial_match       ; more character to consume
    jmp .ex_end                 ; we're at the end
    
.ex_match:                      ; full match. 
    dec si                      ; si needs to go back one byte

.ex_end:
    pop ax                      ; Dummy pop to restore stack state
    jmp [cs:bx]                 ; And we go to it


;=========================================================================
; What follows is the code to execute direct and statement commands.
; Control is transfered to these points via the command table lookup code
; of "direct" and "exec" in last section. After the command is executed,
; control is transfered to other setions as follow:
;
; For 'list', 'new', and 'stop': go back to 'rstart'.
; For 'run': go execute the first stored line if any; 
;            else go back to 'rstart'.
; For 'goto' and 'gosub': go execute the target line.
; For 'return' and 'next': go back to saved return line.
; For all others: if 'currnt' -> 0, go to 'rstart', else go execute next
;                 command. (This is done in 'finish').

; 'new(CR)' reset 'textunf'
tb_new:
    call tb_endchk
    jmp tb_purge
    
    
; 'stop(CR)' goes back to 'rstart'
tb_stop:
    call tb_endchk
    jmp tb_rstart


; 'run(CR)' finds the first stored line, store its address (in 'currnt') 
; and start execute it. Note that only those commands in 'table2' are 
; legal for a stored program.
; 
; There are three more entries in 'run':
; 'runnxl' finds next line, store its address in si and executes it.
; 'runtsl' stores the address of this line and executes it.
; 'runsml' continues the execution on same line
tb_run:
    call tb_endchk
    mov si, tb_txtbgn              ; first saved line

tb_runnxl:
    xor ax, ax                  ; 
    call tb_fndlnp                 ; find whatever line # at [si] or after
    jc tb_rstart                   ; C: passed txtunf, quit
    
tb_runtsl:
    mov [tb_currnt], si            ; store address of current line (-> the line #)
    inc si
    inc si                      ; bump pass the line #
    
tb_runsml:
    call tb_chkio                  ; Check for Control-X
    mov bx, tb_table2              ; find command in table2
    jmp tb_exec                    ; and execute it
    
    
; 'goto expr(CR)' evaluates the expression, find the target line and 
; jump to 'runtsl' to do it.
tb_goto:
    call tb_exp
    push si                     ; save for error routine
    call tb_endchk                 ; must find a CR
    mov ax, bx                  ; the result of the call to expr is the line #
    call tb_fndln                  ; find the target line
    jnz tb_ahow                    ; No such line #
    pop ax                      ; dummy pop to clean up stack
    jmp tb_runtsl                  ; go do it


;=========================================================================
; List has three forms:
; 'list(CR) lists all saved lines
; 'list N(CR) starts list at line N
; list N1, N2(CR) starts list at line N1 for N2 lines.
; You can stop the listing with Control-C.
tb_list:
    call tb_tstnum                 ; Test if there is a line #
    push ax
    call tb_ignblnk
    xor cx, cx                  ; default value: 0
    cmp al, ','                 ; Do we have N2 as well ?
    jne .no_n2                  ; if we don't, 
    
    inc si                      ; if we do, go past the ',' 
    call tb_tstnum                 ; and get that second number
    mov cx, ax                  ; overwrite the default value
    
.no_n2:
    call tb_endchk                 ; Error if there's more on the line
    pop ax                      ; Get first line # back
    call tb_fndln                  ; Find this line or next line
.list_loop:
    jc tb_rstart                   ; C: passed textunf
    
    call tb_prtln                  ; Print line #
    call tb_prtstg                 ; Print line text
    dec cx                      ; Decrement the line counter
    jz tb_rstart                   ; If N2 lines have been printed, we are done
    call tb_chkio                  ; Interrupted ?
    xor ax, ax                  ; Don't need the line # anymore, we're further
    call tb_fndlnp                 ; Find next line
    jmp .list_loop
    

; Print command is "PRINT ....;" or "PRINT ....(CR)"
; Where '....' is a list of expressions, formats, and/or strings.
; These items are separated by commas.
;
; A format is a hash sign followed by a number. It controls the
; number of spaces the value of an expression is going to be printed.
; It stays effective for the rest of the PRINT command, unles changed
; by another format. If no format is specified, 6 positions will be used.
;
; A string is quoted in a pair of single quotes or a pair of double quotes.
;
; Control characters and lower case letters can be included inside the 
; quotes. Another (better) way of generating control characters on
; the output is use the caret character followed by a letter. ^[ is ESC,
; ^H is Backspace, ^G is BELL, etc.
;
; A (CRLF) is generated after the entire list has been printed or if
; the list is a null list. However, if the list ended with a comma, no 
; (CRLF) is generated.
tb_print:
    mov cl, 6                   ; cl = # of spaces
    call tb_ignblnk
    cmp al, ";"                 ; if null list and ';'
    jne .pr1
    call tb_crlf                   ; give CR-LF,
    inc si                      ; eat the character, and
    jmp tb_runsml                  ; continue same line
.pr1:
    cmp al, 0dh                 ; if null list (CR)
    jne .pr6
    call tb_crlf                   ; also give CR-LF,
    inc si                      ; eat the character, and
    jmp tb_runnxl                  ; go to next line
.pr2:
    cmp al, '#'                 ; Else, is it format?
    jne .pr4
    inc si                      ; Eat the character
.pr3:
    call tb_exp                    ; Yes, evaluate expression
    cmp bx, 63                  ; Maximum 63
    jae tb_qhow                    ; Unsigned comparison matches negative values
    mov cl, bl                  ; set new format
    jmp .pr5                    ; Look for more to print
.pr4:
    call tb_qtstg                  ; Or is it a string?
    jc .pr9                     ; If not, must be expr.
.pr5:
    call tb_ignblnk
    cmp al, ','                 ; if ',' go find next
    jne .pr8
.pr6:
    cmp al, ','                 ; if comma
    jne .pr7
    ;mov al, ' '                 ; print a space
    ;call outch
    inc si                      ; eat the character
    call tb_ignblnk
    jmp .pr6
.pr7:
    call tb_fin                    ; Are we done ?
    jmp .pr2                    ; list continues
.pr8:
    call tb_crlf                   ; list ends
    jmp tb_finish
.pr9:
    push cx                     ; Save cl (format)
    call tb_exp                    ; Evaluate the expression
    pop cx                      ; Restore cl
    xchg ax, bx                 ; put value in ax
    call tb_prtnum                 ; Print the value
    xchg ax, bx                 ; get everyting back in place
    jmp .pr5


;=========================================================================
; 'gosub expr;' or 'gosub expr(CR)' is like the 'goto' command,
; except that the current text pointer, stack pointer, etc. are saved so
; that execution can be continued after the subroutine 'return'. In
; order that 'gosub' can be nested (and even recursive), the save area
; must be stacked. The stack pointer is saved in 'stkgos'. The old
; 'stkgos' is saved in the stack. If we are in the main routine,
; 'stkgos' is zero (this is done by the "main" section of the code),
; but we still save it as a flag for no further 'return's.
tb_gosub:
    call tb__pusha                 ; Save the current "for" parameters
    call tb_exp
    push si                     ; and text pointer
    mov ax, bx
    call tb_fndln                  ; Find the target line
    jnz tb_ahow                    ; Not there, say "How?"
    mov ax, [tb_currnt]            ; save old
    push ax                     ; "currnt", old "stkgos"
    mov ax, [tb_stkgos]
    push ax
    xor ax, ax                  ; And load new ones
    mov [tb_lopvar], ax
    mov [tb_stkgos], sp
    jmp tb_runtsl                  ; Then run that line


; 'return(CR)' undos everything that 'gosub' did, and thus return the
; execution to the command after the most recent 'gosub'. If 'stkgos'
; is zero, it indicates that we never had a 'gosub' and is thus an
; error.
tb_return:
    call tb_endchk                 ; There must be a CR
    mov ax, [tb_stkgos]            ; Old stack pointer
    or ax, ax                   ; 0 means not exist
    jz tb_qwhat                    ; so, we say: "What?"
    mov sp, ax                  ; else, restore it
    pop ax
    mov [tb_stkgos], ax            ; and the old "stkgos"
    pop ax
    mov [tb_currnt], ax            ; and the old "currnt"
    pop si                      ; old text pointer
    call tb__popa                  ; old "for" parameters
    jmp tb_finish


;=========================================================================
; 'for' has two forms: "for var=exp1 to exp2 step exp3" and "for
; var=exp1 to exp2". The second form means the same thing as the first
; form with exp3=1. (i.e., with a step of +1.) TBI will find the
; variable var. and set its value to the current value of exp1. It 
; also evaluates exp2 and exp3 and save all these together with the
; 'lopvar', 'lopinc', 'loplmt', 'lopln', and 'loppt'. If there is
; already somthing in the save area (this is indicated by a
; non-zero 'lopvar'), then the old save area is saved in the stack
; before the new overwrites it. TBI will then dig in the stack
; and find out if this same variable was used in another currently
; active "for" loop. If that is the case, then the old "for" loop is
; deactivated (purged from the stack).
tb_for:
    call tb__pusha                 ; Save the old save area
    call tb_setval                 ; Set the control var.
    mov [tb_lopvar], di            ; di is its address, save that
    
    mov bx, tb_table4              ; Use 'exec' to look
    jmp tb_exec                    ; for the word "to"

tb_for_to:
    call tb_exp                    ; Evaluate the limit
    mov [tb_loplmt], bx            ; store that
    
    mov bx, tb_table5              ; Use 'exec' to look
    jmp tb_exec                    ; for the word "step"

tb_for_step:
    call tb_exp                    ; found it, get step
    jmp tb_fr4
tb_fr3:
    mov bx, 1                   ; Not found, set to 1

tb_fr4:
    mov [tb_lopinc], bx            ; save that too
    mov ax, [tb_currnt]            ; save current line #
    mov [tb_lopln], ax
    mov [tb_loppt], si             ; and text pointer

    mov bp, sp                  ; Here is the stack
    xor cx, cx                  ; Level counter
    jmp .fr6

.fr5:
    add bp, 10                  ; Each level is 10 deep

.fr6:
    add cx, 10                  ; One more level
    mov ax, [bp]                ; Get that old 'lopvar'
    or ax, ax
    jz .fr7                     ; 0 says no more in it
    cmp ax, [tb_lopvar]            ; Same as this one ?
    jne .fr5                    ; No, check further
    
    mov ax, ds                  ; save segment register
    mov bx, ss
    mov ds, bx
    mov es, bx                  ; ds and es = ss
    
    add sp, 10                  ; Try to move sp
    
    mov si, bp
    dec si                      ; point to last byte of previous frame
    mov di, si
    add di, 10                  ; To be moved 10 bytes (5 words) further
    std                         ; Move backward
    rep movsb                   ; Purge 10 bytes
    cld                         ; Restore forward direction
    
    mov ds, ax
    mov es, ax                  ; restore segment registers
.fr7:
    mov si, [tb_loppt]             ; Job done, restore si
    jmp tb_finish                  ; and continue


; "next var" serves as the logical (not necessarily physical) end of
; the "for" loop. The control variable var. is checked with the
; 'lopvar'. If they are not the same, TBI digs in the stack to find
; the right one and purges all those that did not match. Either way,
; TBI then adds the 'step' to that variable and checks the result with
; the limit. If it is within the limit, control loops back to the
; command following the "for". If outside the limit, the save area is
; purged and execution continues.
tb_next:
    call tb_tstv                   ; Get address of var.
    jc tb_qwhat                    ; No variable, say "What?"
    mov [tb_varnxt], bx            ; Yes, save it

.nx1:
    push si                     ; Save text pointer
    mov ax, [tb_lopvar]            ; Get var. in 'for'
    or ax, ax                   ; 0 says never had one
    jz tb_awhat                    ; so we ask: "What?"
    cmp ax, bx                  ; else, check them
    je .nx2                     ; OK, they agree
    pop si                      ; No, let's see
    call tb__popa                  ; Purge current loop
    jmp .nx1                    ; and go check again

.nx2:                           ; Come here when agreed
    mov dx, [bx]                ; dx = value of var.
    mov ax, [tb_lopinc]
    add dx, ax                  ; Add one step
    mov [bx], dx                ; Put it back
    jo .nx6                     ; Any overflow means we're out
    
    or ax, ax                   ; Are we going up to
    js .nx_downto               ; or down to the limit?
    cmp dx, [tb_loplmt]            ; Compare with limit
    jg .nx6                     ; outside limit (going up)
    jmp .nx4
    
.nx_downto:
    cmp dx, [tb_loplmt]            ; Compare with limit
    jl .nx6                     ; outside limit (going down)

.nx4:
    pop si                      ; dummy pop to cleanup stack
    mov ax, [tb_lopln]             ; Within limit, go
    mov [tb_currnt], ax            ; back to the saved
    mov si, [tb_loppt]             ; 'currnt' and text pointer
    jmp tb_finish

.nx6:
    pop si
    call tb__popa                  ; Purge this loop
    jmp tb_finish


;=========================================================================
; 'rem' can be followed by anything and is ignored by TBI. TBI treats 
; it like an 'if' with a false condition.
tb_rem:
    xor bx, bx
    jmp tb_iff.if1                 ; This is like "IF 0"


; 'if' is followed by an expr. as a condition and one or more commands
; (including other 'if's) separated by semi-colons. Note that the
; word 'then' is not used. TBI evaluates the expr. If it is non-zero,
; the execution continues. If the expr. is zero, the commands that
; follows are ignored and execution continues at the next line.
tb_iff:
    call tb_exp
.if1:
    or bx, bx                   ; is the expr. = 0 ?
    jnz tb_runsml                  ; no, continue
    xor ax, ax
    call tb_fndskp                 ; yes, skip rest of line
    jnc tb_runtsl                  ; and run the next line
    jmp tb_rstart                  ; if no next, re-start
    

; 'input' command is like the 'print' command, and is followed by a
; list of items. If the item is a string in single or double quotes,
; or is a caret, it has the same effect as in 'print'. If an item
; is a variable, this variable name is printed out followed by a
; colon. Then TBI waits for an expr. to be typed in. The variable is
; then set to the value of this expr. If the variable is preceded by
; a string (again in single or double quotes), the string will be
; printed folloed by a colon. TBI then waits for input expr. and
; set the variable to the value of the expr.
;
; If the input expr. is invalid, TBI will print "What?", "How?" or
; "Sorry." and reprint the prompt and redo the input. The execution
; will not terminate unless you type CTRL-C. This is handled in
; 'inperr'.
tb_inperr:
    mov sp, [tb_stkinp]            ; Restore old sp
    pop ax
    mov [tb_currnt], ax            ; and old 'currnt'
    pop si                      ; and old text pointer
    pop si                      ; redo input


tb_input:
    push si                     ; save in case of error
    call tb_ignblnk
    call tb_qtstg                  ; Is next item a string?
    jc .ip8                     ; No
.ip2:
    call tb_tstv                   ; Yes, but followed by a
    jc .ip5                     ; variable?  No.
    mov di, bx                  ; destination variable in di

.ip3:
    call .ip12
    mov si, tb_buffer              ; Point to buffer
    call tb_exp                    ; evaluate input
    call tb_endchk
    pop di                      ; OK, get old di (variable address)
    mov [di], bx                ; save value in var
    pop ax
    mov [tb_currnt], ax            ; get old 'currnt'       **
    pop si                      ; and old text pointer  *

.ip5:
    pop ax                      ; purge junk in stack (si in case of error)
    call tb_ignblnk
    cmp al, ','                 ; Is next char ',' ?
    jne tb_finish
    inc si                      ; Eat the ',' character
    jmp tb_input                   ; Yes, more items.
    
.ip8:
    push si                     ; save fot prtstg
    call tb_tstv                   ; Must be variable now
    jc tb_qwhat                    ; "What?" It is not?
    mov di, bx                  ; destination variable
    mov bx, si                  ; end mark for prtchs
    pop si
    call tb_prtchs                 ; print those as prompt
    jmp .ip3                    ; Yes, input variable
    
.ip12:
    pop bp                      ; return address
    push si                     ; save text pointer     *
    mov ax, [tb_currnt]
    push ax                     ; also save 'currnt'     **
    mov word [tb_currnt], 0xffff   ; use -1 as flag (for 'error')
    mov [tb_stkinp], sp            ; save sp too
    push di                     ; destination variable
    mov al, ' '                 ; print a space
    push bp
    jmp tb_getln                   ; and get a line
    ; jmp above, no need to ret here.


; 'let' is followed by a list of items separated by commas. Each item
; consists of a variable, an equal sign, and an expr. TBI evaluates
; the expr. and set the variable to that value. TBI will also handle
; 'let' command without the word 'let'. This is done by 'deflt'.
tb_deflt:
    mov al, [si]                ; *** deflt ***
    cmp al, 0dh                 ; Empty line is OK
    je tb_finish
tb_let:                            ; Else it is "let"
    call tb_setval                 ; Set value to var
    call tb_ignblnk
    cmp al, ','                 ; item by item
    jne tb_finish                  ; until finish
    inc si
    jmp tb_let
    
    
;=========================================================================
; expr: Expression parser
;
; 'exp' evaluates arithmetical or logical expressions.
; <exp>::=<expr1>
;         <expr1><rel.op><expr1>
; where <rel.op> is one of the operators in table6 and the result of these 
; operations is 1 if true and 0 if false.
; <expr1>::=(+ or -)<expr2>(+ or -<expr2>)(...)
; where () are optional and (...) are optional repeats.
; <expr2>::=<expr3>(<* or /><expr3>)(...)
; <expr3>::=<variable>
;           <function>
;           <digit>
;           (<exp>)
; <exp> is recursive so that variable '@' can have an <exp> as index, 
; functions can have an <exp> as argument, and
; <expr3> can be <exp> in parenthesis.

tb_exp:
    call tb_expr1                  ; *** expr1 ***
    push bx                     ; save <expr1> value
    mov bx, tb_table6              ; Look up rel. op.
    jmp tb_exec                    ; Go do it
tb_expr_ge:                        ; Rel.op. ">="
    call tb_xpr8                   ; 
    pop ax                      ; restore 1st <expr1> in ax
    cmp ax, dx                  ; Make the comparison here
    jge tb_xpr_true                ; True
    ret                         ; Otherwise return with the default False
tb_expr_ne:                        ; Rel.op. "#"
    call tb_xpr8
    pop ax                      ; restore 1st <expr1> in ax
    cmp ax, dx                  ; Make the comparison here
    jne tb_xpr_true
    ret
tb_expr_g:                         ; Rel.op. ">"
    call tb_xpr8
    pop ax                      ; restore 1st <expr1> in ax
    cmp ax, dx                  ; Make the comparison here
    jg tb_xpr_true
    ret
tb_expr_eq:                        ; Rel.op. "="
    call tb_xpr8
    pop ax                      ; restore 1st <expr1> in ax
    cmp ax, dx                  ; Make the comparison here
    je tb_xpr_true
    ret
tb_expr_le:                        ; Rel.op. "<="
    call tb_xpr8
    pop ax                      ; restore 1st <expr1> in ax
    cmp ax, dx                  ; Make the comparison here
    jle tb_xpr_true
    ret
tb_expr_lt:                        ; Rel.op. "<"
    call tb_xpr8
    pop ax                      ; restore 1st <expr1> in ax
    cmp ax, dx                  ; Make the comparison here
    jl tb_xpr_true
    ret
tb_xpr7:
    pop bx                      ; not Rel.op.
    ret                         ; Return value=<expr1>
tb_xpr8:                           ; Subroutine for all Rel.ops.
    call tb_expr1                  ; Get 2nd <expr1>
    mov dx, bx                  ; use dx for the test
    xor bx, bx                  ; Prepare a 'false' value by default
    ret
tb_xpr_true:
    mov bl, 1                   ; Return 'true' value
    ret

tb_expr1:
    call tb_ignblnk
    cmp al, '-'                 ; Negative sign ?
    jne .xp11
    xor bx, bx                  ; Yes, fake "0-"
    jmp .xp16                   ; Treat like substract
.xp11:
    cmp al, '+'                 ; Positive sign ? Ignore
    jne .xp12
    inc si                      ; (but eat it still)
.xp12:
    call tb_expr2                  ; 1st <expr2>
.xp13:
    call tb_ignblnk
    cmp al, '+'                 ; Add?
    jne .xp15
    push bx                     ; Yes, save value
    inc si                      ; and eat the + character
    call tb_expr2                  ; get 2nd <expr2>
    pop ax
    add bx, ax
    jo tb_qhow                     ; Dow we have an overflow ?
    jmp .xp13                   ; Look for more terms
.xp15:
    cmp al, '-'                 ; subtract ?
    jne .xp17
.xp16:
    push bx                     ; yes, save 1st <expr2>
    inc si                      ; Eat the - character
    call tb_expr2                  ; Get the second <expr2>
    pop ax                      ; Restore 1st term
    xchg ax, bx                 ; exchange 1st and 2nd terms
    sub bx, ax                  ; subtract the second from the first
    jo tb_qhow                     ; Do we have an overflow ?
    jmp .xp13                   ; Look for more terms

.xp17:
    ret


tb_expr2:
    call tb_expr3                  ; Get 1st <expr3>
.xp21:
    call tb_ignblnk
    cmp al, '*'                 ; Multiply ?
    jne .xp24
    push bx                     ; Yes, save 1st
    inc si                      ; (eat the * character)
    call tb_expr3                  ; and get second <expr3>
    pop ax                      ; and 1st in ax
    imul bx                     ; dx:ax = ax*bx
    jo tb_qhow                     ; signed result does not fit ax
    mov bx, ax
    jmp .xp21                   ; Look for more terms
.xp24:
    cmp al, '/'                 ; Divide ?
    jne .xp25
    push bx                     ; Yes, save 1st
    inc si                      ; (eat the / character)
    call tb_expr3                  ; and get 2nd <expr3> in bx
    pop ax                      ; get 1st in ax
    or bx, bx                   ; Divide by 0 ?
    jz tb_qhow                     ; say "How?"
    cwd                         ; convert word in ax into dword in dx:ax
    idiv bx                     ; divide
    mov bx, ax                  ; return result in bx
    jmp .xp21                   ; Look for more terms
.xp25:
    ret                         ; Done.

    
tb_expr3:                          
    mov bx, tb_table3              ; Find function in table3
    jmp tb_exec
tb_notf:                           ; No, not a function
    call tb_tstv                   ; Is it a variable ?
    jc .xp32                    ; Nor a variable
    mov bx, [bx]                ; Load variable value in bx
    ret
.xp32:
    call tb_tstnum                 ; or is it a number ?
    or cl, cl
    jz tb_parn                     ; No digit, must be "(expr)"
    mov bx, ax                  ; OK, digit in bx
    ret
    

tb_parn:                           ; "(expr)" at si->
    lodsb                       ; eat the character
    cmp al, '('                 ; is it '(' ?
    jne tb_qwhat                   ; no, say "what?"
    call tb_exp                    ; evaluate expression
    lodsb                       ; eat the character
    cmp al, ')'                 ; is it ')' ?
    jne tb_qwhat                   ; no, say "what?"
    ret

;=========================================================================
; Functions.

tb_rnd:                            ; Simple pseudo-random generator
    call tb_parn
    cmp bx, 0                   ; expr must be strictly positive
    jng tb_qhow                    ; or it is an error.

    ; RND implementations suggested by Trixter on 
    ; http://www.vcfed.org/forum/showthread.php?40098-Palo-Alto-Tiny-Basic-Download&p=302299#post302299
%ifdef TB_GOOD_RND
    ; *** "This claims 2^31-1 repeatability but I've never verified it."
    push bx
    mov ax, [tb_ranseed+2]
    mov dx, [tb_ranseed]
    mov bx, ax
    mov cx, dx
    shl cx, 1                   ; )
    shl cx, 1                   ; > original was shl cx, 3
    shl cx, 1                   ;_)________________________
    shr bh, 1                   ; )
    shr bh, 1                   ; \ original was shr bh, 4
    shr bh, 1                   ; /
    shr bh, 1                   ; )
    or cl, bh
    xor dx, cx
    not dx
    shl dx, 1
    rcl ax, 1
    shr dx, 1
    mov [tb_ranseed], ax
    mov [tb_ranseed+2], dx
    pop bx
    jmp .rnd_modulo
%else
    ; *** "Another way, if you don't care too much about periodicity and 
    ;      just want small fast results:"
    mov ax, [tb_ranseed]           ;
    add ax, 9248h               ; 1001001001001000b (visual rep)
    ror ax, 1
    ror ax, 1
    ror ax, 1
    mov [tb_ranseed], ax           ; Quick and dirty, it should be improved.
%endif

.rnd_modulo:
    xor dx, dx
    div bx                      ; we tested the arg. to be positive
    mov bx, dx                  ; remainder of the division by the argument
    inc bx                      ; value must be in range [1..arg] inclusive.
    ret

tb__abs:
    call tb_parn                   ; abs(expr)
    or bx, bx                   ; Prepare for comparison
    jns .pos                    ; Is it already positive ?
    neg bx                      ; it's signed, then neg it
.pos:
    ret


tb_size:
    mov bx, tb_txtend              ; Get the number of free bytes between txtunf
    sub bx, [tb_txtunf]            ; and txtend
    ret

;=========================================================================
; 'divide', 'subde', 'chksgn', 'chgsgn' and 'ckhlde' are unneeded.


;=========================================================================
; 'setval' expects a variable, followed by an equal sign and then an
; expr. It evaluates the expr. and set the variable to that value.
tb_setval:
    call tb_tstv
    jc tb_qwhat                    ; "What?" no variable
    push bx                     ; save address of var
    call tb_ignblnk
    cmp al, '='                 ; pass "=" sign
    jne tb_qwhat
    inc si                      ; Eat the character
    call tb_exp                    ; Evaluate expression
    pop di
    mov [di], bx                ; Save value
    ret


; 'fin' checks the end of a command. If it ended with ";", execution
; continues. If it ended with a CR, it finds the next line and
; continue from there.
tb_finish:
    call tb_fin                    ; Check end of command
    jmp tb_qwhat                   ; Print "What?" if wrong
tb_fin:
    call tb_ignblnk
    cmp al, ';'
    jne .fi1
    pop ax                      ; dummy pop, purge ret. address
    inc si                      ; Eat the character
    jmp tb_runsml                  ; continue same line
.fi1:
    cmp al, 0dh                 ; not ";", is it CR?
    jne .fi2
    pop ax                      ; dummy pop, purge ret. address
    inc si                      ; eat the character
    jmp tb_runnxl                  ; Run next line
.fi2:
    ret                         ; Else, return to caller


; 'ignblnk' ignore blanks in text -> si by advancing si to the first non-blank
; character. 
; That character is also returned in al
tb_ignblnk:
    lodsb                       ; Load character
    cmp al, ' '                 ; is it a space ?
    je tb_ignblnk                  ; Then continue
    dec si                      ; Otherwise, move si back to that character
    ret                         ; And return with the char in al


; 'endchk' checks if a command is ended with CR. This is required on certain 
; commands (GOTO, RETURN, STOP, etc.)
tb_endchk:                         ; *** end check ***
    call tb_ignblnk
    cmp al, 0dh                 ; End with CR ?
    jne tb_qwhat                   ; if no, say "what?"
    ret                         ; else, simply return
    

; Related to 'error' are the following: 'qwhat' saves text pointer in
; stack and get message "What?". 'awhat' just get message "What?" and
; jump to 'error'. 'qsorry' and 'asorry' do same kind of thing.
; 'qhow' and 'ahow' also do this.
tb_qwhat:
    push si
tb_awhat:
    mov si, tb_what
    ; and continue to error here below
    
; 'error' prints the string pointed by dx (and ends with CR). It then 
; prints the line pointed by 'currnt' with a "?" inserted at where the
; old text pointer (should be on top of the stack) points to. 
; Execution of TB is stopped and TBI is restarted. However, if 
; 'currnt' -> 0 (indicating direct command), the direct command is not 
; printed. And if 'currnt' -> negative # (indicating 'input' 
; command), the input line is not printed and execution is not 
; terminated, but continued at inperr.
tb_error:
    call tb_crlf
    xor ah, ah
    call tb_prtstg                 ; Print error message pointed by dx
    mov si, [tb_currnt]            ; get current line #
    or si, si                   ; check the value
    jz tb_rstart                   ; if zero, just restart
    cmp si, 0xffff              ; if -1
    je tb_inperr                   ; redo input
    call tb_prtln                  ; Else print the line
    pop bx                      ; Restore pointer to where error happened
    call tb_prtchs
    mov al, '?'                 ; print a "?"
    call tb_outch
    call tb_prtstg                 ; print the rest of the line
    jmp tb_rstart                  ; then restart
    

tb_qsorry:
    push si
tb_asorry:
    mov si, tb_sorry
    jmp tb_error
    

;=========================================================================
; 'fndln' finds a line with a given line # (in ax ) in the text save area.
; si is used as the text pointer. 
; If the line is found, si will point to the beginning of that line (i.e. the 
; low byte of the line #), and flags are NC and Z.
; If that line is not there and a line with a higher line # is found, si points
; to there, and flags are NC and NZ.
; If we reached the end of the text save area and cannot find the line, flags 
; are C and NZ.
; 'fndln' will initialize si to the beginning of the text save area to start 
; the search. Some other entries if this routine will not initialize si and do 
; the search.
; 'fndlnp' will start with si and search for the line #.
; 'fndnxt' wil bump si by 2, find a CR, and then start search.
; 'fndskp' will use si to find a CR and then start search.
; Only si and flags are modified.
tb_fndln:
    or ax, ax                   ; Check sign of ax
    js tb_qhow                     ; It cannot be negative
    mov si, tb_txtbgn              ; init text pointer
    
tb_fndlnp:                         ; *** fndlnp ***
    push bx                     ; save bx
    mov bx, [tb_txtunf]            ; check if we passed end
    dec bx
    cmp bx, si                  ; when si = [txtunf], this will overflow
    pop bx                      ; restore bx
    jc .flnret                  ; C, NZ: passed end
    
    cmp [si], ax                ; Is it the line # we are looking for?
    jb tb_fndnxt                   ; No, not there yet
.flnret:                        ; else we either found it or it is not there
    ret                         ; NC,Z: found;  NC,NZ: not found

tb_fndnxt:                         ; find next line
    inc si                      ; 
tb_fl1:
    inc si                      ; Just passed byte 1 and 2
    
tb_fndskp:                         ; Try to find CR
    cmp byte [si], 0dh          ; is it CR ?
    jne tb_fl1                     ; keep looking
    inc si                      ; found CR, skip over
    jmp tb_fndlnp                  ; check if end of text
   
   
; 'tstv' is used to check for a variable; either single-letter variable or 
; the @() array variable. 
; 
; The address of the variable is returned in bx.
tb_tstv:                           ; Test for a variable
    call tb_ignblnk
    cmp al, '@'                 ; is it the array variable ?
    ;jc .end_tstv                ; C: not a variable
    jne .test_charv             ; not '@' array
    
    inc si                      ; It is the @ array
    call tb_parn                   ; @ should be followed by (expr) as its index
    shl bx, 1                   ; word storage
    jc tb_qhow                     ; Is index too big ?
    
    push dx                     ; Will it fit ?
    mov dx, bx
    call tb_size                   ; Find size of free
    cmp dx, bx                  ; And check that
    jge tb_qsorry                  ; If not, say sorry

    mov bx, tb_txtend              ; If it fits, get address
    sub bx, dx                  ; of @(expr) and put it in bx
    pop dx                      ; restore dx
    clc
    ret                         
    
.test_charv:
    or al, 20h                  ; Lowercase al
    sub al, 'a'                 ; 
    cmp al, 26                  ; Not @, is it 'a' to 'z' ?
    ja .no_tstv                 ; If not, return with CF
    xor ah, ah                  
    shl ax, 1                   ; (word storage)
    mov bx, tb_varbgn              
    add bx, ax                  ; bx = varbgn + ax*2
    inc si                      ; Advance pointer (eat variable char)
    clc
    ret
    
.no_tstv:
    stc                         ; Not a variable, set CF
    ret


;=========================================================================
; 'tstch' is not used in this implementation. Instead, the call to 'ignblnk'
; pre-loads the 1st non-blank character in al, ready to be compared.

    
; 'tstnum' is used to check whether the text (pointed by si) is a number.
; If a number is found, ax contains the number's value and cl will contain the
; number of digits. If not, ax and cl are set to zero.
; si is advanced to the non-digit character.
; Trashed: bx
tb_tstnum:
    call tb_ignblnk                ; Skip any spaces. Char is already in al
    xor ax, ax
    xor bx, bx                  ; Initialize. 
    xor cl, cl                  ; 

.tstnumch:    
    lodsb                       ; char in al
    cmp al, '0'                 ; Is it '0' or above ?
    jb .not_digit               ; no, then it can't be a digit.
    cmp al, '9'                 ; Is it '9' or below ?
    ja .not_digit               ; no, then it can't be a digit.
    
    ; We have a digit.
    test bh, 0f0h               ; If any of the four high bits are set in bh,
    jnz tb_qhow                    ; there will be no room for the next digit.
    
    inc cl                      ; count one more digit
    
    ; a 'mul' is more than 100 cycles!
    push dx                     ; save dx
    shl bx, 1                   ;   bx = old * 2
    mov dx, bx                  ;   dx also = old * 2
    shl bx, 1                   ;   bx = old * 4
    shl bx, 1                   ;   bx = old * 8
    add bx, dx                  ;   bx = old * 8 + old * 2 = old * 10
    pop dx                      ; restore dx
    
    and al, 0fh                 ; convert from ascii '0' to numeric value
    add bx, ax                  ; add that to bx
    js tb_qhow                     ; If we wrapped to signed, that's an error
    jmp .tstnumch               ; Do next char

.not_digit:
    dec si                      ; move si back to that char that was not a digit
    mov ax, bx                  ; result in ax. cl should be ok.
    ret

tb_qhow:                           ; *** Error : How? ***
    push si
tb_ahow:
    mov si, tb_how
    jmp tb_error


;=========================================================================
; 'mvup' and 'mvdown', as declared in the original tbasic, are not really worth
; reimplementing for a x86 CPU that has built-in string operation like 'movsb',
; and even more so with the 'rep' prefix.

; '_popa' restores the 'for' loop variable save area from the stack
tb__popa:
    pop bp                      ; bp=return address
    pop ax                      ; restore lopvar, but
    mov [tb_lopvar], ax
    or ax, ax                   ; =0 means no more
    jz .pp1
    pop ax
    mov [tb_lopinc], ax
    pop ax
    mov [tb_loplmt], ax
    pop ax
    mov [tb_lopln], ax
    pop ax
    mov [tb_loppt], ax
.pp1:
    push bp
    ret


; '_pusha' stacks the 'for' loop variable area into the stack
tb__pusha:
    pop bp                      ; bp=return address
    cmp sp, tb_stklmt              ; Is stack near the top ?
    jb tb_qsorry                   ; Yes, sorry for that.
    mov ax, [tb_lopvar]            ; Else save loop vars.
    or ax, ax                   ; But if lopvar is 0
    jz .pu1                     ; That will be all
    mov ax, [tb_loppt]
    push ax
    mov ax, [tb_lopln]
    push ax
    mov ax, [tb_loplmt]
    push ax
    mov ax, [tb_lopinc]
    push ax
    mov ax, [tb_lopvar]
.pu1:
    push ax
    push bp                     ; bp = return address
    ret


;=========================================================================
; 'prtstg' prints a string pointed to by si. It stops printing and returns
; to caller when either a CR is printed or when the next byte is equal to ah.
tb_prtstg:
.psloop:
    lodsb                       ; Get a char
    cmp al, ah                  ; same as ah ?
    je .psend                   ; yes, we're done
    call tb_outch                  ; else print it
    cmp al, 0dh                 ; was it a CR ?
    jne tb_prtstg                  ; no, next char
.psend:
    ; si points after stop char or CR.
    ret


; 'prtstg_cs' acts just like prtstg, but with text pointed to by cs:dx, for 
; use with strings declared in ROM.
;prtstg_cs:
;    push ds                     ; save ds
;    push cs
;    pop ds                      ; ds now points to code
;    xchg si, dx
;    call prtstg
;    xchg dx, si
;    pop ds                      ; restore ds
;    ret


; 'qtstg' looks for caret (^), singe quote or double quote at si-> (al set)
; If none of these, return to caller. If caret, output a control
; character. If single or double quote, print the string in the quote
; and demands matching unquote. On return, if there was a quoted string 
; or a control character to print, CF is cleared. Otherwise, CF is set.
tb_qtstg:
    cmp al, 022h                ; Is it a " ?
    je .qt1
    cmp al, 027h                ; Is it a ' ?
    jne .qt4
.qt1:
    mov ah, al                  ; Yes, it is a " or a '
    inc si                      ; Eat the quote character
    call tb_prtstg                 ; print until another
.qt2:
    cmp al, 0dh                 ; Was last one a CR?
    jne .qt3
    pop ax                      ; Dummy pop of return address
    jmp tb_runnxl                  ; Was CR, run next line
.qt3:
    clc                         ; Clear CF
    ret                         ; Return
.qt4:
    cmp al, '^'                 ; Is it a caret ?
    jne .qt5
    inc si
    lodsb                       ; Yes, convert next character
    xor al, 0x40                ; to Control-char
    call tb_outch
    mov al, [si]                ; Load next char in al
    jmp .qt2                    ; Just in case it is a CR
    
.qt5:                           ; None of the above
    stc                         ; Set CF
    ret
    

; 'prtchs' prints a string pointed to by si, until si is equal to bx.
; At exit, si points to the next, not printed yet, character.
tb_prtchs:
    cmp si, bx
    jge .pc1
    lodsb
    call tb_outch
    jmp tb_prtchs
.pc1:
    ret
    

; 'prtnum' prints the number in ax. Leading blanks are added if needed to pad the
; number of spaces to the number in cl. However, if the number of digits is 
; larger than cl, all digits are printed anyway. Negative sign is also printed 
; and counted in, positive sign is not.
tb_prtnum:
    push ax                     ; save registers
    push bx
    push cx
    push dx
    mov bx, 10                  ; decimal. Cannot appear as a digit.
    xor ch, ch                  ; By default, no sign
    or ax, ax                   ; check sign
    jns .unsigned               ; our number is positive
    mov ch, '-'                 ; ch contains sign
    dec cl                      ; '-' sign takes place
    neg ax                      ; make ax positive,
.unsigned:
    push bx                     ; Save as a flag
.pn5:
    xor dx, dx                  ; set dx to 0 for division
    div bx                      ; result in ax, remainder in dx
    or ax, ax                   ; result O ?
    jz .pn6                     ; Yes, we got all
    push dx                     ; save remainder
    dec cl                      ; dec space count
    jmp .pn5                    ; Divide by 10 again
.pn6:                           ; We got all digits in the stack
    mov al, ' '                 ; Leading blank
.pn7:
    dec cl                      ; look at space count
    jle .pn8                    ; no (more) leading blanks
    call tb_outch
    jmp .pn7                    ; more ?
.pn8:
    mov al, ch                  ; print sign
    or al, al
    jz .nosign                  ; maybe - or null
    call tb_outch
.nosign:
    mov ax, dx                  ; Last remainder was in dx
.digit:
    cmp al, bl                  ; bl=10, it is our flag for no more
    je .end
    add al, '0'                 ; convert to ascii
    call tb_outch                  ; and print the digit
    pop ax                      ; get next digit
    jmp .digit                  ; and go back for more
.end:
    pop dx                      ; Restore registers
    pop cx
    pop bx
    pop ax
    ret


; 'prtln' prints the line number pointed to by si followed by a space.
; si is also advanced by two
tb_prtln:
    push cx                     ; save cx
    mov ax, [si]                ; load the number
    mov cl, 4                   ; Line number by default on 4 chars
    call tb_prtnum                 ; print the line #
    mov al, ' '                 ; print a space
    call tb_outch
    inc si                      ; Advance si past the word value that has been
    inc si                      ; printed.
    pop cx                      ; restore cx
    ret
    
; Direct commands:
tb_table1:
    db  'list', 0
    dw  tb_list
    db  'new', 0
    dw  tb_new
    db  'run', 0
    dw  tb_run
    db  'bye', 0
    dw  tb_bye


; Direct/Statements:
tb_table2:
    db  'next', 0
    dw  tb_next
    db  'let', 0
    dw  tb_let
    db  'if', 0
    dw  tb_iff
    db  'goto', 0
    dw  tb_goto
    db  'gosub', 0
    dw  tb_gosub
    db  'return', 0
    dw  tb_return
    db  'rem', 0
    dw  tb_rem
    db  'for', 0
    dw  tb_for
    db  'input', 0
    dw  tb_input
    db  'print', 0
    dw  tb_print
    db  'stop', 0
    dw  tb_stop
    db  0
    dw  tb_deflt
    
; Functions
tb_table3:
    db 'rnd', 0
    dw tb_rnd
    db 'abs', 0
    dw tb__abs
    db 'size', 0
    dw tb_size
    db 0
    dw tb_notf
    
; "For" command
tb_table4:
    db  'to', 0
    dw  tb_for_to
    db  0
    dw  tb_qwhat
    
tb_table5:
    db  'step', 0
    dw  tb_for_step
    db  0
    dw  tb_fr3

; Relation operators
tb_table6:
    db '>=', 0
    dw tb_expr_ge
    db '#', 0
    dw tb_expr_ne
    db '>', 0
    dw tb_expr_g
    db '=', 0
    dw tb_expr_eq
    db '<=', 0
    dw tb_expr_le
    db '<', 0
    dw tb_expr_lt
    db 0
    dw tb_xpr7


;========================================================================
; 'bye' (commande directe) rend la main au menu principal.
tb_bye:
    call tb_endchk              ; doit se terminer par CR
    ; ... et continue avec tb_exit

; 'tb_exit' restaure la pile, les segments et les registres de l'appelant
; (voir tiny_basic) puis retourne au menu.
tb_exit:
    mov sp, [tb_savsp]          ; SP de l'appelant (DS = TB_SEG encore valide)
    pop ds                      ; DS = CS (restaure)
    pop es
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret


;=========================================================================
;
; Input output routines - ADAPTEES: terminal UART (voir l'en-tete)
;

; 'crlf' will output a CR followed by its LF.
; al is changed (set to 0dh, the CR character)
tb_crlf:
    mov al, 0dh                 ; CR in al
    ; then continues with outch


; 'outch' will output the character in al. If the character is CR, it
; will also output a LF. Only flags may change at return.
tb_outch:
    push ax
    call uart_tx_byte           ; preserve tous les registres
    cmp al, 0dh                 ; is it a CR ?
    jne .done
    mov al, 0ah                 ; send the LF along.
    call uart_tx_byte
.done:
    pop ax
    ret

; 'chkio' checks to see if there is any input. If no input, it returns zero in
; al with ZF set. If there is input, it further checks whether input is
; control-C or control-X. If neither, it returns the character in al and ZF is
; cleared. Control-C jumps to 'rstart' (does not return); Control-X leaves
; Tiny BASIC for the menu (tb_exit, does not return). Only ax and flags may
; change at return.
tb_chkio:
    call uart_rx_available      ; CF=0 si un octet UART attend (detruit AX)
    jc .none
    call uart_rx_byte           ; AL = octet du terminal

    cmp al, 18h                 ; Is it Control-X ?
    je tb_exit

    cmp al, 03h                 ; is it Control-C ?
    jne .have                   ; No, then return.
    jmp tb_rstart               ; yes, restart TBI

.have:
    mov ah, 1
    or ah, ah                   ; ZF cleared, AL (le caractere) intact
    ret
.none:
    xor al, al                  ; AL = 0, ZF set
    ret

; 'getln' reads a input line into 'buffer'. It first prompts the character
; in al (given by the caller), then it fills the buffer and echos. Backspace
; is used to delete the last character (if there is one). CR signals the end
; of the line, and causes 'getln' to return.
; When 'buffer' is full, 'getln' will accept backspace or CR only and will
; ignore (and will not echo) other characters. After the input line is stored
; in the buffer, di points beyond the last CR.
; ax and flags are also changed at return.
; ADAPTATIONS: attente par scrutation (pas de HLT - voir l'en-tete, point 4),
; qui brasse la graine de RND; DEL (7Fh, touche "Retour arriere" de la plupart
; des terminaux) vaut BS; LF et les autres caracteres de controle sont
; ignores; une SEQUENCE ANSI (fleches, Suppr... : ESC [ ... lettre, ou
; ESC O lettre) est avalee en entier au lieu d'etre inseree dans la ligne
; (tb_escst: 0 = normal, 1 = ESC recu, 2 = dans la sequence).
tb_getln:
    call tb_outch               ; write the prompt from al
    mov di, tb_buffer           ; getln will store the line into the buffer
    mov byte [tb_escst], 0
.glinloop:
    call tb_chkio               ; get a character
    jnz .gotch
    inc word [tb_ranseed]       ; attente: brasse la graine de RND
    jmp .glinloop               ; Wait for input
.gotch:
    mov ah, [tb_escst]
    or ah, ah
    jz .notseq                  ; pas dans une sequence ESC
    cmp ah, 1
    jne .inseq                  ; etat 2: on avale jusqu'a l'octet final
    cmp al, '['                 ; etat 1 (ESC vu): '[' ou 'O' ouvre une sequence
    je .seqopen
    cmp al, 'O'
    je .seqopen
    mov byte [tb_escst], 0      ; ESC suivi d'autre chose: ESC ignore, l'octet
    jmp .notseq                 ; est traite normalement
.seqopen:
    mov byte [tb_escst], 2
    jmp .glinloop
.inseq:
    cmp al, 40h                 ; parametres/intermediaires (20h-3Fh): avales
    jb .glinloop
    cmp al, 7eh                 ; octet final (40h-7Eh): fin de la sequence
    ja .glinloop
    mov byte [tb_escst], 0
    jmp .glinloop
.notseq:
    cmp al, 1bh                 ; ESC ?
    jne .notesc
    mov byte [tb_escst], 1
    jmp .glinloop
.notesc:
    cmp al, 7fh                 ; DEL ?
    jne .gltestbs
    mov al, 08                  ; ... equivaut a BS
.gltestbs:
    cmp al, 08                  ; Is it backspace ?
    jne .gltestcr               ; No, check for other special cases
    cmp di, tb_buffer
    jna .glinloop               ; Buffer is already empty
    call tb_outch               ; go back on screen
    mov al, ' '
    call tb_outch               ; print space over
    mov al, 08
    call tb_outch               ; go back again
    dec di                      ; pointer goes back too
    jmp .glinloop               ; Go get next char

.gltestcr:
    cmp al, 0dh                 ; is it CR ?
    je .gleol                   ; Yes, end of line
    cmp al, 20h                 ; autre caractere de controle (LF, ESC...): ignore
    jb .glinloop
    cmp di, tb_bufend           ; Else, do we have room ?
    je .glinloop                ; No, wait for CR or BS

    call tb_outch               ; We have room, echo the character
    stosb                       ; and store it in the buffer
    jmp .glinloop               ; Go get next one

.gleol:
    call tb_outch               ; Echo the char (CR)
    stosb                       ; and store it in the buffer.
    ret


;========================================================================
; Messages (en ROM, copies en RAM par tiny_basic - voir l'en-tete).
; Chacun se termine par CR: tb_prtstg s'arrete au premier CR imprime.
tb_rom_msg:
    db 'Tiny BASIC 8088 (PATB86, A. Tihon; L.-C. Wang) - VE2CUY', 0dh
tb_rom_ok:
    db 'Ok', 0dh
tb_rom_what:
    db 'What?', 0dh
tb_rom_how:
    db 'How?', 0dh
tb_rom_sorry:
    db 'Sorry', 0dh
tb_rom_hint:
    db 'Ctrl-C: interrompre   Ctrl-X ou BYE: menu principal', 0dh
tb_rom_end:

; adresses RAM des messages (memes decalages que dans la ROM)
tb_ok           equ     tb_msg + (tb_rom_ok    - tb_rom_msg)
tb_what         equ     tb_msg + (tb_rom_what  - tb_rom_msg)
tb_how          equ     tb_msg + (tb_rom_how   - tb_rom_msg)
tb_sorry        equ     tb_msg + (tb_rom_sorry - tb_rom_msg)
tb_hint         equ     tb_msg + (tb_rom_hint  - tb_rom_msg)

%endif ; TINY_BASIC_ASM
