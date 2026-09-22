#!/usr/bin/env python3
"""
build_rom.py - Construit une image de boot ROM 256K pour 8088
à partir d'un binaire de code assemblé avec MASM.

Usage:
    python build_rom.py code.bin
    python build_rom.py code.bin rom_final.bin
"""

import sys
import argparse

ROM_SIZE = 256 * 1024        # 40000h = 262144 octets
VECTOR_OFFSET = 0x3FFF0      # offset du vecteur de reset (physique FFFF0h)

def build_rom(input_path, output_path):
    with open(input_path, "rb") as f:
        code = f.read()

    if len(code) > VECTOR_OFFSET:
        print(f"Erreur : le code ({len(code)} octets) est trop volumineux "
              f"pour tenir avant le vecteur de reset (offset {VECTOR_OFFSET:#x}).")
        sys.exit(1)

    # Image vierge (convention EEPROM effacée = 0xFF)
    rom = bytearray([0xFF]) * ROM_SIZE

    # Code placé au tout début de la ROM (offset 0000h = physique C0000h)
    rom[0:len(code)] = code

    # Vecteur de reset : EA 00 00 00 C0  =  JMP FAR C000:0000
    vector = bytes([0xEA, 0x00, 0x00, 0x00, 0xC0])
    rom[VECTOR_OFFSET:VECTOR_OFFSET + len(vector)] = vector

    with open(output_path, "wb") as f:
        f.write(rom)

    print(f"Fichier créé      : {output_path}")
    print(f"Taille du code    : {len(code)} octets")
    print(f"Taille finale ROM : {len(rom)} octets ({len(rom)//1024} Ko)")
    print(f"Vecteur de reset  : offset {VECTOR_OFFSET:#x} -> {vector.hex(' ').upper()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Construit une image de boot ROM 256K pour 8088 à partir d'un binaire MASM."
    )
    parser.add_argument("input", help="Fichier binaire du code assemblé (ex: code.bin)")
    parser.add_argument(
        "output",
        nargs="?",
        default="rom_final.bin",
        help="Fichier de sortie (défaut: rom_final.bin)"
    )
    args = parser.parse_args()

    build_rom(args.input, args.output)