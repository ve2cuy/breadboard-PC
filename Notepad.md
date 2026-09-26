Les sessions Claude Code sont déjà sauvegardées automatiquement en local — aucune action explicite n'est nécessaire pour "sauvegarder".

Emplacement (pour ce projet) :


C:\Users\alin_\.claude\projects\c--Users-alin--github-i86\<session-id>.jsonl
Chaque conversation est écrite en continu dans ce fichier au fur et à mesure.

Pour la retrouver plus tard :

Dans VS Code (votre environnement actuel) : l'extension garde son propre historique de conversations, accessible via le panneau des conversations — vous pouvez y revenir directement sans passer par le terminal.
Depuis un terminal, si vous préférez :
claude --continue → rouvre la conversation la plus récente de ce dossier
claude --resume → ouvre une liste pour choisir parmi toutes vos conversations
/resume (tapé dans une session active) → même sélecteur, en direct
Astuce utile : tapez /rename <un-nom> dans cette conversation pour lui donner un nom clair (ex. breadboard-pc-manifest) — vous pourrez ensuite la retrouver avec claude --resume <un-nom> ou dans le sélecteur, plutôt que de chercher par ID.

Si vous voulez plutôt une copie lisible (pas pour reprendre le travail, juste pour archiver/consulter le texte), /export produit un fichier texte de l'échange en cours.

C:\Users\alin_\.claude\projects\c--Users-alin--github-i86\breadboard-pc.json


« On reprend le projet breadboard-PC : ajouter [fonction] au BIOS. »