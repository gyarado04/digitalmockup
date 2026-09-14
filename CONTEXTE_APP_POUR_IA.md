# DigitalMockup (alias interne "Agence Template 3D") — contexte pour une IA

> Nom affiché de l'app : **DigitalMockup** (renommé le 2026-09-02, était
> "Mockup 3D"). Les identifiants techniques internes (noms de module,
> dossiers, bundle id) restent "AgenceTemplate3D" — seul le nom que voit
> l'utilisateur a changé.

## En une phrase

Une app macOS qui prend l'URL d'un site web, capture des screenshots
(desktop + mobile), et les injecte automatiquement dans une scène 3D
Blender pré-animée (une tablette/écran qui scrolle la page) pour produire
une vidéo de présentation client — sans jamais ouvrir Blender à la main.

## Origine

C'est le portage d'un addon Blender (`agence_template_3d.py`) vers une
vraie app autonome. L'addon exposait un panneau dans Blender où on
choisissait un site, une caméra/plan, et l'addon remplaçait la texture
d'un écran 3D par un screenshot du site, puis animait le scroll. L'app
reprend exactement cette logique mais pilote Blender **en arrière-plan**
(`blender -b ... --python headless.py`), pour que l'utilisateur (une agence
web/graphisme) n'ait jamais à ouvrir Blender lui-même.

## Le pipeline utilisateur (4 étapes)

1. **Créer un projet** — soit depuis un **template preset** (un fichier
   `.blend` déjà préparé avec une scène 3D animée et des plans caméra
   prédéfinis, ex. "Preset 1" = une tablette avec 9 plans caméra), soit en
   **mode libre** (un template vierge, l'utilisateur choisit lui-même quels
   plans utiliser). Le preset original n'est jamais modifié : l'app en fait
   toujours une copie de travail.
2. **Assigner des plans à des pages** — le projet client a une ou
   plusieurs "pages" (chacune = un nom + une URL de site à capturer). Pour
   chaque page, on assigne un ou plusieurs "plans" (= des caméras de la
   scène 3D, ex. "Plan 1 - Desktop"). Un plan ne peut être assigné qu'à une
   seule page à la fois dans tout le projet.
3. **Capturer** — pour chaque page, l'app ouvre l'URL dans un navigateur
   headless, scrolle progressivement toute la page (pour déclencher les
   animations au scroll du site, type AOS/ScrollTrigger), puis prend un
   screenshot **pleine page** en desktop (1920×1080) ET en mobile
   (390×844). Deux fichiers PNG par page.
4. **Rendre** — Blender est lancé en arrière-plan. Pour chaque frame de
   l'animation, un script (`headless.py`) : regarde quelle caméra/plan est
   actif à cette frame (via des marqueurs posés dans le `.blend`),
   remplace la texture de l'écran 3D par le bon screenshot (desktop ou
   mobile selon le nœud), calcule automatiquement une fraction de scroll
   (0.0→1.0 linéaire sur la durée du segment de ce plan) et anime la
   position de la texture en conséquence, puis rend la frame. Résultat :
   une vidéo (mode Test = aperçu rapide basse résolution EEVEE, ou mode
   Final = rendu haute qualité Cycles) montrant l'écran 3D qui "scrolle"
   dans le vrai site du client, plan après plan.

Deux modes de rendu : **Test** (rapide, basse résolution, pour valider
avant de lancer le vrai rendu) et **Final** (haute qualité, plus lent).

## Le mécanisme 3D (comment le screenshot devient une texture animée)

Chaque `.blend` de template respecte une convention fixe :
- Un matériau nommé `Interface`, avec deux nœuds Image Texture nommés
  `Capture_desktop` et `Capture_mobile` — c'est là que les PNG capturés
  sont chargés (remplacement de texture, pas d'import de mesh).
- Un objet `Ecran verre` (l'écran/vitre 3D par-dessus l'écran, caché en
  mode Test pour accélérer le rendu).
- Des marqueurs de scène Blender délimitant quelle caméra/plan est actif
  sur quelle plage de frames (`_camera_segment_frames`).
- Un nœud Mapping dont l'échelle est recalculée pour que la hauteur de
  l'image capturée (souvent plus haute que l'écran) tienne exactement dans
  le cadre, et une position Y animée automatiquement de 0 à 1 sur la durée
  du segment pour simuler le scroll — jamais keyframé à la main.
