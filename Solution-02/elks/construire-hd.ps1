# Construit l'image de disque dur ELKS de Solution-02 (tous les programmes, compilateur C86)
# depuis Windows, dans un conteneur Docker (Docker Desktop). Premiere fois : longue
# (chaine croisee, OpenWatcom, depots externes, gardes dans le volume elks-s02-cache).
# Resultat : elks\sortie\elks-solution02-hd32.img (a copier sur la carte SD, d'un seul tenant).
#
#   powershell -ExecutionPolicy Bypass -File construire-hd.ps1
$ErrorActionPreference = 'Stop'
docker version --format '{{.Server.Version}}' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker ne repond pas : demarrer Docker Desktop.' }
docker run --rm -v "${PSScriptRoot}:/s02" -v elks-s02-cache:/root/cache ubuntu:24.04 `
    bash /s02/construire-hd.sh /s02/sortie
if ($LASTEXITCODE -ne 0) { throw "construction echouee ($LASTEXITCODE)" }
