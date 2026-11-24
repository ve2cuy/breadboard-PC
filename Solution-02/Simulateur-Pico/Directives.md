## Simulateur de Solution-02 avec le Pico W (demande du 2026-11-23)

* Notre émulateur du montage ne reflète plus tous les changements : programmer une nouvelle version de
  l'émulateur (simulateur dans une page web), dans un nouveau sous-dossier du projet.
* Le simulateur doit intégrer les nouveaux composants ainsi que le Pico, son micrologiciel et le BIOS requis
  pour le bon fonctionnement entre le Pico et le montage, incluant l'accès à TCP/IP et à l'Internet.
* S'assurer que tout est parfaitement fonctionnel et ajouter un nouveau lien dans le README pour atteindre ce
  nouveau simulateur.
* Travailler de façon autonome ; installer les outils requis ; pousser sur GitHub sans demander.

Choix validés avant de commencer :
* le cœur du micrologiciel (protocole des registres, carte SD, réseau) est le même code dans le Pico et dans
  le simulateur (Rust, compilé en WebAssembly ici) ; la couche matérielle (PIO, SPI, Wi-Fi) est vérifiée par
  un essai du PIO au cycle près ;
* l'Internet depuis la page : intégré (pings, zone s02, page du Pico), DNS-over-HTTPS, HTTP par le navigateur,
  et relais WebSocket vers TCP (`outils/relais.py`) pour le vrai TCP/IP.
