#!/bin/bash
# Construit ELKS pour Solution-01 sous Linux (Ubuntu 24.04, en root : conteneur Docker, voir
# construire.ps1) a partir des sources d'ELKS de Solution-02 (Solution-02/elks/src) et de
# solution01.config : chaine croisee ia16-elf-gcc (gardee dans $CACHE, partagee avec Solution-02),
# noyau, programmes, image de disquette de 360 Ko (systeme de fichiers MINIX).
#
#   bash construire.sh SOURCES_S02 [dossier_de_sortie]
#
# Ce qui change par rapport a Solution-02 (voir README.md) : tic d'horloge par l'INT 1Ch du BIOS
# (CONFIG_TIMER_INT1C : Solution-01 n'a pas de 8253, le pont 2.3 envoie le tic), et aucun acces
# direct aux ports qui retombent sur le 8255 (decode par A7 seule) ou le 8259 (par A5 seule) :
# sans 8250 (ttyS), sans pilote direct de disquette (CMOS 70h, FDC 3F2h), sans IDE/CF (1F0h-1F7h),
# sans haut-parleur (61h), sans l'arret des moteurs de disquette de bioshd (CONFIG_HW_SOLUTION01).
set -e
ICI=$(cd "$(dirname "$0")" && pwd)
SRC=${1:?sources d ELKS (Solution-02/elks/src)}
SORTIE=${2:-$ICI/sortie}
CACHE=${CACHE:-/root/cache}
B=${B:-/root/elks-s01}

if [ "$(id -u)" = 0 ] && command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq build-essential texinfo libncurses-dev libelf-dev ncompress \
        bison flex git wget nasm python3 ca-certificates curl xxd rsync >/dev/null
fi

mkdir -p "$B" "$CACHE/cross" "$SORTIE"
rsync -a --delete --exclude cross "$SRC/" "$B/"
ln -sfn "$CACHE/cross" "$B/cross"
chmod 755 "$B/elkscmd/rootfs_template/bin/top"
cd "$B"

if [ ! -x cross/bin/ia16-elf-gcc ]; then
    MAKEFLAGS=-j$(nproc) tools/build.sh
fi

. ./env.sh
cp "$ICI/solution01.config" .config
grep -q '^CONFIG_HW_SOLUTION01=y' .config
grep -q '^CONFIG_TIMER_INT1C=y' .config
make kclean > /dev/null 2>&1 || true
make > make.log 2>&1 || grep -q "Inodes required" make.log || { cp make.log "$SORTIE/make.log"; grep -n -B2 -A6 "error:\|Error 1" make.log | head -60; exit 1; }
grep -q '^CONFIG_HW_SOLUTION01=y' .config || { echo 'CONFIG_HW_SOLUTION01 perdu par la configuration'; exit 1; }
(cd image && make fd360-minix > ../image.log 2>&1) || { tail -20 image.log; exit 1; }
cp image/fd360-minix.img "$SORTIE/elks-solution01-fd360.img"
cp elks/arch/i86/boot/Image "$SORTIE/elks-solution01-noyau.bin"
ls -l "$SORTIE"
md5sum "$SORTIE"/*
