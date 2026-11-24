"""Serveur local du simulateur de Solution-02.

    python outils/serveur.py [--port 8088] [--pas-de-navigateur]

- copie dans www/images/ les images de disquette et de disque du dossier PC-DOS/ du depot
  (si elles n'y sont pas deja) et ecrit www/images/index.json ;
- sert le dossier www/ en HTTP (le WebAssembly et les modules JavaScript ne se chargent pas
  depuis file://) avec le bon type MIME pour .wasm ;
- ouvre le navigateur sur http://localhost:8088/.
"""
import argparse
import http.server
import json
import os
import shutil
import socketserver
import threading
import webbrowser

ICI = os.path.dirname(os.path.abspath(__file__))
WWW = os.path.normpath(os.path.join(ICI, '..', 'www'))
PCDOS = os.path.normpath(os.path.join(ICI, '..', '..', '..', 'PC-DOS'))

# (fichier dans PC-DOS/, nom 8.3 sur la carte, description, coche par defaut)
IMAGES = [
    ('pcdos2_1.img', 'PCDOS21.IMG', 'PC-DOS 2.1', 'PC-DOS 2.1', True),
    ('Dos33-d1.IMG', 'DOS33.IMG', 'PC-DOS 3.3, disquette 1', 'PC-DOS 3.3, disk 1', True),
    ('Dos50-d1-nokeyb.img', 'DOS50.IMG', 'MS-DOS 5.0, disquette 1 (sans KEYB)', 'MS-DOS 5.0, disk 1 (no KEYB)', False),
    ('Dos62-d1-nokeyb.IMG', 'DOS622.IMG', 'MS-DOS 6.22, disquette 1 (sans KEYB)', 'MS-DOS 6.22, disk 1 (no KEYB)', False),
    ('DOS622_C.IMG', 'DOS622_C.IMG', 'MS-DOS 6.22, disque dur C:', 'MS-DOS 6.22, C: hard disk', False),
    ('FREEDOS_C.IMG', 'FREEDOS.IMG', 'FreeDOS 1.4, disque dur C:', 'FreeDOS 1.4, C: hard disk', False),
    # reseau par le Pico W (ou le module de l'ATmega) : bios/tests/gen_fdnet.py, elks/construire-hd
    ('FDNET_C.IMG', 'FDNET.IMG', 'FreeDOS 1.4 + mTCP (réseau), disque dur C:', 'FreeDOS 1.4 + mTCP (network), C: hard disk', True),
    ('ELKS-0.9.2/hd32-minix-s02-reseau.img', 'ELKSNET.IMG', 'ELKS 0.9.2 (Minix, réseau), disque dur C:', 'ELKS 0.9.2 (Minix, network), C: hard disk', False),
]


def preparer_images():
    dst = os.path.join(WWW, 'images')
    os.makedirs(dst, exist_ok=True)
    index = []
    for src, nom, desc, desc_en, defaut in IMAGES:
        cible = os.path.join(dst, os.path.basename(src))
        source = os.path.join(PCDOS, src)
        if os.path.exists(source) and (not os.path.exists(cible) or os.path.getsize(cible) != os.path.getsize(source)
                                       or os.path.getmtime(cible) < os.path.getmtime(source)):
            shutil.copy2(source, cible)
            print('copie', src)
        if os.path.exists(cible):
            index.append({'file': os.path.basename(src), 'name': nom, 'desc': desc, 'desc_en': desc_en, 'size': os.path.getsize(cible), 'def': defaut})
    # autres images deposees a la main dans www/images
    connus = {e['file'] for e in index}
    for f in sorted(os.listdir(dst)):
        if f.lower().endswith(('.img', '.ima')) and f not in connus:
            base = os.path.splitext(f)[0].upper().replace(' ', '')[:8]
            index.append({'file': f, 'name': base + '.IMG', 'desc': f, 'size': os.path.getsize(os.path.join(dst, f)), 'def': False})
    with open(os.path.join(dst, 'index.json'), 'w', encoding='utf-8') as fo:
        json.dump(index, fo, ensure_ascii=False, indent=1)
    print(len(index), 'image(s) dans www/images/index.json')


class Gestionnaire(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      '.wasm': 'application/wasm', '.js': 'text/javascript', '.mjs': 'text/javascript',
                      '.json': 'application/json', '.pdf': 'application/pdf'}

    def __init__(self, *a, **k):
        super().__init__(*a, directory=WWW, **k)

    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache')
        super().end_headers()

    def log_message(self, fmt, *args):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=8088)
    ap.add_argument('--pas-de-navigateur', action='store_true')
    a = ap.parse_args()
    preparer_images()
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(('127.0.0.1', a.port), Gestionnaire) as srv:
        url = 'http://localhost:%d/' % a.port
        print('Simulateur de Solution-02 :', url, '(Ctrl+C pour arreter)')
        if not a.pas_de_navigateur:
            threading.Timer(0.6, lambda: webbrowser.open(url)).start()
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
