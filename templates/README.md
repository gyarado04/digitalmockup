# Ajouter un template preset

L'app propose au démarrage une grille de templates avec miniature + nom.
Pour ajouter un preset (4-5 attendus) :

1. Crée un dossier `templates/<id>/` (ex. `templates/tablette_salon/`).
2. Mets-y `template.blend` (le fichier de référence, avec le matériau
   `Interface`, les caméras/plans, etc.).
3. (Optionnel mais recommandé) ajoute `thumbnail.png` — une image
   représentative du rendu (ratio large, ~640×360 suffit). Sans miniature,
   l'app affiche une vignette grise générique.
4. Déclare-le dans `templates/manifest.json` :

```json
{
  "templates": [
    {
      "id": "tablette_salon",
      "name": "Tablette — Salon",
      "blend": "tablette_salon/template.blend",
      "thumbnail": "tablette_salon/thumbnail.png",
      "duration": "26 sec"
    }
  ]
}
```

`duration` est optionnel et purement informatif (affiché sous forme "Durée :
26 sec" sur la carte) — mets-y la durée de l'animation du template si tu la
connais (ex. déduite de `frame_end` du .blend), sinon omets le champ.

L'app ne modifie jamais ces fichiers : quand un utilisateur choisit un
template, elle en fait une **copie** vers l'emplacement de son projet client
(`<destination choisie>.blend`) et travaille sur cette copie.

Un preset dont le `.blend` déclaré est introuvable est ignoré silencieusement
(pas de plantage du sélecteur) — vérifie le chemin si un template
n'apparaît pas dans la grille.

## Miniatures vidéo (survol de la carte)

Deux emplacements, tous les deux optionnels — sans eux, l'app retombe sur la
miniature statique habituelle (photo du preset, ou rendu EEVEE auto pour un
plan) :

- **Carte du preset** (grille "Choisissez un template") : dépose
  `templates/<id>/video.mp4` et déclare-le dans le manifest à côté de
  `thumbnail` :
  ```json
  { "id": "tablette", "thumbnail": "tablette/thumbnail.png", "video": "tablette/video.mp4" }
  ```

- **Carte d'un plan** (grille "Assigner un plan") : un plan a le même rendu
  visuel d'un projet client à l'autre pour un même preset (seul le site
  injecté change), donc pas besoin de le régénérer par rendu EEVEE — dépose
  directement une photo + une vidéo par caméra :
  ```
  templates/<id>/shots/<nom de la caméra>/photo.png   (ou .jpg)
  templates/<id>/shots/<nom de la caméra>/video.mp4
  ```
  Le nom du dossier doit être le nom EXACT de la caméra dans le .blend, avec
  les caractères invalides pour un dossier remplacés par `_` (ex. la caméra
  `Camera 6 - Desktop/Mobile` → dossier `Camera 6 - Desktop_Mobile`). Pas de
  déclaration dans manifest.json pour les plans : l'app détecte les fichiers
  simplement en cherchant ce dossier au moment d'afficher la grille. Un plan
  sans dossier correspondant garde sa miniature EEVEE auto-rendue comme
  avant — aucune obligation d'en fournir pour tous les plans d'un coup.

Dans les deux cas : vidéo courte (quelques secondes), en boucle et sans son
à l'écran (l'app la coupe automatiquement) — juste de quoi montrer ce à quoi
ressemble le rendu en un coup d'œil.
