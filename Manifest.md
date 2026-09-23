* Lors du test de vitesse, afficher sur le UART des points sur la même ligne, au lieu des secondes, , pour représenter le déroulement du test.
  * Au départ du test, indiquer qu'il dure environ 30 secondes.
* Implémenter une compilation conditionnelle pour les messages des interfaces UART et LCD.
  * Les textes sont disponibles en français et en anglais.
  * Il est possible de produire un ROM_EN et un ROM_FR en fonction d'un paramètre à la compilation.
  * Tous les messages de la version francaise sont en français
  * Tous les messages de la version anglaise sont en anglais.
* Dans le menu Configuration, ajouter les items:
  * Heure et date
    * Permet de renseigner la date et l'heure du RTC
  * Information (permet d'afficher l'écran suivant)
    * jj-mm-aaaa, hh:mm:ss (rafraichie à toutes les secondes)
    * BIOS version: 9.99 (version_du_rom)
    * STM firmware: 9.99 
    * RAM: 999K (taille de la RAM)
    * DISQUE: 9999/9999 KB (utiliser/disponible)
    * Vitesse CPU: 4.77Mhz

NOTE: le texte en () sont des directives pour Claude.

---


1 - 

1) Clock speed
--> Current speed:  7.07 MHz
--- Sous-menu Configuration ---
1) Test CPU speed

--- Test CPU speed ---
Banc d'essai en cours, duree: environ 30 secondes (Echap pour annuler)...
..............................
Ecoule: 22 s
Le 8088 roule 54% plus vite qu'un 8088 a 4,77 MHz.
Vitesse estimee:  7.37 MHz

Mesuré à l'osciloscope, 7.3-4 mhz

--------------------------------------------------------------

2 - UART Repositionner le curseur sur la ligne de l'heure

1)
22-09-2026 20:03:18
22-09-2026 20:03:19
22-09-2026 20:03:20
22-09-2026 20:03:21
22-09-2026 20:03:22
22-09-2026 20:03:23
22-09-2026 20:03:24
...

La touche ESC ne fonctionne pas ici


2) LCD - Actualiser l'heure à chaque seconde.

Présentement, l'heure LCD est actualisé seulement à la saisie d'une touche clavier.

--------------------------------------------------------------

