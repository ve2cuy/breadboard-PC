#!/usr/bin/env python3
"""
Solution-02 - outil SLIP minimal pour le module Wi-Fi (esp_slip_router) vu d'un PC, sans pilote
SLIP ni droits d'administrateur : SLIP, IPv4, ICMP et un petit client TCP ecrits ici.

Le module est relie au PC par un adaptateur serie : directement, ou a travers la carte
(menu 9 du BIOS, Ctrl+B : pont de l'ATmega). Adresses par defaut d'esp_slip_router : module
192.168.240.1, client (nous) 192.168.240.2.

  python slip_outil.py COM9 ping [adresse] [nombre]     ICMP echo (defaut : 192.168.240.1)
  python slip_outil.py COM9 console                     console du module (TCP 7777) : taper
                                                        les commandes (show, set ssid ...,
                                                        save, reset), ligne vide = fin
  python slip_outil.py COM9 commandes "cmd1" "cmd2" ... console, commandes donnees ici

Dependance : pyserial.
"""
import random
import socket
import struct
import sys
import time

import serial

END, ESC, ESC_END, ESC_ESC = 0xC0, 0xDB, 0xDC, 0xDD
NOUS = "192.168.240.2"
MODULE = "192.168.240.1"


# ------------------------------------------------------------------ SLIP
class Slip:
    def __init__(self, port, vitesse=115200):
        self.s = serial.Serial(port, vitesse, timeout=0.05)
        self.tampon = bytearray()
        self.trames = []
        self.dans_esc = False

    def envoie(self, paquet):
        t = bytearray([END])
        for b in paquet:
            if b == END:
                t += bytes([ESC, ESC_END])
            elif b == ESC:
                t += bytes([ESC, ESC_ESC])
            else:
                t.append(b)
        t.append(END)
        self.s.write(bytes(t))

    def recoit(self, delai):
        """Prochaine trame (paquet IP) dans le delai, ou None."""
        fin = time.time() + delai
        while True:
            if self.trames:
                return self.trames.pop(0)
            if time.time() > fin:
                return None
            for b in self.s.read(512):
                if self.dans_esc:
                    self.tampon.append(END if b == ESC_END else ESC if b == ESC_ESC else b)
                    self.dans_esc = False
                elif b == ESC:
                    self.dans_esc = True
                elif b == END:
                    if self.tampon:
                        self.trames.append(bytes(self.tampon))
                    self.tampon = bytearray()
                else:
                    self.tampon.append(b)


