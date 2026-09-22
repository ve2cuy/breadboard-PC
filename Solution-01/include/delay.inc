; ============================================================
; delay.inc
; Macro delay_ms - remplace l'ancien code inline "mov cx, N /
; call delay_ms" par une syntaxe plus lisible: "delay_ms N".
;
; Utilisation:
;   delay_ms SECONDE          ; ~1000 ms
;   delay_ms (2*SECONDE)      ; ~2000 ms - PARENTHESES obligatoires
;                                pour une expression, sinon NASM ne
;                                passerait que "2" comme argument 1
;
; Detruit CX/BX (memes registres que l'ancienne routine inline).
; La procedure reelle (delay_ms_proc) vit dans lib/utils.asm - ce
; fichier n'emet AUCUN octet (macro seulement), il peut donc etre
; inclus n'importe ou avant le premier usage, meme avant start:.
; ============================================================
%ifndef DELAY_INC
%define DELAY_INC

%macro delay_ms 1
        mov     cx, %1
        call    delay_ms_proc
%endmacro

%endif ; DELAY_INC
