#!/bin/bash
# Construit l'image de disque dur ELKS de Solution-02 (systeme de fichiers MINIX, 32 Mo, table
# de partitions 63 secteurs x 16 tetes) avec TOUS les programmes : ceux d'elkscmd (etiquette
# CONFIG_APPS_HD) et les applications externes (buildext.sh) qui se construisent : compilateurs
# C natifs C86 (cpp, c86, as, ld, ar, make, en-tetes et libc86 dans /usr) et dcc (c88),
# programmes OpenWatcom, Lua, gzip, kilomacs, etc.
#
#   bash construire-hd.sh [dossier_de_sortie]      (dans le conteneur : voir construire-hd.ps1)
#
# Prealable : construire.sh (chaine croisee, noyau, programmes). OpenWatcom v2 (instantane
# Linux) et les depots externes sont gardes dans $CACHE (volume Docker elks-s02-cache).
set -e
ICI=$(cd "$(dirname "$0")" && pwd)
SORTIE=${1:-$ICI/sortie}
CACHE=${CACHE:-/root/cache}
B=${B:-/root/elks-s02}

bash "$ICI/construire.sh" "$SORTIE"
apt-get install -y -qq xz-utils >/dev/null

# OpenWatcom v2 (Linux 64 bits), une seule fois
if [ ! -x "$CACHE/watcom/binl64/wcc" ]; then
    mkdir -p "$CACHE/watcom"
    curl -fsSL -o /tmp/ow.tar.xz \
        https://github.com/open-watcom/open-watcom-v2/releases/download/Current-build/ow-snapshot.tar.xz
    tar -xJf /tmp/ow.tar.xz -C "$CACHE/watcom"
fi
export WATCOM=$CACHE/watcom
export PATH=$WATCOM/binl64:$WATCOM/binl:$PATH
export INCLUDE=$WATCOM/h

# depots externes gardes dans le cache
mkdir -p "$CACHE/extapps"
ln -sfn "$CACHE/extapps" "$B/extapps"
# ExtApplications nomme aussi ../extapps/../libc, ../elks, ../elkscmd (en-tetes et libc86.a
# du compilateur C86) : extapps etant un lien, ces chemins partent du cache
for d in libc elks elkscmd; do ln -sfn "$B/$d" "$CACHE/$d"; done
cd "$B"
. ./env.sh

# chaque projet externe : un echec n'arrete pas les autres (il manquera seulement a l'image)
: > "$SORTIE/externes.log"
# (c86_elkscmd omis : seulement la demo paint.c86, et il cherche cpp86 absent de host-bin)
for p in owc_libc owc_elkscmd c86_toolchain dcc dflat elkirc elksdigger \
         elks_viewer gzip lua bobcat kilomacs elksmoria elksdoom ngircd_elks microwindows gem; do
    if (cd "$B" && ./buildext.sh $p) > "$SORTIE/ext-$p.log" 2>&1; then
        echo "OK     $p" | tee -a "$SORTIE/externes.log"
    else
        echo "ECHEC  $p (voir ext-$p.log)" | tee -a "$SORTIE/externes.log"
    fi
done

# image de disque dur avec table de partitions
cd "$B/image"
make hd32mbr-minix > ../image-hd.log 2>&1 || { tail -30 ../image-hd.log; exit 1; }
grep -c "SKIPPED" ../image-hd.log || true
grep "SKIPPED" ../image-hd.log > "$SORTIE/absents-hd.log" || true
cp hd32mbr-minix.img "$SORTIE/elks-solution02-hd32.img"
ls -l "$SORTIE"/elks-solution02-hd32.img
md5sum "$SORTIE"/elks-solution02-hd32.img
