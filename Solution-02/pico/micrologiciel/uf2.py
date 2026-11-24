"""ELF du micrologiciel -> UF2 pour le Pico (RP2040), et occupation de la flash et de la RAM.

    python uf2.py target/thumbv6m-none-eabi/release/s02pico-micrologiciel s02pico.uf2

Le Pico branche en USB avec BOOTSEL enfonce apparait comme un disque (RPI-RP2) : y copier
le fichier .uf2 suffit a le programmer.
"""
import struct
import sys

UF2_MAGIC0 = 0x0A324655
UF2_MAGIC1 = 0x9E5D5157
UF2_MAGIC_FIN = 0x0AB16F30
FAMILLE_RP2040 = 0xE48BFF56
FLASH = (0x10000000, 0x10000000 + 2 * 1024 * 1024 - 4096)
RAM = (0x20000000, 0x20000000 + 264 * 1024)


def segments(elf):
    assert elf[:4] == b'\x7fELF' and elf[4] == 1, 'ELF 32 bits attendu'
    phoff, = struct.unpack_from('<I', elf, 28)
    phentsize, phnum = struct.unpack_from('<HH', elf, 42)
    for i in range(phnum):
        p_type, off, vaddr, paddr, filesz, memsz, flags, align = struct.unpack_from('<8I', elf, phoff + i * phentsize)
        if p_type == 1:  # PT_LOAD
            yield vaddr, paddr, elf[off:off + filesz], memsz


def main():
    elf = open(sys.argv[1], 'rb').read()
    sortie = sys.argv[2]
    pages = {}
    ram_haut = RAM[0]
    flash_haut = FLASH[0]
    for vaddr, paddr, data, memsz in segments(elf):
        if RAM[0] <= vaddr < RAM[1]:
            ram_haut = max(ram_haut, vaddr + memsz)
        if not data:
            continue
        assert FLASH[0] <= paddr and paddr + len(data) <= FLASH[1], 'segment hors de la flash : %08X' % paddr
        flash_haut = max(flash_haut, paddr + len(data))
        for k in range(0, len(data), 1):
            a = paddr + k
            page = a & ~0xFF
            pages.setdefault(page, bytearray(b'\x00' * 256))[a - page] = data[k]
    adresses = sorted(pages)
    blocs = []
    for n, a in enumerate(adresses):
        b = struct.pack('<8I', UF2_MAGIC0, UF2_MAGIC1, 0x00002000, a, 256, n, len(adresses), FAMILLE_RP2040)
        b += bytes(pages[a]) + b'\x00' * (476 - 256) + struct.pack('<I', UF2_MAGIC_FIN)
        assert len(b) == 512
        blocs.append(b)
    open(sortie, 'wb').write(b''.join(blocs))
    print('%s : %d blocs ; flash %d Ko sur %d ; RAM statique %d Ko sur 264' % (
        sortie, len(blocs), (flash_haut - FLASH[0] + 1023) // 1024, (FLASH[1] - FLASH[0]) // 1024,
        (ram_haut - RAM[0] + 1023) // 1024))
    assert ram_haut <= RAM[1], 'RAM depassee'


if __name__ == '__main__':
    main()