# ------------------------------------------------------------------ IPv4
def somme(d):
    if len(d) % 2:
        d += b"\0"
    s = sum(struct.unpack("!%dH" % (len(d) // 2), d))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF


def ip(proto, src, dst, charge):
    ident = random.randint(0, 0xFFFF)
    h = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(charge), ident, 0, 64, proto, 0,
                    socket.inet_aton(src), socket.inet_aton(dst))
    h = h[:10] + struct.pack("!H", somme(h)) + h[12:]
    return h + charge


def ip_lit(p):
    if len(p) < 20 or p[0] >> 4 != 4:
        return None
    lh = (p[0] & 15) * 4
    total = struct.unpack("!H", p[2:4])[0]
    return p[9], socket.inet_ntoa(p[12:16]), socket.inet_ntoa(p[16:20]), p[lh:total]


# ------------------------------------------------------------------ ICMP
def ping(sl, dst, n=4):
    ident = random.randint(0, 0xFFFF)
    recus = 0
    for seq in range(1, n + 1):
        donnees = b"Solution-02 " + bytes(range(20))
        icmp = struct.pack("!BBHHH", 8, 0, 0, ident, seq) + donnees
        icmp = icmp[:2] + struct.pack("!H", somme(icmp)) + icmp[4:]
        t0 = time.time()
        sl.envoie(ip(1, NOUS, dst, icmp))
        rep = None
        while time.time() - t0 < 3:
            p = sl.recoit(3 - (time.time() - t0))
            if p is None:
                break
            r = ip_lit(p)
            if r and r[0] == 1 and r[1] == dst and r[3][0] == 0 and \
                    struct.unpack("!HH", r[3][4:8]) == (ident, seq):
                rep = time.time() - t0
                break
        if rep is None:
            print("ping %s seq %d : pas de reponse" % (dst, seq))
        else:
            recus += 1
            print("ping %s seq %d : %.0f ms" % (dst, seq, rep * 1000))
        time.sleep(0.3)
    print("%d/%d reponses" % (recus, n))
    return recus


# ------------------------------------------------------------------ TCP (client minimal)
class Tcp:
    SYN, ACK, PSH, FIN, RST = 2, 16, 8, 1, 4

    def __init__(self, sl, dst, port):
        self.sl, self.dst, self.port = sl, dst, port
        self.sport = random.randint(20000, 60000)
        self.seq = random.randint(0, 0x7FFFFFFF)
        self.ack = 0
        self.recu = bytearray()
        self.ferme = False

    def _seg(self, drapeaux, donnees=b""):
        h = struct.pack("!HHIIBBHHH", self.sport, self.port, self.seq, self.ack, 5 << 4,
                        drapeaux, 4096, 0, 0)
        pseudo = socket.inet_aton(NOUS) + socket.inet_aton(self.dst) + \
            struct.pack("!BBH", 0, 6, len(h) + len(donnees))
        c = somme(pseudo + h + donnees)
        h = h[:16] + struct.pack("!H", c) + h[18:]
        self.sl.envoie(ip(6, NOUS, self.dst, h + donnees))

    def _lit(self, delai):
        """Traite les segments recus pendant le delai ; rend les drapeaux du dernier."""
        fin = time.time() + delai
        dr = None
        while time.time() < fin:
            p = self.sl.recoit(fin - time.time())
            if p is None:
                break
            r = ip_lit(p)
            if not r or r[0] != 6 or r[1] != self.dst:
                continue
            t = r[3]
            sp, dp, seq, ack, off, drap = struct.unpack("!HHIIBB", t[:14])
            if dp != self.sport:
                continue
            donnees = t[(off >> 4) * 4:]
            dr = drap
            if drap & self.RST:
                self.ferme = True
                return dr
            if drap & self.SYN:
                self.ack = (seq + 1) & 0xFFFFFFFF
                self.seq_srv = ack
                return dr
            if donnees and seq == self.ack:
                self.recu += donnees
                self.ack = (self.ack + len(donnees)) & 0xFFFFFFFF
                self._seg(self.ACK)
            elif donnees:
                self._seg(self.ACK)         # (doublon : on redit ou on en est)
            if drap & self.FIN:
                self.ack = (self.ack + 1) & 0xFFFFFFFF
                self._seg(self.ACK)
                self.ferme = True
        return dr

    def connecte(self):
        for essai in range(3):
            self._seg(self.SYN)
            dr = self._lit(3)
            if dr is not None and dr & self.SYN:
                self.seq = (self.seq + 1) & 0xFFFFFFFF
                self._seg(self.ACK)
                return True
        return False

    def envoie(self, donnees):
        self._seg(self.PSH | self.ACK, donnees)
        self.seq = (self.seq + len(donnees)) & 0xFFFFFFFF

    def ecoute(self, delai):
        self._lit(delai)
        d = bytes(self.recu)
        self.recu.clear()
        return d

    def termine(self):
        if not self.ferme:
            self._seg(self.FIN | self.ACK)
            self.seq = (self.seq + 1) & 0xFFFFFFFF
            self._lit(1)


def console(sl, commandes=None):
    c = Tcp(sl, MODULE, 7777)
    if not c.connecte():
        print("console du module : pas de connexion (192.168.240.1:7777)")
        return False
    sys.stdout.write(c.ecoute(1.5).decode("latin-1"))
    sys.stdout.flush()
    for ligne in (commandes if commandes is not None else iter(lambda: input(), "")):
        c.envoie(ligne.encode() + b"\r\n")
        sys.stdout.write(c.ecoute(2.5).decode("latin-1"))
        sys.stdout.flush()
        if c.ferme:
            break
    c.termine()
    print()
    return True


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    sl = Slip(sys.argv[1])
    action = sys.argv[2]
    if action == "ping":
        dst = sys.argv[3] if len(sys.argv) > 3 else MODULE
        n = int(sys.argv[4]) if len(sys.argv) > 4 else 4
        return 0 if ping(sl, dst, n) else 1
    if action == "console":
        return 0 if console(sl) else 1
    if action == "commandes":
        return 0 if console(sl, sys.argv[3:]) else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
