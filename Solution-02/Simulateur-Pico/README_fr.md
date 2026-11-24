# Simulateur de Solution-02 avec le Pico W

*[English version](README.md)*

C'est le simulateur de la **carte Solution-02 actuelle** : le [simulateur d'origine](../Simulateur/README_fr.md)
(8088, LCD, DEL, clavier PS/2, oscilloscope, analyseur logique, débogueur…) et tout ce qui s'est ajouté le 2026-11-23 :

- l'**ATmega328P U17** : terminal J5 à 57600 bauds, module Wi-Fi Grove sur J13 ;
- le **Raspberry Pi Pico W** (A1) sur les ports **50h-57h**, derrière deux **SN74LVC245** (U18 données, U19 adresses et
  commandes) et **RN4** (8 × 100 Ω) ;
- **READY** : Q1 met RDY1 du 82C84 à 0, et le 8088 attend pendant que le Pico répond ;
- **J16** (GP22 → IRQ3), **J14** (lecteur microSD du Pico) et **J15** (UART1 du Pico).

**À essayer en ligne : <https://ve2cuy.github.io/breadboard-PC/pico/>**

## Ce qui tourne dedans

| Partie | Ce que le simulateur exécute |
|---|---|
| 8088, 8259, 8253, 8255, LCD, ATmega | les modèles du simulateur d'origine |
| BIOS | **BIOS 3.3** ([../bios](../bios)) : il détecte le Pico, lit la carte SD par lui et fait passer `INT 14h DX=1` (S02PKT, `ttyS1` d'ELKS) par lui |
| Pico W | le **cœur de son vrai micrologiciel** ([../pico/coeur](../pico/coeur)), compilé en WebAssembly : registres 50h-57h, commandes de la carte SD, SLIP et relais TCP/IP (smoltcp) |
| Temps du Pico | états d'attente par lecture (READY, 3 par défaut, tirés de l'essai du PIO au cycle près), durée des commandes (lecture d'un secteur ≈ 0,4 ms) |
| Internet | Internet intégré, DNS-over-HTTPS, HTTP par le navigateur, relais TCP en option (voir plus bas) |

## Réseau

Le 8088 envoie des paquets IP en SLIP (192.168.240.2, passerelle 192.168.240.1 = le Pico). Le Pico termine lui-même les
connexions TCP du 8088, à la manière de slirp, et demande à son hôte d'ouvrir les vraies. Dans la page, cet hôte est :

1. **L'Internet intégré**, toujours présent :
   - les pings vers toute adresse reçoivent une réponse (un navigateur ne peut pas envoyer de vrai ping) ;
   - zone `s02` : `www.s02` (10.83.0.80, pages d'essai et fichier de 64 Ko), `pico.s02` ;
   - `http://192.168.240.1/` est la page d'état du Pico lui-même.
2. **DNS-over-HTTPS** (Cloudflare) pour les vrais noms, en UDP (mTCP) comme en TCP (ELKS).
3. **HTTP par le navigateur** (`fetch()`), sans relais. Cela ne marche que pour les sites qui acceptent les requêtes
   d'autres origines (CORS).
   L'essai de la page de bout en bout (`node outils/essai_page.mjs`, Edge sans fenêtre) vérifie ce chemin :
   DNS-over-HTTPS puis `fetch()` depuis la page elle-même.
4. **Relais TCP**, pour du vrai TCP/IP vers n'importe quel site (telnet, ftp, http…). Lancer
   `python outils/relais.py` sur l'ordinateur, puis cliquer **Connecter** dans l'onglet **Pico W · Réseau**. Le relais
   écoute sur `ws://127.0.0.1:8765` et n'utilise que la bibliothèque standard de Python.

NTP (UDP 123) reçoit l'heure de l'ordinateur. Pendant une opération réseau réelle (DNS-over-HTTPS, fetch, relais), la
page ramène la simulation au temps réel. En vitesse Max, les délais réseau du 8088 expireraient avant la réponse de
l'Internet.

## Démarrage rapide

1. Mise sous tension. L'écran Info du BIOS montre `CPU 8088    Pico v01`.
2. **1) Load DOS**, choisir **FDNET.IMG** (FreeDOS 1.4 + mTCP + S02PKT, chargé depuis J14 par le Pico).
3. Essayer ces commandes :
   - `PING 8.8.8.8`, `HTGET http://www.s02/`, `HTGET http://192.168.240.1/` ;
   - sans relais, les sites qui acceptent CORS : `HTGET http://api.ipify.org/` (votre adresse publique sur le
     LCD), `HTGET http://wttr.in/Montreal?format=3` (la météo) ;
   - avec le relais, n'importe quel site : `HTGET http://example.com/`.

**ELKSNET.IMG** (ELKS 0.9.2) s'utilise de la même façon : `root`, `net start slip`, `ping 8.8.8.8`,
`urlget http://www.s02/texte.txt`.

L'onglet **Pico W · Réseau** contient :
- le registre d'état (51h) et les accès du bus ;
- les options du montage : Pico monté, lecteur de la carte (J14 ou J9), J16, nombre d'états d'attente ;
- l'état du Wi-Fi, les compteurs réseau et le relais ;
- le journal du réseau.

Un clic droit sur A1, U18, U19 ou Q1 permet de les inspecter.

## Mesures au simulateur

| | Sans Pico (SPI de U12) | Avec le Pico |
|---|---|---|
| Démarrage du DOS depuis C: jusqu'au pilote de paquets | 37,4 s | 19,9 s |
| Téléchargement HTTP de 64 Ko, écrit sur C: | — (≈ 2,7 Ko/s par l'ATmega) | 5,8 Ko/s |

Le téléchargement est limité par la scrutation à 18,2 Hz de S02PKT (16 blocs de 255 octets par tic avec le Pico), pas
par le bus.

## Construire et essayer

```
.\construire.ps1 -Essais      # copie du BIOS, netliste, WebAssembly, puis cargo test
.\lancer.cmd                  # serveur local http://localhost:8088/
python outils\relais.py       # relais TCP pour la page
node outils\essai_reseau.mjs [--relais ws://127.0.0.1:8765]   # chemin réseau de la page, de bout en bout, avec Node
node outils\essai_page.mjs [--relais ws://127.0.0.1:8765]     # la vraie page dans Edge sans fenêtre (serveur sur le port 8099)
.\publier.ps1                 # publie les deux simulateurs (gh-pages : / et /pico/)
```

`cargo test --release` passe les essais du simulateur d'origine sur le BIOS 3.3, et [tests/pico.rs](tests/pico.rs) :
- détection par le BIOS et écran Info ;
- MS-DOS 6.22 démarré depuis la carte du Pico, avec `PING`, DNS et `HTGET` de mTCP (dont un fichier de 64 Ko écrit
  sur C:) ;
- vitesse des secteurs avec et sans le Pico ;
- FreeDOS + mTCP ;
- ELKS (`ping`, DNS sur TCP, `urlget`).

Les essais propres au Pico sont dans [../pico/coeur](../pico/coeur) : `cargo test`, et `cargo test --features pio` pour
l'essai du PIO au cycle près face aux temps du 8088.

## Limites

- Un instantané restaure le 8088 et la carte, mais le Pico redémarre : ses connexions TCP sont perdues.
- Sans le relais, l'UDP autre que DNS et NTP n'est pas relayé, et les connexions entrantes sont impossibles.
- La couche matérielle du micrologiciel (PIO, SPI0, Wi-Fi CYW43439) n'est pas simulée. Elle est vérifiée par l'essai du
  PIO, et le sera sur le montage.
