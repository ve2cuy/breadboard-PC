"""Relais WebSocket -> TCP pour le simulateur de Solution-02 avec le Pico W.

    python outils/relais.py [--port 8765] [--hote 127.0.0.1]

Un fureteur ne peut pas ouvrir de connexion TCP. La page du simulateur (onglet Pico W, bouton
« Connecter ») ouvre ici une WebSocket par connexion du 8088 :

    ws://127.0.0.1:8765/?ip=93.184.215.14&port=80

le relais ouvre la vraie connexion TCP, repond « OK » (texte) une fois connecte, puis copie les
octets dans les deux sens (trames binaires). Fermeture d'un cote = fermeture de l'autre.
`/?test=1` repond « S02RELAIS <version> » (verification de la page).

Bibliotheque standard seulement (asyncio). N'ecoute que sur 127.0.0.1 par defaut : seul ce
poste peut s'en servir. Les pages servies par https (gh-pages) peuvent joindre ws://127.0.0.1
(adresse locale, permise par les fureteurs).
"""
import argparse
import asyncio
import base64
import hashlib
import struct
import sys
import urllib.parse

VERSION = '1.0'
GUID = b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


async def lire_trame(r):
    """(opcode, donnees) d'une trame du client (masquee), fragments reunis."""
    donnees = b''
    while True:
        b0, b1 = await r.readexactly(2)
        op = b0 & 0x0F
        n = b1 & 0x7F
        if n == 126:
            n, = struct.unpack('>H', await r.readexactly(2))
        elif n == 127:
            n, = struct.unpack('>Q', await r.readexactly(8))
        masque = await r.readexactly(4) if b1 & 0x80 else b'\0\0\0\0'
        d = bytearray(await r.readexactly(n))
        for i in range(n):
            d[i] ^= masque[i & 3]
        if op in (8, 9, 10):
            return op, bytes(d)
        donnees += d
        if b0 & 0x80:
            return op or 2, donnees


def trame(op, d):
    n = len(d)
    if n < 126:
        t = struct.pack('>BB', 0x80 | op, n)
    elif n < 65536:
        t = struct.pack('>BBH', 0x80 | op, 126, n)
    else:
        t = struct.pack('>BBQ', 0x80 | op, 127, n)
    return t + d


async def client(r, w):
    pair = w.get_extra_info('peername')
    try:
        tete = await r.readuntil(b'\r\n\r\n')
    except Exception:
        w.close()
        return
    lignes = tete.decode('latin1').split('\r\n')
    chemin = lignes[0].split(' ')[1] if ' ' in lignes[0] else '/'
    champs = {l.split(':', 1)[0].strip().lower(): l.split(':', 1)[1].strip() for l in lignes[1:] if ':' in l}
    cle = champs.get('sec-websocket-key', '').encode()
    if not cle:
        w.write(b'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n')
        await w.drain()
        w.close()
        return
    accepte = base64.b64encode(hashlib.sha1(cle + GUID).digest())
    w.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
            b'Sec-WebSocket-Accept: ' + accepte + b'\r\n\r\n')
    await w.drain()
    q = urllib.parse.parse_qs(urllib.parse.urlparse(chemin).query)
    if 'test' in q:
        w.write(trame(1, ('S02RELAIS ' + VERSION).encode()))
        w.write(trame(8, b''))
        await w.drain()
        w.close()
        return
    ip = q.get('ip', [''])[0]
    try:
        port = int(q.get('port', ['0'])[0])
    except ValueError:
        port = 0
    print('%s -> %s:%d' % (pair[0], ip, port), flush=True)
    try:
        tr, tw = await asyncio.wait_for(asyncio.open_connection(ip, port), 10)
    except Exception as e:
        print('   echec : %s' % e, flush=True)
        w.write(trame(8, struct.pack('>H', 4000) + str(e)[:100].encode()))
        await w.drain()
        w.close()
        return
    try:
        w.write(trame(1, b'OK'))
        await w.drain()
    except Exception:
        tw.close()                              # la page a deja ferme (connexion abandonnee)
        print('   page partie avant la connexion', flush=True)
        return

    async def vers_tcp():
        try:
            while True:
                op, d = await lire_trame(r)
                if op == 8:
                    break
                if op == 9:
                    w.write(trame(10, d))
                    await w.drain()
                    continue
                if op in (1, 2):
                    tw.write(d)
                    await tw.drain()
        except Exception:
            pass
        try:
            tw.write_eof()
        except Exception:
            tw.close()

    async def vers_ws():
        try:
            while True:
                d = await tr.read(16384)
                if not d:
                    break
                w.write(trame(2, d))
                await w.drain()
        except Exception:
            pass
        try:
            w.write(trame(8, b''))
            await w.drain()
        except Exception:
            pass

    await asyncio.gather(vers_tcp(), vers_ws())
    for x in (tw, w):
        try:
            x.close()
        except Exception:
            pass
    print('   fin %s:%d' % (ip, port), flush=True)


async def principal(hote, port):
    s = await asyncio.start_server(client, hote, port)
    print('Relais WebSocket -> TCP de Solution-02 : ws://%s:%d (Ctrl+C pour arreter)' % (hote, port), flush=True)
    async with s:
        await s.serve_forever()


if __name__ == '__main__':
    a = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    a.add_argument('--port', type=int, default=8765)
    a.add_argument('--hote', default='127.0.0.1')
    o = a.parse_args()
    try:
        asyncio.run(principal(o.hote, o.port))
    except KeyboardInterrupt:
        sys.exit(0)
