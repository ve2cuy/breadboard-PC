## Un émulateur de Solution-02, écrit en Rust, qui roule dans un fureteur (WebAssembly).

* Exemple à regarder: https://github.com/zzleezz/8bit-hw-simulator

## L'émulateur propose les fonctions suivantes:

* Afficher l'ensemble des composants physiques avec leurs nom, apparence physique et broches sur un PCB.
  * voir l'exemple de présentation de l'URL Exemple à regarder.
* Implémente toutes les connexions entre les composants (NETLIST) et connait l'ensemble des signaux électriques et logiques.
* Un écran LCD fonctionnel
* Les LEDs fonctionnelles
* Un bouton reset fonctionnel
* Un clavier PS2
* Un terminal UART
  * Une fonction pour passer du clavier PS2 au clavier UART
* Un lecteur de Carte SD
* Un osciloscope permettant de prendre des lectures sur les broches des composants
* La posibilité de charger des fichiers BIOS
* La posibilité d'afficher le fichier PDF des composants (menu via clic droit de la souris)
* Permet de mettre en pause le système pour afficher les registres et le contenu de la mémoire.
  * Reprendre l'exécution au pas à pas ou normalement.
* Placer tous les fichiers de l'émulateur dans le dossier `Simulateur`
* Ajouter toutes autres fonctions qui pourraient être utilises.
* À la mise sous tension, le simulateur se comporte exactement comme le montage sur le breadboard.

Directives pour Claude

* Installer tous les outils nécessaire à la réalisation du simulateur
* Travailler sans intervention à moins que cela soit absolument nécessaire
* Produire une application testée et fonctionnelle
* Générer une interface utilisateur hautement professionnelle et ergonomique.
* Donner au visuel un look de laboratoire électronique