- Si plusieurs plans caméra ne sont PAS tous assignés à une page, le rendu
  saute intelligemment les plages non utilisées (ne perd pas de temps à
  rendre un plan sans contenu) et ne garde que le nécessaire.

Cette logique (`headless.py`) est reprise **telle quelle** de l'addon
Blender d'origine — c'est la seule partie du projet qui reste en Python
dans TOUS les cas, parce que c'est Blender lui-même qui l'exécute dans son
propre interpréteur Python embarqué (ça ne peut pas être remplacé par un
autre langage).

## Deux implémentations de l'app orchestratrice (transition en cours)

- **`app/` (Python + PySide6)** — l'app d'origine, complète et
  fonctionnelle, utilisée jusqu'ici. Utilise Playwright/Chromium pour la
  capture web. **Vouée à être abandonnée** : l'utilisateur a précisé que
  cette version Python est terminée une fois la version Swift
  opérationnelle — ce n'est plus la version à faire évoluer.
- **`swift-app/` (Swift + SwiftUI, macOS le plus récent uniquement)** —
  **c'est la vraie app, celle qui remplace la version Python**, nommée
  "DigitalMockup". Même
  fonctionnalités, même format de fichiers projet (JSON interchangeable
  avec la version Python), mais :
  - la capture web utilise **`WKWebView` natif** (pas de Playwright/
    Chromium à installer, zéro dépendance externe) ;
  - l'app pilote Blender headless exactement pareil (`Process` au lieu de
    `QProcess`/`subprocess`), même script `headless.py`, mêmes marqueurs
    stdout pour suivre la progression d'un rendu ;
  - architecture en 2 couches : `AgenceTemplate3DCore` (bibliothèque pure
    Swift/Foundation, zéro dépendance SwiftUI, testable sans lancer
    d'interface) + `AgenceTemplate3D` (l'app SwiftUI elle-même) ;
  - le portage a rattrapé la parité fonctionnelle ET visuelle avec la
    version Python (même palette de couleurs, même disposition à 2
    colonnes, mêmes tailles de miniatures, etc.) pour l'essentiel de
    l'usage quotidien.

## Fichiers projet (identiques dans les deux implémentations)

Un projet client vit dans un dossier (par défaut sous
`~/Movies/DigitalMockup — Projets/Vidéo présentation projet/` — volontairement
hors de ~/Documents, ~/Desktop et ~/Downloads : macOS proteste par un popup
système au premier accès direct à ces 3 dossiers précis) :
```
<NomDuClient>/
├── <NomDuClient>.blend              — copie de travail du template
├── <NomDuClient>.agence_project.json — état du projet (JSON)
├── 01_CAPTURES/
│   └── <page>/web_desktop_<page>.png, web_mobile_<page>.png
└── 02_RENDUS/
    └── <blend>_<site>_<Test|Rendu>_0001-0900.mp4
```
Le dossier ET le fichier `.blend` sont automatiquement renommés d'après le
nom du client dès qu'il est renseigné (le nom du rendu final dérive du nom
du fichier `.blend`, pas du dossier).

Le JSON garde : nom du site, liste des pages (uid, nom, URL, plans
assignés), mode de rendu, cache des caméras du `.blend` (noms, miniatures,
durée en frames), fps, et si le projet est "verrouillé" (= preset à plans
figés, dans quel cas tous les plans du preset doivent être utilisés avant
de pouvoir rendre).

## Templates presets

Décrits par `templates/manifest.json` (id, nom, chemin du `.blend`,
miniature, vidéo de survol optionnelle, durée, liste ordonnée des plans du
preset). Chaque preset peut aussi fournir, par caméra, une photo/vidéo
statique déposée à la main (`templates/<id>/shots/<caméra>/photo.png` +
`video.mp4`) pour éviter de re-générer une miniature EEVEE à chaque fois —
un plan sans ce dossier retombe sur un rendu EEVEE auto.
