// Solution-02 : BIOS calls for serial-s02.c (ttyS1 = Wi-Fi module through the ATmega U17)
//
// INT 14h DX=1 : AH=03h status (AH bit 7 = 1 : no module), AH=08h read block,
// AH=09h write block (ES:BX buffer, CX count -> CX done). BIOS 3.1 and later.
//
#include <linuxmt/config.h>
	.arch	i8086, nojumps
	.code16
	.text

	.global	s02_present
	.global	s02_read
	.global	s02_write

// int s02_present(void) : 1 if the BIOS answers block reads on COM2

s02_present:
	push	%bp
	push	%si
	push	%di
	push	%es
	push	%ds
	pop	%es
	mov	$1,%dx
	mov	$0x08,%ah		// empty read: AH = 0 with a version 3 ATmega,
	xor	%cx,%cx			// 80h without, unchanged (08h) with an older BIOS
	mov	%sp,%bx			// (no byte is written with CX = 0)
	int	$0x14
	xor	%al,%al
	or	%ah,%ah
	jnz	1f
	inc	%al
1:	xor	%ah,%ah
	pop	%es
	pop	%di
	pop	%si
	pop	%bp
	ret

// int s02_read(char *buf, int max)

s02_read:
	mov	$0x08,%ah
	jmp	1f

// int s02_write(char *buf, int len)

s02_write:
	mov	$0x09,%ah
1:	push	%bp
	mov	%sp,%bp
	push	%si
	push	%di
	push	%es
	push	%ds
	pop	%es
	mov	4(%bp),%bx
	mov	6(%bp),%cx
	mov	$1,%dx
	int	$0x14
	test	$0x80,%ah
	jz	2f
	xor	%cx,%cx
2:	mov	%cx,%ax
	pop	%es
	pop	%di
	pop	%si
	pop	%bp
	ret
