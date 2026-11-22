#!/bin/bash
# Construit ELKS pour Solution-02 sous Linux (Ubuntu 24.04, en root : conteneur Docker,
# voir construire.ps1) : chaine croisee ia16-elf-gcc (une seule fois, gardee dans $CACHE),
# noyau, programmes, image de disquette de 360 Ko (systeme de fichiers MINIX).
#
#   bash construire.sh [dossier_de_sortie]
#
# Variables : CACHE (defaut /root/cache) = chaine croisee ; B (defaut /root/elks-s02) =
# copie de travail des sources.
set -e
ICI=$(cd "$(dirname "$0")" && pwd)
SORTIE=${1:-$ICI/sortie}
CACHE=${CACHE:-/root/cache}
B=${B:-/root/elks-s02}

if [ "$(id -u)" = 0 ] && command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq build-essential texinfo libncurses-dev libelf-dev ncompress \
        bison flex git wget nasm python3 ca-certificates curl xxd rsync >/dev/null
fi

# copie de travail (on ne compile pas dans le dossier partage avec Windows)
mkdir -p "$B" "$CACHE/cross" "$SORTIE"
rsync -a --delete --exclude cross "$ICI/src/" "$B/"
ln -sfn "$CACHE/cross" "$B/cross"
cd "$B"

# chaine croisee (longue : ~20 min sur 16 coeurs ; une seule fois)
if [ ! -x cross/bin/ia16-elf-gcc ]; then
    MAKEFLAGS=-j$(nproc) tools/build.sh
fi

. ./env.sh
cp solution02.config .config
grep -q '^CONFIG_HW_SOLUTION02=y' .config
make kclean > /dev/null 2>&1 || true
# 'make' finit par l'image pleine, qui ne tient pas sur 360 Ko (manque d'inodes) :
# seule cette erreur est toleree, l'image reduite est construite ensuite.
make > make.log 2>&1 || grep -q "Inodes required" make.log || { tail -40 make.log; exit 1; }
(cd image && make fd360-minix > ../image.log 2>&1) || { tail -20 image.log; exit 1; }
cp image/fd360-minix.img "$SORTIE/elks-solution02-fd360.img"
cp elks/arch/i86/boot/Image "$SORTIE/elks-solution02-noyau.bin"
ls -l "$SORTIE"
md5sum "$SORTIE"/*
