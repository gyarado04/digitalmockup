# Portage Swift/SwiftUI — état d'avancement

**Nom affiché de l'app : "DigitalMockup"** (renommé le 2026-09-02, était
"Mockup 3D"). L'utilisateur a précisé que cette app Swift EST l'app à
terme — la version Python (`../app/`) est terminée une fois celle-ci
fonctionnelle, donc seul le nom affiché ici a été changé (identifiants
techniques internes — `AgenceTemplate3D` en nom de module/cible, bundle
id, dossiers — inchangés, aucun intérêt à les renommer).

Portage de l'app Python/PySide6 (`../app/`) vers Swift/SwiftUI, décidé le
2026-09-01. Décisions actées avec l'utilisateur :

- **SwiftUI**, pas AppKit.
- **macOS le plus récent uniquement** — pas de compatibilité versions
  antérieures à gérer.
- **Par étapes livrables** : d'abord le strict nécessaire pour un flux
  bout-en-bout basique (créer un projet, assigner des plans, capturer une
  page, lancer un rendu), sans les fonctionnalités avancées du côté Python
  (presets verrouillés, mode libre, panneau de debug d'espacement, thème
  clair/sombre…) — celles-ci viendront dans des étapes suivantes une fois
  le flux de base solide.

`blender_side/headless.py` **reste inchangé et reste en Python** — c'est le
script que Blender exécute dans son propre interpréteur Python embarqué
(`blender -b template.blend --python headless.py -- <cmd> <config.json>`),
pas quelque chose que l'app appelante peut remplacer. Le portage ne
concerne que l'app elle-même (l'orchestrateur qui lance Blender et pilote
l'UI), pas ce script.

## Prérequis machine — Xcode ✅ RÉSOLU (2026-09-02)

**Xcode 27 beta 6 installé** (`/Applications/Xcode-beta.app`,
`xcode-select -s .../Xcode-beta.app/Contents/Developer` + licence acceptée
par l'utilisateur). `swift build` compile désormais LES TROIS cibles sans
erreur, y compris `AgenceTemplate3D` (SwiftUI) — confirmé.

Avant ça (2026-09-01, seuls les Command Line Tools étaient installés),
**aucune ligne de code SwiftUI ne pouvait être compilée**, pas même
`@State` seul (macro `SwiftUIMacros` absente hors Xcode complet) — le Core
(`AgenceTemplate3DCore`, pas de SwiftUI dedans) n'était pas concerné et
avait déjà été entièrement vérifié à l'époque via
`swift run AgenceTemplate3DSelfTest`.

`swift test` reste indisponible (XCTest/Testing ont besoin de
`XCTest.framework`/`Testing.framework` — pas testé à nouveau depuis
l'installation d'Xcode, probablement débloqué aussi désormais mais non
prioritaire vu que `AgenceTemplate3DSelfTest` fait le même travail).

## Structure

```
swift-app/
  Package.swift
  Sources/
    AgenceTemplate3DCore/       — modèle de données + pont Blender (bibliothèque,
      Project.swift               PAS de SwiftUI dedans — compile et tourne
      Template.swift              sans Xcode, entièrement vérifié)
      ProjectService.swift
      BlenderBridge.swift
      WebCapture.swift
    AgenceTemplate3D/            — app SwiftUI (exécutable) — ✅ compile
      App.swift                    (vérifié 2026-09-02 avec Xcode). Relue
      ContentView.swift            ligne par ligne après compilation (pas
      ProjectView.swift            juste "ça build") : un vrai bug logique
      AppState.swift                trouvé et corrigé, voir "Fait" plus bas
    AgenceTemplate3DSelfTest/    — vérification "à la main" du Core (pas de
      main.swift                   XCTest, voir "Prérequis machine" ci-dessus)
                                    — même esprit que AGENCE_SELFTEST côté
                                    app Python
```

## Commandes utiles

```bash
cd swift-app
swift build AgenceTemplate3DCore   # compile juste le Core (sans erreur)
swift run AgenceTemplate3DSelfTest # vérifie le Core (modèle + pont Blender +
                                    # templates + création de projet, y COMPRIS
                                    # un vrai appel Blender réel — pas un mock)
./dev_run.sh                       # build + LANCE l'app SwiftUI à l'écran
                                    # (voir piège ci-dessous — ne PAS utiliser
                                    # `swift run AgenceTemplate3D` pour ça)
```

⚠️ **Piège confirmé le 2026-09-02** : `swift run AgenceTemplate3D` compile
et démarre bien un process, mais **aucune fenêtre n'apparaît jamais** —
confirmé par `log show`, qui montre `Cannot index window tabs due to
missing main bundle identifier` puis `No windows open yet` sans qu'aucun
message d'ouverture de fenêtre ne suive jamais. Cause : un exécutable lancé
tel quel n'a pas d'`Info.plist`/identifiant de bundle, et AppKit refuse d'y
créer une fenêtre SwiftUI dans ce cas sur cette version de macOS. `dev_run.sh`
contourne ça en empaquetant le binaire dans un `.app` minimal jetable
(`Info.plist` avec juste un `CFBundleIdentifier`) avant de l'`open`-er —
PAS le packaging final signé (qui reste à faire, voir "Pas encore fait"),
juste assez pour tester à l'écran pendant le développement.

## Fait (2026-09-01)

**Core — écrit ET vérifié** (`swift run AgenceTemplate3DSelfTest`, 51
vérifications, toutes PASS, aucun mock) :
- `Project`/`Page`/`CameraShot`/`RenderMode` : Codable, mêmes clés JSON que
  côté Python (snake_case), même rétro-compatibilité (`cameras_cache`
  ancien format liste de `String`). Vérifié en LISANT DE VRAIS fichiers
  `.agence_project.json` déjà présents sur le disque (créés par l'app
  Python pendant cette session).
- `Template`/`TemplateCatalog` : lecture réelle de `templates/manifest.json`
  (5 templates trouvés, `preset_plan_order` de "tablette" correct).
- `ProjectService.createProject()` : portage de
  `main_window.py:_start_new_project_from_template` — copie le .blend,
  construit le Project (verrouillé + plans figés si preset, page vide sinon
  ou en mode libre forcé), crée 01_CAPTURES/02_RENDUS, sauvegarde le JSON.
  Vérifié par une VRAIE création de projet sur disque (dossier temporaire
  isolé), relecture depuis le disque, et confirmation que le .blend
  original du preset n'est jamais modifié.
- `BlenderBridge.runHeadless()` : même protocole que
  `app/core/blender.py:run_headless`. Vérifié avec un VRAI appel Blender
  headless (`list_shots` sur `templates/tablette/template.blend`) : 9 plans
  renvoyés avec les bons noms/frames/fps.
- Piège Swift 6 rencontré et corrigé dans `BlenderBridge` : la vérification
  stricte de concurrence refuse de muter un `var` capturé par une closure
  `@Sendable` (lecture du stdout du process) — voir le commentaire dans le
  fichier pour la solution (file de lecture dédiée + accumulateur verrouillé).
- `WebCapture` (capture web native, `WKWebView`) : voir détail dans "Pas
  encore fait" ci-dessous (barré, déplacé côté "fait" depuis session 3).

**UI SwiftUI — écrite ET compile désormais** (Xcode installé le
2026-09-02, `swift build` propre sur les 3 cibles). Relue ligne par ligne
après compilation, pas juste "ça build" :
- `AppState` (`@Observable`) : projet courant, liste des templates, appel
  `refreshShots()` (list_shots asynchrone, hors thread principal).
- `ContentView`/`TemplatePickerView` : écran d'accueil "Nouveau projet" →
  choix Mode libre/Preset → grille (liste pour l'instant, pas de
  miniatures) de templates.
- `ProjectView`/`PageRowView`/`PlanPickerButton` : nom du site, liste de
  pages (nom/URL éditables), plans assignés (liste de noms pour l'instant),
  "Assigner un plan" (respecte l'ordre canonique + les règles d'un preset
  verrouillé, comme `page_widget.py`), "Ajouter une page".
  **Bug trouvé et corrigé le 2026-09-02** : le sélecteur de plans
  n'excluait que les plans pris par une AUTRE page, pas ceux déjà assignés
  à la page courante (`page_widget.py:_open_shot_picker` les grise avec
  "Déjà assigné à cette page" — cette règle avait été omise à l'écriture
  initiale) → re-choisir un plan déjà sur la page le dupliquait dans
  `page.cameras`. Corrigé dans `ProjectView.swift`
  (`PlanPickerButton.availableShots`).
- **Capture web câblée dans l'UI** (2026-09-02) : `AppState.capturePage(at:)`
  — bouton "Capturer la page" par page, appelle `WebCapture` (Core) deux
  fois (desktop 1920×1080 puis mobile 390×844, une `WKWebView` neuve par
  capture — équivalent du `page.goto()` répété côté Python pour repartir
  d'un scroll à 0), écrit dans `01_CAPTURES/<page>/`
  (`Project.pageDesktopPath`/`pageMobilePath`, ajout d'un `Project.baseDir`
  calculé comme le `base_dir` Python). État par page suivi dans
  `AppState.capturingPageUIDs`/`capturedPageUIDs` (spinner pendant, coche
  après — `Project.pageHasCaptures` recalculé après coup, pas à chaque
  redraw).
- **`RenderProcess` + `RenderConfigBuilder` (Core) — VRAI rendu Blender
  streamé, câblé dans l'UI** (2026-09-02) : portage de
  `blender.py:RenderProcess` (Process/Pipe + `readabilityHandler` au lieu
  de QProcess, mêmes marqueurs stdout `AGENCE_PROGRESS`/`AGENCE_PREVIEW`/
  `AGENCE_RESULT_BEGIN…END` émis par `headless.py`, inchangé). Callbacks
  (`onProgress`/`onPreviewUpdated`/`onFinished`) plutôt que Combine/
  delegate — Core reste sans dépendance SwiftUI. `RenderConfigBuilder`
  porte les validations de `_launch_production` (preset : tous ses plans
  doivent être assignés ; pages sans capture bloquantes ; au moins une page
  assignée). Vérifié par l'étape 10 du self-test avec un **VRAI rendu
  Blender complet** (1 plan, 99 frames, EEVEE Next TEST 960×540) : 99
  mises à jour de progression reçues, 99 aperçus PNG live, fichier `.mp4`
  produit sur disque, aucun process Blender orphelin après — 62/62
  vérifications au total. UI : panneau "Production" dans
  `ProjectView.swift` (`RenderSectionView`) — mode Test/Final, lancer/
  annuler, barre de progression + ETA formatée, aperçu live (relit le PNG
  à chaque frame via un compteur `previewRefreshToken`, le fichier étant
  réécrit au même chemin).
- **Estimation de durée + "Afficher le dossier de rendu"** (2026-09-02) :
  portage de `_update_duration_estimate` (somme des frames de CHAQUE plan
  assigné, `project.camerasCache` — pas juste le plus long segment, les
  plans s'additionnent dans la vidéo finale) et de
  `preview.open_folder_requested`/`_open_render_folder` (`NSWorkspace.
  shared.open` sur `02_RENDUS`). Les deux dans `RenderSectionView`.
- **"Charger un projet"** (2026-09-02) : jusque-là l'UI ne savait QUE créer
  — fermer un projet (bouton "Menu") ou relancer l'app le rendait
  inaccessible, aucun moyen de revenir dessus. Portage de
  `main_window.py:_choose_blend` : `NSOpenPanel` (pas de macro SwiftUI,
  juste AppKit) pour choisir un `.blend`, `TemplateCatalog.findTemplate(
  byBlendPath:)` (ajouté, portage de `find_template_by_blend_path`) pour
  détecter un preset original ouvert par erreur (→ copie de travail créée
  plutôt que de le charger/modifier tel quel), sinon
  `ProjectStore.loadOrCreate`. Bouton "Charger un projet" ajouté à côté de
  "Nouveau projet" sur l'écran d'accueil (`ContentView.swift`).
- **Menu Fichier + changer l'emplacement des projets** (2026-09-02) :
  portage de `main_window.py:_build_menu`/`_change_projects_root`. Le menu
  "Nouvelle fenêtre" généré par défaut par SwiftUI (sans intérêt, l'app est
  mono-fenêtre) est remplacé (`CommandGroup(replacing: .newItem)` dans
  `App.swift`) par : Nouveau projet depuis un template…, Ouvrir un fichier
  .blend existant…, Enregistrer (⌘S), Changer l'emplacement des projets…
  (`AppState.presentChangeProjectsRootPanel()`, `NSOpenPanel` sur un
  dossier). `AppState.showTemplatePicker` déplacé depuis un `@State` de
  `ContentView` vers `AppState` pour être atteignable aussi bien depuis le
  bouton "Nouveau projet" que depuis ce menu.
- **Thème (style visuel)** (2026-09-02) : nouveau `Theme.swift` — portage
  des couleurs EXACTES de `app/ui/theme.py` (`DARK_PALETTE`/
  `LIGHT_PALETTE`, hex identiques). Différence assumée : côté Python le
  thème est un bouton explicite (Qt ne suit pas nativement l'apparence
  système de façon fiable) ; côté Swift on suit l'apparence système
  standard de macOS via `colorScheme` (plus idiomatique) — pas de bouton
  dédié pour l'instant, à ajouter si demandé explicitement. Fournit :
  `AppPalette` (+ `.appPalette` dans l'environnement, posé une fois par
  `ThemedRoot` dans `ContentView`), `PrimaryButtonStyle`/
  `SecondaryButtonStyle`/`DestructiveButtonStyle` (portage de
  `QPushButton#primary`/normal), `.cardBackground()`/`.panelBackground(
  dashed:)`/`.modalCardBackground()`/`.chipBackground()` (portage de
  `QFrame#card`/`#panel`/`#pageBox`/`#modalCard`/`#shotChip`),
  `.dimText()` (`QLabel[role="dim"]`), `.underlineFieldStyle()` (portage
  de `QLineEdit` : soulignement seul, accent au focus via `@FocusState`).
  Appliqué dans `ContentView`/`ProjectView` : fond de fenêtre, cartes de
  templates avec survol, pages en panneaux à bordure pointillée (comme
  `#pageBox`), puces de plans, boutons primaire/secondaire/destructif,
  barre de progression teintée accent.
- **Style, passe 2 — comparé à de VRAIES captures de l'app Python**
  (2026-09-02) : la passe 1 avait les bonnes couleurs mais une disposition
  différente. Corrigé en lisant le code source Python exact (pas en
  devinant depuis les captures) :
  - Disposition à 2 colonnes comme `main_window.py` — `ProjectView`
    (gauche : site/pages/plans + Test/Final + Lancer le rendu) et
    `RenderPreviewPanel` (droite, largeur fixe 380, **toujours visible**,
    pas seulement pendant un rendu) — portage direct de
    `preview_panel.py:PreviewPanel` (aperçu 16:9 letterbox, frame/ETA sur
    une ligne au-dessus de la barre, `formatETA` portée EXACTEMENT de
    `_format_eta`, "Ouvrir le rendu dans le Finder" au texte identique).
  - `PlanChipView` refaite en vraie carte 150×88 (`PLAN_CARD_THUMB_SIZE`,
    `page_widget.py`) avec barre nom + bouton "–" en bas, plus le badge x
    flottant de la passe 1.
  - `TemplatePickerView` refaite en grille 3 colonnes 220×170 (`CARD_SIZE`/
    `THUMB_SIZE`, `card_grid.py`), placeholder texte "?", titre "Choisissez
    un template", footer "Fichier .blend existant…"/"Annuler" — portage de
    `template_picker.py`/`card_grid.py`.
  - Tous les boutons pleine largeur (`.frame(maxWidth: .infinity)` posé
    sur le LABEL, pas sur le `Button` — sinon SwiftUI centre un bouton à
    taille fixe au lieu d'étirer son fond).
  - Fenêtre élargie (`minWidth: 860`) pour la disposition à 2 colonnes.
  Différence toujours assumée : pas de `ToggleSwitch` sombre/clair dédié
  (Python en a un explicite à droite de "Aperçu du rendu") — Swift suit
  l'apparence système macOS à la place.

**Flux bout-en-bout créer → assigner → capturer → rendre : COMPLET** dans
l'UI (les 4 étapes existent maintenant). Vue tourner réellement à l'écran
le 2026-09-02 (confirmé par l'utilisateur, après correction du piège
`swift run` ci-dessous) pour le flux de base ; le panneau "Production"
spécifiquement écrit/compilé/relu juste après, pas encore essayé à
l'écran par l'utilisateur au moment d'écrire ceci.

- **Renommage "Mockup 3D" → "DigitalMockup"** (2026-09-02) : nom AFFICHÉ
  seulement — noms techniques internes (module `AgenceTemplate3D`, bundle
  id, dossiers) inchangés, l'utilisateur a précisé que ça ne concerne QUE
  l'app Swift (la version Python est vouée à l'abandon une fois celle-ci
  opérationnelle).
- **Police Monument Grotesk embarquée** (2026-09-02, design fourni par
  l'utilisateur) : fichier `.otf` copié dans
  `Sources/AgenceTemplate3D/Resources/`, déclaré comme resource SwiftPM
  (`Package.swift`), enregistré au lancement via CoreText
  (`Theme.swift:AppFonts.registerBundledFonts()`, appelé dans
  `App.swift:init()`) — nom PostScript exact vérifié avec CoreText
  (`MonumentGrotesk-Regular`), pas deviné depuis le nom de fichier.
  `Font.monumentGrotesk(_:)` comme helper. **Piège de packaging à
  nouveau évité en amont** (même famille de problème que
  blender_side/templates) : SwiftPM compile les resources dans un
  `.bundle` séparé (`AgenceTemplate3D_AgenceTemplate3D.bundle`,
  `Bundle.module`) qu'il faut copier À LA MAIN dans
  `Contents/Resources/` en plus de l'exécutable — `dev_run.sh` ET
  `packaging/build_app.sh` mis à jour pour le faire.
- **Nouvel écran d'accueil** (2026-09-02, design fourni par
  l'utilisateur) : en-tête (titre 32pt + actions à droite, 12pt),
  "Projets récents" (16pt, les 3 plus récents en cartes), "Anciens
  projets" (16pt, le reste en liste) — fonctionnalité nouvelle côté
  Swift, pas un portage (Python n'a que Nouveau/Charger, aucun
  navigateur de projets existants). `ProjectService.listRecentProjects()`
  (Core, nouveau) scanne `<projectsRoot>/Vidéo présentation projet/`,
  trie par date de modification du `.agence_project.json`, ignore
  silencieusement un dossier corrompu. Vérifié par 6 nouvelles étapes de
  self-test avec de VRAIES créations de projets + dates de modification
  explicites (79/79 au total désormais).

- **Déformation verticale du contenu affiché sur l'écran 3D (2026-09-07)** —
  RÉSOLU, bug côté `blender_side/headless.py` (pas Swift). Le texte/les
  visages capturés apparaissaient "écrasés"/étirés verticalement sur
  l'écran de la tablette 3D, visible seulement avec du vrai contenu
  (photos de personnes) — c'est le bug de capture manquante ci-dessus qui
  a rendu ce problème visible pour la première fois, il préexistait sans
  doute. Cause : `update_mapping_scale_for_full_page` calcule le Scale Y
  du noeud Mapping via `DESKTOP_HEIGHT(1080) / image.height`, en supposant
  une capture à 1x (1 pixel image = 1 pixel CSS). Mais `WebCapture.swift`
  (WKWebView) capture en Retina sur ce Mac (2x) : une capture demandée à
  1920px de large produit une image PNG de 3840px. Sans correction, la
  fenêtre de recadrage vertical calculée est deux fois trop petite → le
  contenu affiché à l'écran apparaît anormalement zoomé/étiré
  verticalement. Fix : `update_mapping_scale_for_full_page` prend
  maintenant un paramètre `expected_width_px` (nouvelles constantes
  `DESKTOP_WIDTH=1920`/`MOBILE_WIDTH=390`, alignées sur les
  `viewportWidth` utilisés par `AppState.capturePage`), détecte le
  facteur d'échelle réel de l'image chargée (`image.size[0] /
  expected_width_px`) et corrige la hauteur cible avant de diviser.
  Diagnostiqué par comparaison de rendus isolés (une seule variable
  changée à la fois, frame/caméra fixes) plutôt que par jugement visuel —
  deux fausses pistes explorées puis écartées par calcul/diff pixel-à-pixel
  (animation de caméra, `resolution_percentage`) avant de trouver la
  vraie cause. Vérifié par rendu de reproduction complet (mêmes fichiers
  que le projet client réel) + suite de self-tests (0 échec).

- **Bouton Lancer/Annuler le rendu unique, déplacé sous l'aperçu
  (2026-09-07)** — le sélecteur Test/Rendu final + le bouton d'action
  vivent maintenant dans `RenderPreviewPanel` (colonne de droite), sous le
  cadre "Aperçu du rendu" (`RenderControlsView`, appelé depuis
  `ProjectView.swift`, plus depuis `leftColumn`). Un seul bouton bascule
  automatiquement Lancer (bleu, `PrimaryButtonStyle`)/Annuler (rouge,
  `DestructiveButtonStyle`) selon `appState.isRendering`, via deux `Button`
  CONCRETS dans un `if/else` — PAS un seul bouton avec un style choisi par
  ternaire (bug déjà rencontré le 2026-09-03 : un `ButtonStyle` choisi par
  ternaire entre deux styles concrets différents peut rester bloqué sur
  les couleurs de l'ancien thème après une bascule clair/sombre).

- **Réglages du projet : couleur de fond (2026-09-07)** — PROPRE À CHAQUE
  PROJET (`Project.colorPickerEnabled`), stocké dans le
  `.agence_project.json`, pas une préférence globale de l'app. Séparation
  ACTIVATION/UTILISATION (précisée après un aller-retour : d'abord tout
  dans une sheet "Paramètres", puis tout inline dans `leftColumn`, la
  version finale sépare les deux) :
  - **Activation** : page "Paramètres" (`ProjectSettingsSheet.swift`,
    bouton engrenage dans `ProjectView.leftColumn`) — SEULEMENT le
    `Toggle` `Project.colorPickerEnabled`.
  - **Utilisation** : le contenu révélé par ce toggle vit dans le projet
    lui-même (`leftColumn`), PAS dans la page Paramètres.
  - **"Couleurs personnalisées"** révèle `ProjectColorSettingsView.swift`
    (dans `leftColumn`) : un swatch de couleur (Fond seulement —
    `Project.backgroundColorHex`, hex `#RRGGBB` sRGB, converti en linéaire
    côté `headless.py:apply_color_override` au moment d'écraser le Base
    Color du Principled BSDF du matériau "Fond") + un bouton bleu ✓ +
    un bouton "Aperçu" qui déclenche un vrai rendu Blender à la frame 100
    (1 still, réglages TEST, commande `headless.py:cmd_color_preview` —
    `RenderConfigBuilder.buildColorPreviewConfig`) affiché directement
    dans le panneau.
    Le swatch N'EST PAS un `ColorPicker` SwiftUI standard — remplacé par
    `NativeColorSwatch.swift` (`NSViewRepresentable` autour d'un
    `NSButton` qui ouvre `NSColorPanel.shared` directement, plus fiable
    qu'un `ColorPicker` classique qui affiche d'abord son PROPRE popover
    interne). Le bouton ✓, lui, referme cette SECTION elle-même
    (`appState.setColorPickerEnabled(false)`, comme désactiver le toggle
    depuis Paramètres) — PAS le panneau système `NSColorPanel` : plusieurs
    tentatives pour fermer ce dernier (`close()`, `orderOut(nil)`, ramener
    la fenêtre principale au premier plan) ont toutes échoué à le masquer
    sur cette machine (bug/particularité AppKit non élucidé, peut-être lié
    à la version beta de macOS utilisée ici) — mais il s'est avéré que ce
    n'était de toute façon pas la bonne cible : l'utilisateur voulait
    fermer le panneau "Couleurs personnalisées" DE L'APP, pas celui de
    macOS (clarifié explicitement le 2026-09-07 après plusieurs
    allers-retours).
    Le picker "Tablette/téléphone" a été RETIRÉ de l'UI après
    investigation : dans le template "tablette", "Body Apple" (essayé en
    premier) ne colore rien (0 face du cadre ne l'utilise réellement,
    juste un slot inutilisé) ; "Material" (indiqué par l'utilisateur) n'a
    pas d'effet visible confirmé par rendu non plus ; "Noir basic" est le
    seul qui colore vraiment quelque chose — mais TOUTE la tranche visible
    du cadre, pas juste les boutons (aucun matériau dédié aux boutons
    seuls dans ce template) — donc laissé de côté pour l'instant plutôt
    que de livrer un réglage trompeur. `Project.deviceColorHex` et
    `apply_color_override(["Noir basic"], …)` restent en place côté
    Core/Blender (juste jamais renseignés depuis l'UI), faciles à
    rebrancher si un matériau boutons dédié est ajouté au template.

  Toutes les nouvelles clés JSON (`color_picker_enabled`,
  `background_color_hex`, `device_color_hex`) décodées avec
  `decodeIfPresent` + défaut (`Project` a un `init(from:)` explicite) — un
  vieux `.agence_project.json` sans ces clés se charge sans erreur, vérifié
  par un self-test dédié avec un JSON minimal construit dans le test (pas
  de dépendance à un fichier réel sur disque).

- ~~"Scroll manuel par keyframes" / "Sections importantes"~~ **FAIT PUIS
  ENTIÈREMENT RETIRÉ (2026-09-07 → 2026-09-08)** — un 2ème toggle
  (`Project.manualScrollEnabled`) qui permettait de tracer des sections sur
  une page et d'y assigner un plan Blender (une caméra créée volontairement
  lente/rapide par l'utilisateur) pour la défiler à un rythme choisi
  plutôt qu'à vitesse constante. Repensé 3 fois le 2026-09-07 (frise
  abstraite → miniature à côté → sections tracées directement sur la vraie
  page), avec 2 mécanismes de ralenti AUTOMATIQUE essayés et abandonnés en
  cours de route (brut, puis lissé `smoothstep`) avant le pivot final
  "assigner un plan à une section" — voir l'historique complet dans la
  mémoire projet si le détail de ces itérations redevient utile un jour.
  **Retiré ENTIÈREMENT le 2026-09-08** (demande explicite de
  l'utilisateur, "retirer toute la fonctionnalité") : `ImportantSection`
  (Core), `ScrollControlView.swift`/`SectionEditorPanel.swift` (vues,
  supprimées), `AppState.sectionEditorTarget`/`addImportantSection`/
  `removeImportantSection`/`clearImportantSections`/`updateImportantSection`/
  `assignCameraToSection`/`setManualScrollEnabled`, `Project.
  manualScrollEnabled`, `Page.importantSectionsDesktop/Mobile`/
  `cameraSections()`, le toggle "Sections importantes" dans
  `ProjectSettingsSheet`, le bouton "Mettre en avant des sections" dans
  `PageRowView`, `camera_sections` dans `RenderConfigBuilder`, et
  `camera_own_segment`/`camera_section_fraction` dans `headless.py`
  (`apply_frame` retombe désormais TOUJOURS sur `scroll_frames_for_page`/
  `scroll_fraction` — le mécanisme de scroll auto à vitesse constante
  D'ORIGINE, jamais retouché par tout cet épisode, inchangé). Self-tests
  dédiés (blocs 14/15 rétrocompat + `cameraSections`) retirés avec — la
  rétrocompat elle-même n'a pas besoin de code dédié : un vieux
  `.agence_project.json` qui contient encore `manual_scroll_enabled`/
  `important_sections_desktop/mobile` est juste silencieusement ignoré
  (ces clés ne sont plus dans `CodingKeys`), comportement standard de
  `Decoder`.

  (Un texte d'UI resté périmé — libellé/description du toggle "Sections
  importantes" — avait été corrigé plus tôt le 2026-09-08, mais c'est
  devenu sans objet quelques échanges plus tard quand toute la
  fonctionnalité a été retirée, voir juste au-dessus. Leçon qui reste
  valable pour la prochaine fois : lors d'un renommage fonctionnel,
  chercher aussi le texte UTILISATEUR affiché — pas seulement le nom de
  variable/fonction — sur TOUTES les vues qui en parlent.)

- **Avertissement temps de rendu Test vs Rendu final (2026-09-07)** —
  `RenderControlsView.renderTimeExpectationText` : ligne de texte générique
  ("quelques minutes en moyenne" / "quelques heures en moyenne" selon le
  mode sélectionné), affichée AU-DESSUS de `estimatedDurationText` — les
  deux ne répondent PAS à la même question : `renderTimeExpectationText`
  = combien de temps l'ordinateur va y passer (calcul, ordre de grandeur
  générique, pas par projet) ; `estimatedDurationText` = durée de la VIDÉO
  produite (nombre de frames ÷ fps, calculé par projet). Gardées comme 2
  lignes distinctes plutôt que fusionnées, pour ne pas laisser croire que
  l'une est un raffinement de l'autre.

- **"Anciens projets" borné + bouton Finder (2026-09-08)** — demande
  explicite : "il faudrait mettre une limite au nombre de projets dans
  anciens projets et un bouton pour ouvrir le dossier des projets pour
  voir le reste". `ContentView.olderProjectsLimit` (7) plafonne la liste
  affichée sous les 3 cartes "Projets récents" — `ProjectService.
  listRecentProjects` lui-même n'est PAS bridé (continue de tout scanner/
  trier, utile ailleurs, ne casse aucun self-test existant), le
  plafonnage est purement côté vue. Un bouton "Voir les N projets
  restants dans le Finder" (masqué si rien n'est caché) appelle
  `AppState.openProjectsFolderInFinder()` (`NSWorkspace.shared.open`,
  même pattern que "Ouvrir le rendu dans le Finder" déjà existant) sur
  `<projectsRoot>/Vidéo présentation projet/` — le même dossier que celui
  scanné.

- **Vidéo de présentation à l'ouverture (2026-09-08)** — demande
  explicite : popup avec vidéo au lancement + bouton "Ne plus afficher" +
  rejouable depuis Paramètres. `OnboardingVideoView.swift` : overlay
  maison (PAS une vraie `.sheet` système — même raison que
  `TemplatePickerView`/`ShotPickerView`, une sheet AppKit assombrit toute
  la fenêtre de façon non contrôlable depuis SwiftUI, déjà rejeté par
  l'utilisateur pour ces 2 popups), branché dans le même
  `GeometryReader`/overlay de `ContentView.swift`, piloté par
  `AppState.showOnboardingVideo`. `AVKit.VideoPlayer` sur un `AVPlayer`
  chargé depuis `Bundle.module` (contrôles de lecture natifs inclus,
  aucun besoin d'en construire).
  - **"Ne plus afficher"** (bouton dédié, DISTINCT du simple "Fermer"/✕) :
    persiste `has_seen_onboarding_video` dans `UserDefaults` — "Fermer"
    seul laisse la vidéo réapparaître au prochain lancement, seul "Ne
    plus afficher" mémorise le choix. `AppState.init()` positionne
    `showOnboardingVideo = true` au lancement SEULEMENT si ce drapeau
    n'est pas encore posé.
  - **Rejouable depuis Paramètres** (`ProjectSettingsSheet`, bouton "Voir
    la vidéo de présentation", `AppState.presentOnboardingVideo()`) —
    indépendant du drapeau "déjà vue". Piège évité : "Paramètres" est une
    VRAIE `.sheet` système (fenêtre séparée, au-dessus de `ContentView`)
    — sans `dismiss()` D'ABORD, l'overlay vidéo (posé sur `ContentView`,
    EN DESSOUS de cette sheet) se serait affiché invisible, caché
    derrière "Paramètres" resté ouvert.
  - **Vraie vidéo livrée le 2026-09-11** : `Package.swift` déclare
    `Resources/onboarding_video.mp4` — c'était un simple fond de couleur
    généré par `ffmpeg` (placeholder, aucun son, ~6s) jusqu'à ce que
    l'utilisateur fournisse la vraie vidéo de présentation (17s, 60fps,
    avec son). Remplacée par simple copie du fichier (même nom, même
    dossier `Resources/`) — AUCUN changement dans `Package.swift`, conforme
    à ce qui était prévu depuis le début : `Bundle.module.url(...)` pointe
    toujours vers le même nom de ressource, seul son contenu a changé.
    Vérifié une nouvelle fois que remplacer juste le CONTENU d'un fichier
    déjà déclaré est bien pris en compte par un rebuild incrémental normal
    (pas besoin du clean rebuild qui n'est nécessaire que pour une entrée
    `resources:` toute NOUVELLE dans `Package.swift`).
    **Format réel 1200×674** (mesuré via `ffprobe` sur le fichier fourni) —
    quasi du 16:9 (674 au lieu des 675 attendus pour un vrai 16:9), PAS le
    1200×800 (ratio 3:2) d'abord annoncé le 2026-09-08 pour le placeholder.
    `OnboardingVideoView` utilise maintenant
    `.aspectRatio(1200.0/674.0, contentMode: .fit)` (ratio exact de la
    vraie vidéo, pas une valeur ronde) pour que `AVPlayerView` n'ajoute
    aucune bande de letterbox/pillarbox superflue.
    **Corrigée une 2ème fois le même jour** ("il y avait une erreur dans la
    vidéo voici la bonne version") — mêmes dimensions exactes (1200×674,
    17s, 60fps), donc juste un nouveau remplacement de fichier, aucun
    changement de code (le `.aspectRatio` déjà en place restait valide).
    Piège à surveiller si ça se reproduit : `swift build` recopie bien le
    fichier mis à jour dans `.build/out/.../Resources/`, mais l'app `.app`
    lancée en dev (`dev_run.sh`, dossier `.build/dev-app/`) est une COPIE
    distincte — il faut relancer `dev_run.sh` (pas juste `swift build`)
    pour que le nouveau contenu atteigne réellement l'app affichée à
    l'utilisateur ; vérifié ici en comparant la taille du fichier dans les
    deux emplacements avant/après relance.
  - **Panneau de contrôle marges/spacings (2026-09-11)** — [RETIRÉ le
    2026-09-11, même jour, une fois les valeurs validées : "c'est bon on
    valide" puis "enlève les restes de dev" — même pattern déjà appliqué
    le 2026-09-03 à `TemplatePickerSpacing`/`ProjectViewSpacing` : le
    panneau ne sert qu'à TROUVER des valeurs, pas à rester dans le code
    une fois qu'elles sont figées. Les 6 constantes `default*` deviennent
    de simples constantes (`outerPadding`/`vstackSpacing`/`cardMaxWidth`/
    `chromeHeight`/`overlayPadding`/`overlaySpacing`, valeurs 40/20/900/
    200/15/12), tout le code `#if DEBUG` (sliders, `debugPanel`,
    `resetDebugValues`, `copyDebugValuesToClipboard`) supprimé.] Demande
    explicite ("un panneau de contrôle pour les marges et les spacings"),
    en réaction directe aux allers-retours capture d'écran → correctif →
    nouvelle capture déjà vécus sur cette vue (bug de marge du 2026-09-09
    ci-dessous). Portée choisie : ce popup uniquement (pas les 3 popups,
    pas toute l'app — trop large pour l'instant). Accès : bouton discret
    (icône `slider.horizontal.3`) en haut-gauche du popup, symétrique de
    la croix/du téléchargement en haut-droite, compilé UNIQUEMENT en build
    debug (`#if DEBUG`) — absent du binaire packagé par
    `packaging/build_app.sh -c release` (vérifié en buildant les 2
    configs : `swift build` ET `swift build -c release` compilent tous
    les deux sans erreur). 6 sliders réglables en direct :
    padding externe, espacement vertical du `VStack`, largeur max de la
    carte, budget "chrome" réservé hors vidéo (`chromeHeight`), padding et
    espacement du bloc croix/téléchargement. Toutes les valeurs codées en
    dur (40/20/900/260/16/12) sont devenues des constantes
    `default*` nommées (seul endroit à modifier pour rendre un réglage
    trouvé via le panneau permanent) plus une paire de propriétés
    calculées qui lisent soit l'état debug réglable, soit la constante,
    selon la configuration de build — donc AUCUN changement de
    comportement en Release, juste un point d'indirection en plus.
    Bouton "Copier les valeurs" (`NSPasteboard`) : évite à l'utilisateur
    de retaper les chiffres à la main, il lui suffit de coller le texte
    copié dans le chat pour que les valeurs soient reportées dans le code.
  - **Valeurs reportées le 2026-09-11** (texte collé depuis "Copier les
    valeurs") : `chromeHeight` 260→200, `overlayPadding` 16→15, le reste
    inchangé (`outerPadding`=40, `vstackSpacing`=20, `cardMaxWidth`=900,
    `overlaySpacing`=12). Observation utile de l'utilisateur en testant le
    curseur "Budget réservé (hors vidéo)" : en dessous d'environ 180-200,
    le déplacer n'a plus aucun effet visible ("je peux pas aller plus bas
    ça fait rien"). Diagnostic : à cette valeur, la vidéo n'est plus
    limitée par la HAUTEUR (`videoMaxHeight`) mais par la LARGEUR
    disponible de la carte (`cardMaxWidth` - 2×`outerPadding` ≈ 820px,
    qui donne une hauteur naturelle d'environ 460px vu le ratio 1200/674)
    — elle affiche déjà sa taille maximale pour cette largeur, donc lui
    accorder encore plus de hauteur via `chromeHeight` ne change plus
    rien. Pour compacter le popup davantage, les leviers qui comptent
    vraiment sont `outerPadding`/`vstackSpacing` (réduisent un espace
    RÉEL) ou augmenter `cardMaxWidth` (donne plus de large à la vidéo
    avant qu'elle ne re-plafonne en hauteur) — pas `chromeHeight`, qui
    n'est qu'un plafond théorique, sans effet une fois qu'il n'est plus la
    contrainte active.
  - **Bug réel corrigé le 2026-09-11 : marge LATÉRALE (largeur), pas
    hauteur** ("il y a un problème de dimensions c'est trop petit et du
    coup il y a pas de marge avec la popup", capture fournie sur la
    fenêtre par défaut 740×560). Distinct du bug de marge VERTICALE du
    2026-09-09 ci-dessous : celui-ci n'avait jamais eu d'équivalent en
    largeur. Cause : `.frame(maxWidth: cardMaxWidth)` (900) ne plafonne
    qu'un MAXIMUM, il ne réserve aucune marge — et la zone vidéo (une
    `GeometryReader`, intrinsèquement "gourmande" : elle s'étire toujours
    pour remplir tout ce qu'on lui propose) tire la carte entière jusqu'à
    occuper toute la largeur DISPONIBLE dès que la fenêtre est plus
    étroite que 900 (le minimum de l'app est 740) — zéro marge latérale.
    `TemplatePickerView`/`ShotPickerView` n'ont jamais ce problème : ils
    utilisent une largeur FIXE (pas de `GeometryReader` gourmande dedans).
    Fix, même famille que `popupMaxHeight` mais en largeur : `ContentView`
    calcule maintenant `popupMaxWidth = max(geo.size.width - 80, 360)`
    (mêmes 80pt réservés que la hauteur, 40 de chaque côté) et le passe à
    `OnboardingVideoView` via un nouveau paramètre `maxWidth` ; la carte
    utilise `.frame(maxWidth: min(cardMaxWidth, maxWidth))` — jamais plus
    large que 900 (le design), jamais plus large que la fenêtre moins la
    marge réservée. Vérifié en buildant les 2 configs (`swift build` ET
    `-c release`, 0 erreur), 98/98 self-tests, app relancée sans crash.
  - **Bug réel corrigé le 2026-09-11 : `.defaultSize` pas respecté DU
    TOUT** ("il faut réduire la largeur de l'app au lancement" →
    investigation a révélé que ce n'était pas un problème de largeur
    minimale de popup, comme soupçonné par l'utilisateur, mais que la
    fenêtre n'ouvrait carrément pas à la taille demandée). En vérifiant
    directement le fichier de préférences sur disque
    (`~/Library/Preferences/<bundle-id>.plist`) juste après un lancement
    bien FRAIS (aucun état sauvegardé, confirmé), la fenêtre ouvrait à
    ~1512×726 au lieu de 740×560 (`App.swift:.defaultSize`) — environ
    79%/69% de la taille de l'écran, pas une valeur liée au code. Cause :
    `ContentView`'s `.frame(minWidth: 740, maxWidth: .infinity, minHeight:
    560, maxHeight: .infinity)` n'avait NI `idealWidth` NI `idealHeight` —
    sans taille "idéale" concrète pour la mise en page racine, AppKit/
    SwiftUI retombe sur une heuristique basée sur l'écran plutôt que sur
    `.defaultSize`. Fix : ajouter `idealWidth`/`idealHeight` à ce `.frame`,
    alignés EXACTEMENT sur `.defaultSize` — les deux DOIVENT rester
    synchronisés (commentaires croisés dans les 2 fichiers). Vérifié
    rigoureusement : app tuée et confirmée totalement quittée AVANT
    d'effacer la clé "NSWindow Frame …" (sinon l'ancien process la
    réécrit à la fermeture — piège rencontré une fois pendant le
    diagnostic), puis relancée et la taille réelle relue directement sur
    disque (pas juste `defaults read`, qui peut servir un cache
    `cfprefsd` périmé).
    **Valeur changée le même jour** ("passe en 1000x750") : `.defaultSize`
    passe de 740×560 à 1000×750 — DÉCOUPLÉ du minimum de fenêtre
    (`minWidth`/`minHeight`, restés 740×560, toujours alignés sur
    `TemplatePickerView`) : une taille idéale/d'ouverture plus grande que
    le plancher minimum est parfaitement valide en SwiftUI. Revérifié sur
    disque après le changement : fenêtre ouvre bien à 1000×750 pile.
    **Valeur finale 1300×750** (2026-09-11, via le panneau de debug
    largeur/hauteur ci-dessous — "Copier les valeurs" : "1300 × 750") —
    `.defaultSize` ET `idealWidth`/`idealHeight` (`ContentView.swift`) mis
    à jour ensemble, toujours synchronisés.
  - **Panneau de contrôle largeur/hauteur de fenêtre (2026-09-11)** —
    [RETIRÉ le 2026-09-11, même jour, une fois la valeur 1300×750 validée
    — même vague de nettoyage que le panneau marges/spacings ci-dessus
    ("c'est bon on valide" puis "enlève les restes de dev") :
    `WindowAccessor`, `windowSizeDebugOverlay`/`windowSizeDebugPanel`,
    `debugWindow`/`debugWindowWidth`/`debugWindowHeight`/
    `showWindowSizePanel`, `applyDebugWindowSize()`,
    `copyDebugWindowSizeToClipboard()` — tout supprimé de
    `ContentView.swift`. La valeur trouvée (1300×750) reste, elle, dans
    `App.swift:.defaultSize` et `ContentView.swift`'s `idealWidth`/
    `idealHeight` (voir plus haut), qui eux ne bougent pas.]
    demande explicite ("met un panneau de contrôle pour contrôler la
    largeur et la hauteur de la fenêtre et je te donnerais les données"),
    en réaction directe au diagnostic `.defaultSize`/`idealWidth`
    ci-dessus : tester des tailles en DIRECT sur la vraie fenêtre plutôt
    que deviner une valeur et attendre un nouveau build+zip à chaque
    itération. `ContentView.swift`, dev-only (`#if DEBUG`), même pattern
    que le panneau de marges/spacings d'`OnboardingVideoView` : bouton
    discret (icône `macwindow`) en bas à gauche de la fenêtre → panneau
    avec un slider ET un `TextField` par dimension (largeur/hauteur,
    demande explicite du même jour : "je puisse rentrer manuellement les
    valeurs en plus du curseur" — les 2 contrôles partagent le même
    `@State`, un seul `.onChange` par dimension posé sur le `VStack`
    englobant plutôt que dupliqué sur chaque contrôle) + bouton "Copier
    les valeurs". `WindowAccessor` (`NSViewRepresentable`, même idiome que
    `Theme.swift`'s `WindowBackgroundAccessor`) capture la vraie
    `NSWindow` ; `applyDebugWindowSize()` la redimensionne en gardant son
    CENTRE fixe (pas son coin haut-gauche, sinon la fenêtre "part" vers un
    bord de l'écran à chaque glissement de curseur). Piège technique
    rencontré : `TextField(value:format: .number)` exige `Double`/`Int`
    (`ParseableFormatStyle`), pas directement `CGFloat` — pontée via une
    `Binding<Double>` calculée (`get`/`set` convertissant vers/depuis
    `CGFloat`), le `Slider` juste à côté continuant d'utiliser le
    `CGFloat` natif directement (lui n'a pas ce problème).
  - **Bug réel corrigé le 2026-09-09, en 2 temps** ("il y a de la marge
    en haut et pas en bas, il faut la même en bas qu'en haut" — puis,
    après un 1er correctif insuffisant : "ça a rien changé il faut qu'il
    y ait la marge peu importe la dimension de la fenêtre").
    1. **1ère piste (INSUFFISANTE, gardée quand même)** : soupçon que
       `AVPlayerView` (vue AppKit, `AVPlayerNSView`) ne respecte pas
       fiablement `.aspectRatio(fit)` une fois en `NSViewRepresentable`.
       La zone vidéo est enveloppée dans un `GeometryReader` qui lui
       impose une taille EXPLICITE (`.frame(width:height:)` depuis
       `geo.size`) plutôt que de compter sur `.aspectRatio` seul — reste
       en place par prudence (plus robuste dans tous les cas), mais
       n'expliquait PAS le vrai symptôme : l'utilisateur a confirmé
       "ça a rien changé".
    2. **Vraie cause** : contrairement à `TemplatePickerView`/
       `ShotPickerView` (les 2 autres popups plein écran de l'app),
       `OnboardingVideoView` n'avait AUCUN plafond de hauteur — sur une
       fenêtre pas assez haute, la carte entière pouvait devenir plus
       grande que la fenêtre, et c'est CE débordement qui mangeait la
       marge basse (`.padding(40)`), peu importe ce qui se passait à
       l'intérieur de la zone vidéo. Fix : `ContentView` lui passe
       maintenant `popupMaxHeight` (le MÊME budget déjà calculé pour
       `ShotPickerView`, depuis la vraie hauteur de fenêtre) via un
       nouveau paramètre `maxHeight`. À l'intérieur, `videoMaxHeight`
       (`maxHeight` moins un budget `chromeHeight`=260 réservé au
       titre/à la description/à la case à cocher/aux 2 marges) plafonne
       SEULEMENT la zone vidéo (`.frame(maxHeight:)` après
       `.aspectRatio`) — c'est elle qui rétrécit en premier, jamais le
       titre/la case à cocher/les marges. Un 2ème filet de sécurité
       (`.frame(maxHeight: maxHeight)` sur le popup ENTIER) garantit
       que la carte ne déborde JAMAIS de la fenêtre même si
       `chromeHeight` sous-estimait — même filet que `ShotPickerView`.
  - **Bug réel corrigé le 2026-09-08** : `SwiftUI.VideoPlayer` (AVKit)
    essayé en premier — l'app PLANTAIT au lancement (`EXC_CRASH`/
    `SIGABRT`, fatal error Swift profondément dans la résolution de
    métadonnées génériques — `swift_getTypeByMangledName`/
    `getSuperclassMetadata` — pile complète dans
    `~/Library/Logs/DiagnosticReports/AgenceTemplate3D-*.ips`), avant
    même d'afficher quoi que ce soit. Cause probable : `VideoPlayer`
    (composant SwiftUI déclaratif) mal supporté dans cet exécutable
    SwiftPM pur sur cette combinaison Swift/SDK — jamais creusé plus loin,
    contourné à la place par `AVPlayerView` (composant AppKit historique,
    plus stable) enveloppé dans un `NSViewRepresentable`
    (`AVPlayerNSView`) — même famille de solution que `WKWebView` déjà
    utilisé ailleurs dans ce projet pour une raison différente mais
    similaire (une vue AppKit directement, plutôt que son équivalent
    déclaratif SwiftUI). Vérifié en relançant l'app dev plusieurs fois de
    suite après le correctif : plus de crash, processus stable.
  - **Mise en page revue (2026-09-08)**, capture d'écran fournie par
    l'utilisateur — 1er essai (petit dialog 560pt, titre+bouton en ligne,
    2 boutons "Fermer"/"Ne plus afficher" en bas) jugé pas ce qu'il
    voulait. Version actuelle : grand popup centré
    (`.modalCardBackground()`, `maxWidth: 900`, même famille visuelle que
    `TemplatePickerView`/`ShotPickerView`) — titre ET description
    centrés, vidéo en grand (16:9), une croix ✕ en haut à droite du popup
    (PAS un bouton "Fermer" texte), et surtout : "Ne plus afficher à
    l'ouverture" devient une VRAIE case à cocher (`Toggle` +
    `.toggleStyle(.checkbox)`) flottante en bas à droite (légèrement EN
    DEHORS du coin du popup via `.offset`) — INDÉPENDANTE de la
    fermeture : la cocher mémorise le choix tout de suite
    (`AppState.suppressOnboardingVideoOnLaunch`, backée par
    `UserDefaults`) SANS fermer le popup, l'utilisateur ferme séparément
    (croix, clic sur le scrim, ou Échap — mêmes 3 façons que les 2 autres
    popups, ajoutées ici aussi à cette occasion : le 1er essai n'avait
    volontairement PAS de fermeture par clic extérieur, jugé à tort
    risqué "pendant qu'une vidéo joue").
    `AppState.dismissOnboardingVideo(permanently:)` (une seule méthode
    qui faisait les 2 choses à la fois) remplacée par 2 API séparées :
    `closeOnboardingVideo()` (juste fermer) et la propriété calculée
    `suppressOnboardingVideoOnLaunch` (juste la préférence) — reflète la
    séparation demandée dans l'UI.
  - **Téléchargement (2026-09-08)** — un 2ème bouton icône à côté de la
    croix (`square.and.arrow.down`) : `AppState.
    downloadOnboardingVideo()` copie le fichier bundlé
    (`Bundle.module.url(forResource: "onboarding_video",
    withExtension: "mp4")`) vers un emplacement choisi via `NSSavePanel`
    — même style direct-AppKit que `presentOpenBlendPanel`/
    `presentChangeProjectsRootPanel` (pas de composant SwiftUI).
  - **Case à cocher ramenée À L'INTÉRIEUR de la carte (2026-09-08)** —
    demande explicite juste après le design ci-dessus : le `.offset` qui
    la faisait flotter en dehors du coin bas-droit (fidèle à la capture
    d'écran d'origine) a finalement été jugé pas voulu. Redevenue un
    simple dernier élément du `VStack` principal, alignée à droite via
    `HStack { Spacer(); Toggle(...) }` — toujours dans les marges de
    `.padding(40)` de la carte, plus aucun `.offset`/`ZStack` séparé
    nécessaire pour elle.
  - **Bug réel corrigé le 2026-09-08 : "le bouton ne se cochait pas
    quand je cliquais dessus"** — `suppressOnboardingVideoOnLaunch`
    avait été écrite comme propriété CALCULÉE lisant `UserDefaults`
    directement (`get`/`set` inline) — EXACTEMENT le piège déjà
    documenté juste au-dessus sur `hasChosenProjectsRoot` dans ce même
    fichier ("`@Observable` ne suit que les propriétés STOCKÉES ; une
    calculée qui lit une source externe ne notifie JAMAIS SwiftUI d'un
    changement") : la valeur changeait bien dans `UserDefaults` à chaque
    clic, mais `@Observable` ne le détectait jamais, donc SwiftUI ne
    redessinait jamais la case cochée/décochée à l'écran. Corrigé en la
    rendant PROPRIÉTÉ STOCKÉE avec `didSet` persistant dans
    `UserDefaults` — même pattern EXACT que `projectsRoot` juste au-dessus
    dans `AppState.swift`, qui documentait déjà ce piège sans que je le
    réapplique moi-même la première fois pour cette nouvelle propriété.

- **Alignement sur les visuels Figma définitifs (2026-09-08)** — l'utilisateur
  a fourni 6 captures des maquettes finales (accueil, projet en rendu,
  "Assigner un plan", "Choisissez un preset", projet mode libre,
  "Paramètres") avec pour consigne : "si tu vois des différences avec la
  version qu'on a, tu corrige". Comparé au code, PAS à l'oeil sur des
  captures d'écran de l'app (jamais utilisé de computer-use sur ce projet)
  — en lisant le texte/la structure exacte de chaque vue concernée.
  Différences trouvées et corrigées :
  - `TemplatePickerView` ("Choisissez un preset", `ContentView.swift`) :
    titre "Sélectionnez un preset" → **"Choisissez un preset"** ; bouton de
    pied de page "Annuler" → **"Fermer"**.
  - `ShotPickerView` ("Assigner un plan", `ProjectView.swift`) : même
    correctif, bouton "Annuler" → **"Fermer"**.
  - `ProjectColorSettingsView.swift` : libellé du swatch "Fond" →
    **"Couleur du fond :"**.
  - **"Anciens projets" (`ContentView.landing`)** : le bouton "Voir tout"
    (2026-09-08, ajouté plus tôt le même jour) est repositionné — plus un
    bouton pleine largeur SOUS la liste ("Voir les N projets restants dans
    le Finder"), mais un lien discret À CÔTÉ du titre "Anciens projets"
    (même ligne, `HStack` + `Spacer()`, style `.plain` + `.dimText()`),
    TOUJOURS visible (plus conditionné à `hiddenOlderCount > 0` — sur la
    maquette c'est un raccourci général "voir tout", pas seulement un
    accès au surplus caché). `olderProjectsLimit` : 7 → **6** (nombre exact
    de lignes visibles sur la maquette).
  - **Point vérifié PUIS écarté** : l'en-tête du projet affiche "Menu"
    (état normal) vs "Changer de preset" (2 des 6 captures, avec une popup
    ouverte par-dessus) — question posée à l'utilisateur plutôt que de
    deviner (ça changerait un vrai comportement : fermer le projet vs
    ouvrir le sélecteur de presets). Réponse : "Menu" reste tel quel —
    "Changer de preset" est une incohérence entre 2 versions du Figma, pas
    une vraie différence à corriger.
  - **Confirmé correct sans y toucher** : le retrait de "Sections
    importantes" fait plus tôt ce même jour colle exactement à la maquette
    "Paramètres" définitive (aucune trace de ce toggle dessus) — aucune
    régression, dans le bon sens cette fois. Structure de `PageRowView`
    (nom/URL/capture/Plans/Assigner un plan), `ProjectSettingsSheet`
    ("Couleurs personnalisées" + description + "Voir la vidéo de
    présentation"), `RenderControlsView` (Test/Rendu final + Lancer le
    rendu), `RenderPreviewPanel` (aperçu 16:9 + frame/ETA + barre de
    progression) : tous déjà conformes, aucun changement nécessaire.

## Compatibilité Blender 5.x (2026-09-11)

Demande initiale anodine ("mets le setup Blender dans le zip avec l'app") a
révélé une vraie incompatibilité : l'utilisateur avait 2 installeurs Blender
5.x dans Téléchargements (5.1.2, 5.2.1), jamais testés avec ce projet — seule
la 4.5.3 LTS (installée sur cette machine, utilisée pour TOUS les tests
depuis le début du portage) était réellement validée. Question posée avant
d'agir : laquelle bundler ? Réponse : "teste l'app pour blender 5.2.1 je
viens de l'installer" (remplace la 4.5.3 sur la machine, plus de retour en
arrière possible sans réinstaller).

- **Suite de self-tests : 6 échecs** dès la 1ère tentative de rendu réel sur
  Blender 5.2.1 — tous liés à la même cause racine, isolée précisément via
  `Blender --background --factory-startup --python-expr "..."` (jamais de
  computer-use, comme d'habitude sur ce projet) plutôt qu'en devinant :
  ```
  enum "FFMPEG" not found in ('AVIF', 'JPEG', 'OPEN_EXR', 'PNG', 'WEBP',
  'BMP', 'CINEON', 'DPX', 'IRIS', 'JPEG2000', 'HDR', 'TARGA', 'TARGA_RAW',
  'TIFF')
  ```
  Recherche web (queue de bugs officielle Blender) confirme : **Blender 5.0
  a ajouté `image_settings.media_type`** (`'IMAGE'`/`'MULTI_LAYER_IMAGE'`/
  `'VIDEO'`), qui FILTRE les valeurs acceptées par `file_format` — `'FFMPEG'`
  n'apparaît dans l'énum que si `media_type = 'VIDEO'` est posé AVANT. Pas
  une suppression de fonctionnalité, un changement d'ordre d'appels dans
  l'API. Absent en Blender 4.x (`hasattr` protège).
  - **Fix** : nouvelle fonction `_set_image_format(image_settings,
    file_format)` dans `blender_side/headless.py` (juste après
    `_set_render_engine`) — pose `media_type` (`'VIDEO'` pour `'FFMPEG'`,
    `'IMAGE'` sinon) SI la propriété existe, puis `file_format`. Remplace
    les 5 assignations directes (`apply_render_mode_settings` ×2 modes,
    sauvegarde/restauration dans `cmd_list_shots`, l'assemblage final dans
    `_render_and_concat_blocks`, l'aperçu couleur dans `cmd_render`) — un
    seul endroit à corriger si l'API change encore.
- **2ème échec après le 1er fix, DIFFÉRENT** : le rendu progressait
  maintenant jusqu'au bout (99/99 frames) mais échouait à l'assemblage
  final :
  ```
  'SequenceEditor' object has no attribute 'sequences'
  ```
  `sequence_editor.sequences` → `.strips` en Blender 5.x (renommage
  terminé ; `.strips` existait déjà comme alias en 4.x). Fix dans
  `_render_and_concat_blocks` : `strips = seq.strips if hasattr(seq,
  "strips") else seq.sequences`.
  - **Piège rencontré PENDANT ce fix** : 1er essai écrit `getattr(seq,
    "strips", None) or seq.sequences` — l'erreur persistait IDENTIQUE
    malgré le fix. Cause : au moment de cet appel, la collection `strips`
    est VIDE (rien ajouté encore) — une collection Blender vide est FAUSSE
    en contexte booléen (comme une liste Python vide), donc le `or`
    retombait quand même sur `seq.sequences`, qui n'existe pas en 5.x.
    **Leçon à ne pas re-perdre** : ne JAMAIS utiliser `getattr(obj, "attr",
    None) or repli` pour détecter la PRÉSENCE d'un attribut dont la valeur
    peut être un conteneur vide (liste/collection/dict) — utiliser
    `hasattr(obj, "attr")` explicitement, `or` teste la valeur de vérité
    du résultat, pas son existence.
- **Après les 2 fixes : 98/98 self-tests, 0 échec**, rendu réel complet
  vérifié de bout en bout sur Blender 5.2.1 (frames + assemblage vidéo +
  fichier de sortie écrit). Les 2 fixes utilisent `hasattr` donc restent
  compatibles Blender 4.x en théorie — PAS re-vérifié directement dessus
  (la 4.5.3 n'est plus installée sur cette machine, remplacée par la
  5.2.1, aucun installeur 4.5.3 disponible localement pour la
  réinstaller).
- **Livraison** : `packaging/build_app.sh` copie déjà `headless.py` dans le
  bundle (`Contents/Resources/blender_side/`), donc le fix est
  automatiquement inclus dans tout nouveau build release — vérifié en
  comptant les occurrences de `_set_image_format`/`hasattr(seq, "strips"`
  dans la copie bundlée après packaging. Zip final envoyé à l'utilisateur :
  `DigitalMockup.app` + `blender-5.2.1-macos-arm64.dmg` (346 Mo, le fichier
  qu'il avait dans Téléchargements) + `LISEZMOI.txt` (3 étapes : installer
  Blender dans `/Applications` → installer l'app → 1er lancement avec
  clic droit "Ouvrir" pour contourner Gatekeeper) — zippés ensemble
  (~400 Mo), nom de dossier volontairement SANS tiret cadratin (`—`) pour
  éviter tout souci d'encodage avec d'autres outils de décompression que
  ceux d'Apple.

## Mises à jour automatiques (Sparkle) — 2026-09-14

Demande explicite : "comment on peut faire pour que je puisse faire des
mises a jour de l'app sans qu'ils ai besoin de la réinstaller ?" — décidé
avec l'utilisateur (2 questions posées) : hébergement sur **GitHub**
(repo public [`gyarado04/digitalmockup`](https://github.com/gyarado04/digitalmockup)),
mécanisme **Sparkle** (le standard macOS hors App Store), pas une simple
notification+lien.

### Mise en place
- **Repo Git créé** (le projet n'en avait pas) — voir `.gitignore` pour ce
  qui est volontairement exclu : `.build/`/`dist/` (artefacts), l'ancien
  app Python (`app/`, `run_app.py`, `requirements.txt`, packaging
  PyInstaller à la racine — gardés en LOCAL comme référence historique,
  pas publiés), `CONTEXTE_APP_POUR_IA.md`, la clé privée Sparkle. Le
  `README.md` racine, lui, a été RÉÉCRIT (pas exclu) pour décrire la
  version Swift actuelle plutôt que l'archi Python obsolète.
- **Sparkle 2.10.0** ajouté via SPM (`Package.swift`, dépendance exacte
  épinglée). `App.swift` : `SPUStandardUpdaterController` (démarré
  `startingUpdater: true` dans l'`init`) + entrée de menu "Rechercher les
  mises à jour…" (`CommandGroup(after: .appInfo)`, emplacement standard
  Sparkle).
- **Clé de signature EdDSA** générée (`generate_keys`, stockée dans le
  Trousseau) — `SUPublicEDKey` posée dans l'Info.plist des 2 scripts de
  build.
- **`Sparkle.framework` embarqué** dans `Contents/MacOS/` (PAS
  `Contents/Frameworks/`, convention Xcode habituelle mais inutile ici :
  l'exécutable le lie via `@rpath/Sparkle.framework/...`, et
  `@loader_path` — déjà présent parmi ses rpaths, posé par SwiftPM lui-
  même, vérifié via `otool -l` — résout déjà au dossier CONTENANT
  l'exécutable). Copié dans `dev_run.sh` ET `packaging/build_app.sh`
  (sans lui, l'app ne lance même pas — dylib manquant au chargement).
- **`SUFeedURL`** = `https://raw.githubusercontent.com/gyarado04/digitalmockup/main/appcast.xml`
  — l'app installée relit périodiquement ce fichier (`SUEnableAutomaticChecks`
  + `SUScheduledCheckInterval`=86400s) pour savoir si une version plus
  récente existe.
- **`packaging/build_app.sh`** prend maintenant 2 arguments optionnels,
  `VERSION` et `BUILD_NUMBER` (`CFBundleShortVersionString`/
  `CFBundleVersion`) — défauts sensés pour un simple build de test local
  (`"0.0.0"`/timestamp Unix) si omis.
- **`packaging/release.sh`** (nouveau) — orchestre une VRAIE publication :
  build signé → signature EdDSA du zip (`sign_update`) → nouvelle entrée
  dans `appcast.xml` (script Python inline, insérée en tête de liste) →
  commit + push de l'appcast et du compteur de build
  (`packaging/BUILD_NUMBER`, tracké en Git) → `gh release create` avec le
  zip en pièce jointe. Usage : `./packaging/release.sh 1.2.0`.
- **v1.0.0 publiée** avec ce pipeline — appcast et zip vérifiés
  publiquement accessibles (`curl`, taille exacte = celle signée).

### Piège rencontré en signant : Keychain bloqué en headless
`sign_update` lit la clé privée depuis le Trousseau par défaut, ce qui
déclenche une fenêtre d'autorisation système (SecurityAgent) — invisible
et impossible à approuver depuis une session Claude Code (jamais de
computer-use sur ce projet). Pire : l'autorisation donnée en cliquant
"Toujours autoriser" dans le Terminal de l'utilisateur NE S'APPLIQUE PAS
aux commandes lancées par Claude (ACL liée au process appelant, pas
juste à l'outil). **Fix définitif** : exporter la clé privée dans un
fichier local (`generate_keys -x packaging/sparkle_private_key.pem`, une
seule fois, avec l'aide de l'utilisateur dans SON Terminal) puis
`sign_update --ed-key-file packaging/sparkle_private_key.pem` pour
toutes les signatures futures — aucune interaction Trousseau requise.
Fichier **jamais committé** (`.gitignore` : `sparkle_private_key*`).

### Signature ad-hoc → Sparkle bloqué → RÉSOLU avec un certificat GRATUIT
Après tout le pipeline mis en place et une v1.0.0 publiée, le
vérificateur de mise à jour ne se déclenchait jamais en pratique — confirmé
rigoureusement (`/usr/bin/log show` — PAS le `log` de zsh, un builtin qui
piège avec "too many arguments" ; `lsof -i` sur le process ; `ps aux` pour
un XPC Sparkle qui ne spawnait jamais) : aucune requête réseau, aucun log
Sparkle. Cause identifiée précisément via le log `amfid` :
```
amfid: .../Sparkle.framework/Versions/B/Sparkle not valid:
Error Domain=AppleMobileFileIntegrityError Code=-423
"The file is adhoc signed or signed by an unknown certificate chain"
```
La **Library Validation** du runtime durci macOS rejette
`Sparkle.framework` en signature 100% ad-hoc — limitation documentée de
Sparkle (voir
[developer.apple.com/forums/thread/737571](https://developer.apple.com/forums/thread/737571)).
2 tentatives de contournement en pur ad-hoc (`--options runtime` seul →
a empiré les choses, crash "different Team IDs" ; puis
`packaging/entitlements.plist` avec
`com.apple.security.cs.disable-library-validation` → aucun effet non plus)
ont toutes deux échoué — la conclusion à ce stade était qu'un VRAI
certificat semblait nécessaire, payant (Developer ID, 99$/an) ou non.

**Décision utilisateur (2026-09-14)** : "on continue sans certificat pour
l'instant" → menu "Rechercher les mises à jour…" masqué,
`startingUpdater: false` (un bug réel corrigé au passage : `true` seul
provoquait une popup d'erreur bloquante AU LANCEMENT sur un vrai poste
utilisateur — "Unable to Check For Updates" — alors qu'elle semblait
"silencieuse/inoffensive" d'après des tests seulement locaux ; **leçon**
gardée : ne jamais déclarer un comportement "confirmé inoffensif" sur la
base de tests SEULEMENT locaux).

**Rebondissement le même jour** : question posée — "il y a pas de
solution pour faire sans les 99$ par an ?" — un certificat **"Apple
Development" GRATUIT** (Xcode → Settings → Accounts → Apple ID personnel,
PAS le programme payant) donne une vraie identité de signature (pas
ad-hoc), et la Library Validation vérifie la cohérence d'identité entre
l'app et ses frameworks embarqués, pas spécifiquement "developer ID payant
contre gratuit". Testé — **ça marche**.

**Mise en place** :
- Compte Apple ID personnel ajouté dans Xcode, certificat "Apple
  Development" généré via "Manage Certificates… → +".
- **Piège rencontré** : le certificat généré n'était PAS reconnu comme une
  identité de signature valide (`security find-identity -v -p codesigning`
  → "0 valid identities found") malgré sa présence dans le Trousseau —
  `codesign` échouait avec "unable to build chain to self-signed root".
  Cause : la chaîne de confiance était incomplète — le certificat
  intermédiaire Apple installé (WWDR) était de la MAUVAISE génération
  (comparaison précise des "Key Identifier" X.509 du certificat dev vs de
  l'intermédiaire installé : le dev cert exigeait la génération **G3**,
  une autre génération était présente). Fix : téléchargé et installé
  `AppleWWDRCAG3.cer` + `AppleIncRootCertificate.cer` (certificats
  officiels Apple, `www.apple.com/certificateauthority/`) via `security
  add-certificates`/`add-trusted-cert` — `security verify-cert` confirme
  ensuite la chaîne valide, `find-identity` trouve l'identité.
- `packaging/build_app.sh` détecte maintenant AUTOMATIQUEMENT ce
  certificat (`security find-identity -v -p codesigning | grep "Apple
  Development"`) et signe avec — repli sur ad-hoc (`-`) si aucun trouvé
  (portable : fonctionne aussi sur une machine pas encore configurée,
  juste sans Sparkle fonctionnel dans ce cas).
- `App.swift` : `startingUpdater: true` réactivé, menu "Rechercher les
  mises à jour…" redécommenté.
- **Testé bout en bout, avec succès** : "You're up to date! DigitalMockup
  1.0.1 is currently the newest version available." (vérification
  manuelle), PUIS le vrai scénario "mise à jour disponible" (v1.0.1
  installée détecte et propose la v1.0.2 fraîchement publiée) —
  **confirmé par l'utilisateur en personne sur sa machine**.
- **Piège rencontré pendant CE test** : le tout premier essai du scénario
  "mise à jour disponible" a échoué (Sparkle affichait encore "1.0.1 is
  the newest" après publication de la 1.0.2) — pas un bug Sparkle, un
  **cache CDN** : `raw.githubusercontent.com` sert `cache-control:
  max-age=300` (5 min), confirmé en comparant une requête normale (cache
  HIT, contenu périmé) contre une requête avec paramètre anti-cache
  (`?bust=...`, contenu à jour immédiat). Attendu l'expiration du cache
  (`ScheduleWakeup`, ~200s) puis retesté avec succès. **À savoir pour la
  suite** : une mise à jour publiée peut mettre jusqu'à 5 minutes avant
  d'être vue par les apps qui vérifient à ce moment précis — non
  bloquant pour un usage interne petite équipe, juste à ne pas s'étonner
  si un test immédiat après publication semble ne rien détecter.

**Résultat final** : mises à jour automatiques pleinement fonctionnelles,
SANS payer les 99$/an — juste un compte Apple personnel gratuit + le bon
certificat intermédiaire Apple installé une fois. `packaging/release.sh`
publie ; les apps déjà installées se mettent à jour toutes seules (petite
fenêtre native de confirmation à chaque mise à jour trouvée, norme de
sécurité macOS — pas de silence total possible, mais aucune réinstallation
manuelle requise).

## Pas encore fait

- ~~Vidéo au survol~~ **FAIT** (2026-09-02) : `HoverVideoThumbnail.swift`
  (nouveau) — `AVQueuePlayer`+`AVPlayerLooper` (boucle fiable, muet),
  portage de `card_grid.py:HoverVideoLabel` (mode standalone ; AVPlayerLayer
  n'a pas le bug d'affichage de `QVideoWidget` qui forçait Python à peindre
  chaque frame à la main). Branchée dans `TemplateCard`
  (`ContentView.swift`) SEULEMENT — vérifié en lisant `headless.py:
  cmd_list_shots` que `list_shots` ne renvoie JAMAIS de clé `"video"` pour
  un plan assigné (juste `name`/`thumbnail`/`frames`), donc
  `PlanChipView` n'a rien à gagner d'une vidéo au survol : ce n'était pas
  un renoncement, juste inutile — seuls les TEMPLATES ont un `videoPath`
  réel (`templates/manifest.json`, "tablette" → `video.mp4`).
- ~~Miniatures dans le sélecteur de plans~~ **FAIT** (2026-09-02) :
  `PlanChipView` (nouveau, `ProjectView.swift`) affiche la vraie miniature
  de chaque plan assigné (`CameraShot.thumbnail`, déjà renvoyée par
  `list_shots`/`refreshShots()`, juste pas affichée jusqu'ici) + un bouton
  de retrait par plan — **trou fonctionnel comblé au passage** : il n'y
  avait jusque-là AUCUN moyen de désassigner un seul plan d'une page (juste
  supprimer la page entière). Distingue "en cours de chargement"
  (`ProgressView`) de "introuvable" (triangle orange) — même règle que
  `page_widget.py:_rebuild_plan_cards`, jamais confondre les deux (un
  triangle pendant un simple chargement induit en erreur, bug déjà corrigé
  une fois côté Python). Miniatures aussi ajoutées à la liste du sélecteur
  "Assigner un plan" (`PlanPickerButton.picker`).
- ~~Capture web~~ **FAIT** (`WebCapture.swift`, Core) : capture native
  macOS via `WKWebView` + `takeSnapshot` (décidé avec l'utilisateur le
  2026-09-01), aucune dépendance Node/Chromium/Playwright. Séquence :
  scroll progressif pour déclencher les animations, retour en haut, puis
  capture par tranches à la vraie taille de viewport recollées en une
  image pleine page (`captureStitched`, voir bug du 2026-09-08 plus bas —
  PAS un resize-à-la-hauteur-complète-puis-un-seul-snapshot, essayé
  d'abord comme `capture.py`/Playwright, mais qui cassait les animations
  d'apparition au scroll).
  Aucune macro SwiftUI utilisée (`@MainActor` seul suffit) → compile SANS
  Xcode, contrairement au reste de l'UI. **Câblée dans l'UI depuis le
  2026-09-02**, voir plus haut.
  - **Bug réel corrigé le 2026-09-03** ("les images ne sont pas pris dans
    la capture", constaté sur un vrai projet client — photo héro + bloc de
    chiffres + cartes "objectifs" absents du rendu final) : 3 causes
    cumulées. (1) `didFinish navigation` ne signale que le document
    PRINCIPAL chargé, pas les requêtes asynchrones suivantes (images,
    ajax) — Playwright attendait explicitement `wait_until="networkidle"`
    côté Python, portage manquant ; ajouté `waitForNetworkIdle` (sondage
    de la Resource Timing API) + `waitForImagesToLoad` (`img.complete`).
    (2) La "photo héro" en cause était en réalité une `<video autoplay
    muted>` (fond animé, très courant) — `document.images` ne contient
    pas les `<video>`, il fallait un contrôle séparé
    (`waitForVideosToLoad`, `readyState >= HAVE_CURRENT_DATA`) + forcer
    `.play()` + autoriser l'autoplay dans la `WKWebViewConfiguration`.
    (3) **La cause la plus profonde** : une `<video>` reste bloquée à
    `readyState 0` (ses `<source>` jamais traités) tant que la WKWebView
    n'est PAS attachée à une VRAIE fenêtre — `capture()` en crée
    désormais une (quasi invisible, `alphaValue ~0`) le temps de la
    capture (`useHostWindow: true` par défaut). Les 3 correctifs
    vérifiés ensemble sur le vrai site en cause : hero vidéo, bloc
    "150+ Entreprises", les 4 cartes "Nos objectifs" et tous les logos
    partenaires apparaissent enfin dans la capture.
  - **Bug réel corrigé le 2026-09-08** ("il n'y a pas les animations
    d'apparition" — les animations D'ÉLÉMENTS au scroll, style AOS/
    ScrollReveal/GSAP ScrollTrigger/interactions Webflow, pas le scroll de
    la caméra 3D dans le rendu final, qui lui n'a jamais posé problème).
    Cause : juste avant le snapshot final, `capture()` redimensionnait la
    `WKWebView` à la hauteur COMPLÈTE de la page (`document.scrollHeight`)
    pour capturer toute la page en un seul `takeSnapshot`. Or la plupart
    des bibliothèques d'animation au scroll calculent leurs seuils de
    déclenchement à partir de `window.innerHeight` — une fois la fenêtre
    aussi haute que la page entière, `scrollHeight == innerHeight` : plus
    aucun scroll possible (`scrollY` bloqué à 0), donc plus rien ne se
    déclenche (ou se réinitialise sans jamais se redéclencher, selon la
    bibliothèque). Les éléments concernés restaient donc bloqués dans leur
    état de départ (transparent/décalé) sur l'image capturée.
    Fix : `captureStitched` (nouvelle méthode) — la `WKWebView` n'est
    **plus jamais redimensionnée**, elle garde sa vraie taille de viewport
    du début à la fin. La page complète est capturée par TRANCHES (une
    par hauteur de viewport, en scrollant réellement avec
    `window.scrollTo` comme le ferait un vrai visiteur, avec une pause
    (`sliceSettleNs`=700ms) après chaque scroll pour laisser une
    transition CSS/JS finir de jouer), puis les tranches sont recollées en
    une seule image via un `CGContext` (composition pixel-exacte, échelle
    Retina déduite de la tranche elle-même — même principe que la
    correction du noeud Mapping, voir plus bas). Générique : ne dépend
    d'aucune connaissance de la bibliothèque d'animation utilisée par tel
    ou tel site client, contrairement à une liste de correctifs par
    bibliothèque.
    Élément `position: fixed`/`sticky` (barre de nav, bouton flottant…) :
    masqué (`visibility: hidden`, JS) pendant toutes les tranches SAUF la
    première (scrollY=0, sa position naturelle) pour éviter qu'il
    apparaisse dupliqué à chaque tranche de l'image finale — liste calculée
    une seule fois avant la boucle de tranches, restaurée après chaque
    snapshot.
    Piège rencontré en route : la nouvelle `NSImage` (construite depuis un
    `CGImage` assemblé, `NSImage(cgImage:size:)`) prend la taille passée
    EXACTEMENT telle quelle — contrairement à celle que renvoyait
    `takeSnapshot` (toujours en points/CSS px, indépendamment du facteur
    Retina). Avait été codé par erreur avec la taille en PIXELS RÉELS
    (`widthPx`/`totalHeightPx`, ex. 800×6000 au lieu de 400×3000 attendu en
    Retina 2x) — détecté par le self-test dédié (`WebCapture PNG fait bien
    400 de large` / `capture la page ENTIÈRE`), corrigé en repassant à la
    taille logique (`viewportWidth`/`effectiveFullHeight`). Les pixels
    RÉELS écrits dans le PNG (ce que lit `headless.py` via PIL pour
    détecter l'échelle Retina) ne sont pas affectés par ce champ — seule la
    métadonnée de taille logique du fichier l'était.
  - ⚠️ **Limite découverte en corrigeant ça** : créer une VRAIE NSWindow
    ne fonctionne QUE dans un process avec une vraie boucle
    `NSApplication` qui tourne (l'app réelle, packagée) — bloque
    indéfiniment (`didFinish` jamais appelé) dans un simple exécutable
    CLI sans ça, ce qui inclut `AgenceTemplate3DSelfTest` : l'affirmation
    d'origine ("WKWebView fonctionne bien dans un exécutable CLI SANS
    NSApplication") ne tenait que pour une page SANS vidéo/animation à
    charger. `capture(..., useHostWindow: false)` (nouveau paramètre) le
    contourne pour le test local (page HTML statique, dégradé, aucune
    vidéo) — le comportement complet (AVEC fenêtre hôte, sur une vraie
    page) se vérifie dans l'app réelle via `AGENCE_SELFTEST=capture`
    `AGENCE_SELFTEST_CAPTURE_URL=<url>` (voir SelfTestRunner.swift),
    PASS/FAIL + PNG écrit dans `<tmp>/agence_selftest_capture.png`.
  - **Capture animée en séquence d'images — `captureFrameSequence`
    (2026-09-08, PAS ENCORE BRANCHÉE dans le flux de capture réel de
    l'app)** : `capture()` (image fixe, correctif ci-dessus) garantit que
    tout le contenu est dans son état FINAL révélé — mais une image fixe
    ne peut structurellement PAS montrer le MOUVEMENT d'une animation
    d'apparition (fade-in, slide-in...), juste son résultat. Signalé par
    l'utilisateur : "elle apparaissent avec l'animation finie mais pas
    avec l'apparition de l'animation" — "je veux essayer la vidéo".
    - **Vidéo (AVFoundation) essayée d'abord, ABANDONNÉE** : le mécanisme
      d'encodage (H.264/.mov, `AVAssetWriter`+`AVAssetWriterInputPixelBufferAdaptor`)
      fonctionnait, mais la vérification en conditions réelles (fenêtre
      hôte + vraie boucle `NSApplication`, seul contexte où une transition
      CSS se PEINT réellement — constaté en CLI : le DOM disait bien
      `opacity:1` mais le pixel restait figé à l'état d'avant, faute de
      compositeur actif pour une WKWebView hors fenêtre) s'est heurtée à
      un blocage de LANCEMENT de l'app dans cet environnement d'outillage
      (`open --env` → `RBSRequestErrorDomain`/`launchd job spawn failed`,
      cause non élucidée). Pas une preuve que la vidéo ne marcherait pas
      dans l'app réelle packagée normalement — juste un obstacle abandonné
      faute de temps, l'utilisateur a préféré repartir sur une séquence
      d'images (plus simple, aucune dépendance d'encodage).
    - **Séquence d'images retenue** : `WebCapture.captureFrameSequence`
      scrolle la page en TEMPS RÉEL (comme `captureStitched`, mais sans
      jamais s'arrêter pour un unique snapshot pleine page) — un
      screenshot du VIEWPORT toutes les `1/videoFps` secondes (8fps),
      écrit `frame_0001.png`, `frame_0002.png`, ... dans un dossier.
      Vitesse de scroll = `viewportHeight / SECONDS_PER_VIEWPORT_HEIGHT`
      (même repère que le scroll par défaut côté `headless.py`, 4s par
      hauteur d'écran) — garde un rythme cohérent avec le rendu final,
      pas une vitesse arbitraire nouvelle. Retourne le nombre de frames
      écrites.
    - **Côté Blender (`headless.py`)** : `sync_texture_node(node, path,
      target_height_px, expected_width_px)` — fonction MODULE-LEVEL qui
      auto-détecte image fixe (fichier) vs séquence animée (dossier) via
      `os.path.isdir` (pas de nouvelle clé JSON : Swift décide juste en
      écrivant un fichier ou un dossier). `replace_image_sequence_on_node`
      charge `frame_0001.png` avec `Image.source = 'SEQUENCE'` +
      `image_user.frame_duration` (compté via `glob`, Blender ne scanne
      pas le dossier lui-même). `reset_mapping_identity` remet le Mapping
      node à l'identité (Scale=1, Location=0) : une séquence n'a PAS
      besoin du recadrage/scroll simulé par ce noeud, chaque frame étant
      déjà cadrée au viewport. `apply_sequence_frame(node, fraction,
      frame_count, current_blender_frame)` choisit la bonne frame — MÊME
      FORMULE que le pilotage vidéo abandonné, validée par rendu direct
      contre une vraie vidéo test (dégradé rouge→bleu connu, fractions
      0.0/0.5/1.0 → rouge/violet/bleu conformes) puis réutilisée telle
      quelle pour une séquence (`ImageUser.frame_current` documente
      explicitement gérer "image sequence or movie" de la même façon) :
      `image_user.frame_start = current_blender_frame` (annule le terme
      "scene_frame - frame_start + 1" à 1), `image_user.frame_offset =
      target_frame - 1`. Réappliqué à CHAQUE frame (dépend de la frame
      Blender courante).
      `scroll_frames_for_page` (pacing par défaut, sans plan assigné à
      une section) : pour une séquence, sa DURÉE RÉELLE de capture
      (`frame_count / SEQUENCE_CAPTURE_FPS`, 8fps, miroir de
      `WebCapture.videoFps`) est directement convertie en frames Blender
      — plus de calcul par hauteur de page (qui n'a plus de sens : le
      noeud ne porte plus qu'UNE frame à la taille du viewport, pas la
      page entière). Le pacing par plan assigné à une section
      (`camera_section_fraction`) est INCHANGÉ (indépendant de la hauteur
      de page de toute façon).
      Vérifié par exécution directe contre le vrai template "tablette" :
      page mixte (axe desktop = séquence 69 frames, axe mobile = image
      fixe) sur la vraie plage native de "Plan 6 - Desktop" (marqueurs
      réels 480-570) — `image.source` bien `SEQUENCE`, `frame_offset`
      croissant avec le temps (0→15→30), aucune exception, l'axe mobile
      statique reste inchangé en parallèle (cas mixte fonctionnel).
    - **Self-test dédié** (`AgenceTemplate3DSelfTest`, étape "9b") :
      capture une page dégradé rouge→bleu de 900px (viewport 300px, donc
      scroll nécessaire), vérifie ≥3 frames écrites, dimensions de frame
      = viewport (PAS la page entière, contrairement à `capture()`), et
      que la couleur centrale de la DERNIÈRE frame est bien plus bleue
      que la PREMIÈRE (preuve d'un vrai scroll entre les frames, pas la
      même image répétée). `useHostWindow: false` ici aussi — mêmes
      limites que `capture()` pour cet outil CLI (voir juste au-dessus) :
      valide la MÉCANIQUE de la séquence, pas le rendu d'une vraie
      transition CSS (a besoin d'une fenêtre hôte réelle, donc de l'app
      empaquetée).
    - **BRANCHÉE PARTOUT par défaut (2026-09-08, décision explicite de
      l'utilisateur — pas un réglage optionnel)** : `AppState.capturePage`
      appelle désormais `captureFrameSequence` (plus `capture`).
      `Project.pageDesktopPath`/`pageMobilePath` renvoient maintenant un
      DOSSIER (plus un `.png`) — `pageHasCaptures` vérifie la présence de
      `frame_0001.png` DEDANS (`Project.firstFramePath`). Conséquence
      assumée : les anciennes captures `.png` des projets déjà en cours
      ne sont plus reconnues (`pageHasCaptures` renvoie `false` dessus) —
      il faut recapturer via le bouton "Capturer la page" existant, qui
      fonctionne tel quel (juste plus lent : scroll réel, ~10-60s par
      page selon sa longueur, contre quelques secondes avant ; et plus
      lourd sur disque, des dizaines de PNG par page au lieu d'un seul).
      `RenderConfigBuilder` inchangé : `desktop_path`/`mobile_path` sont
      juste maintenant des chemins de dossier plutôt que de fichier,
      `headless.py:sync_texture_node` gère la différence tout seul.
    - **Barre de progression de capture (2026-09-08)** : demande explicite
      juste après le branchement ci-dessus — la capture prend maintenant
      le temps d'un vrai scroll (~10-60s), un simple spinner indéterminé
      ne suffit plus. `captureFrameSequence` prend un `onProgress:
      ((Double) -> Void)?` optionnel, rappelé avec la fraction de scroll
      complétée (0.0→1.0 — PAS un compte de frames, inconnu à l'avance
      tant que la vraie hauteur de page n'est pas chargée) après chaque
      frame écrite. Comme `WebCapture` est `@MainActor`, ce callback
      arrive déjà sur le MainActor — pas besoin du `Task { @MainActor in
      … }` qu'utilise `RenderProcess.onProgress` (lui vient d'un process
      externe, hors MainActor).
      `AppState.capturingPageProgress: [Int: Double]` (uid de page →
      fraction 0…1 de la capture ENTIÈRE) combine les 2 appels séquentiels
      (desktop = 1ère moitié [0, 0.5], mobile = 2ème [0.5, 1.0]) — même
      garde-fou "réponse en retard" que le reste de `capturePage`
      (`self.project?.blendPath == blendPath`) à chaque mise à jour, pas
      seulement à la toute fin. `ProjectView.captureButton` affiche
      désormais une `ProgressView(value:)` DÉTERMINÉE (barre linéaire) +
      le pourcentage en texte à droite, plutôt que le spinner indéterminé
      d'avant.
    - **2 bugs réels corrigés le 2026-09-08, trouvés sur le premier vrai
      rendu de l'utilisateur** ("la video est a l'envers et c'est super
      saccadé") :
      1. **Vidéo à l'envers** : `reset_mapping_identity` forçait Scale.Y
         du Mapping node à `+1.0` — ignorant que CE TEMPLATE ("tablette")
         a un Scale.Y par défaut NÉGATIF sur le noeud desktop (`-0.229`,
         orientation du maillage de l'écran — le noeud MOBILE, lui, a un
         Scale.Y par défaut POSITIF : pas de convention universelle,
         chaque template/axe peut différer). Fix en 2 temps :
         - Préserver le SIGNE (même logique que
           `update_mapping_scale_for_full_page` :
           `sign = -1.0 if current_y < 0 else 1.0`).
         - Puis DEUXIÈME bug révélé par le premier fix : Location.Y à 0
           SANS CONDITION donnait un écran NOIR pour un Scale.Y négatif
           (`V' = -V` sort de `[0,1]` pour tout `V>0` → hors image). Il
           faut une Location.Y qui compense (`V' = 1-V` pour un Scale=-1)
           — exactement ce que `apply_scroll_position` calcule DÉJÀ pour
           n'importe quel signe. `reset_mapping_identity` appelle
           maintenant `apply_scroll_position(image_node, 0.0)` au lieu de
           réinventer ce calcul.
         Vérifié par un VRAI rendu (`cmd_render` complet, pas un test
         isolé) contre le vrai projet client en cause ("Test capture",
         page "Home", plans "Plan 2/3 - Desktop") — écran noir avant le
         2ème fix, contenu net et à l'endroit après, à la frame EXACTE où
         l'utilisateur avait vu le problème.
      2. **"Super saccadé"** : `SEQUENCE_CAPTURE_FPS`/`WebCapture.videoFps`
         à 8fps alors que ce template rend à 24fps — chaque frame capturée
         restait donc affichée ~3 frames de rendu d'affilée (24/8), un
         scroll par à-coups bien visible. Remonté à 24fps (les 2
         constantes DOIVENT rester synchronisées, comme
         `DESKTOP_WIDTH`/`MOBILE_WIDTH`) : une frame capturée par frame de
         rendu, plus de palier. Coût : ~3x plus d'appels `takeSnapshot`
         pendant la capture (déjà en temps réel) et ~3x plus de fichiers
         PNG par page — pas encore mesuré précisément sur un vrai site,
         à surveiller si une page très longue devient trop lente/lourde à
         capturer.
    - **3ème bug (2026-09-08, trouvé DANS le fix précédent) : "la vidéo
      est en accéléré"** — en faisant passer `SEQUENCE_CAPTURE_FPS`/
      `videoFps` de 8 à 24 (fix des saccades ci-dessus), les séquences
      DÉJÀ capturées à l'ancien rythme (8fps) se sont retrouvées
      réinterprétées comme si elles duraient 3x moins longtemps —
      `scroll_frames_for_page` ne connaissait qu'UNE constante globale
      pour convertir `frame_count` en durée réelle, jamais le fps
      RÉELLEMENT utilisé pour CETTE capture précise. Symptôme : le
      scroll se précipitait à travers toute la séquence puis restait figé
      (fraction bloquée à 1.0) pour le reste du plan — pas juste "plus
      rapide" uniformément, mais "rapide puis gelé".
      Fix structurel (pas juste un ajustement de constante, pour ne plus
      JAMAIS revivre ce bug si la constante rechange un jour) :
      `captureFrameSequence` écrit désormais un sidecar
      `sequence_meta.json` (`{"fps": <valeur au moment de LA capture>}`)
      à côté des frames. `headless.py:sequence_capture_fps(sequence_dir)`
      le lit en PRIORITÉ (repli sur `SEQUENCE_CAPTURE_FPS` seulement si
      absent/corrompu — anciennes captures d'avant ce fix).
      Les captures déjà sur disque À CE MOMENT (`Test capture`, page
      Home) n'avaient pas ce fichier — corrigé manuellement en écrivant
      `{"fps": 8}` dedans (seule capture existante, connue avec
      certitude avoir été faite avec l'ancien code) plutôt que de forcer
      l'utilisateur à recapturer ; toute capture FUTURE porte
      automatiquement son propre fps, plus besoin d'y repenser.
      Vérifié par un VRAI rendu avant/après (même projet/page/plans que
      les 2 bugs précédents) : avant le sidecar, le scroll atteignait le
      bas de page en ~la moitié de la vidéo puis restait figé ; après,
      défilement continu jusqu'à la toute fin.
      Logique testée en isolation (Python pur, sans Blender) : sans
      sidecar → repli constante ; sidecar `{"fps": 8}` → 8.0 lu
      correctement ; sidecar corrompu → repli silencieux sur la
      constante (jamais d'exception qui casserait tout le rendu).
- ~~Dépendances Playwright~~ **DOCUMENTÉ** (2026-09-02) : côté Swift,
  `WebCapture` (`WKWebView` natif) n'a jamais eu besoin de Playwright/
  Chromium — rien à installer, aucune dépendance externe, ni ici ni dans
  `Package.swift`. Ça ne concerne QUE ce portage : `app/core/deps.py`
  (Python) reste nécessaire et inchangé côté app Python, qui n'a pas
  Playwright en moins tant qu'elle existe en parallèle de ce portage.
- ~~Empaquetage en vrai `.app` signé~~ **FAIT** (2026-09-02) :
  `swift-app/packaging/build_app.sh` — même contournement iCloud que le
  script Python équivalent (compile + assemble + signe HORS de ce dossier
  projet, dans `~/Library/Caches/AgenceTemplate3D-Swift/`, copie signée
  vers `swift-app/dist/` seulement à la fin). Signature ad-hoc (pas de
  compte développeur Apple), même avertissement Gatekeeper "clic droit →
  Ouvrir" au premier lancement que côté Python.
  **Changement de fond nécessaire AVANT le packaging** : `BlenderBridge.
  headlessScriptPath()`/`TemplateCatalog.templatesRoot()` remontaient
  jusque-là vers `blender_side/`/`templates/` en résolvant `#filePath`
  (l'arbre SOURCE) — marchait par accident en dev, aurait cassé pour un
  vrai utilisateur sans l'arbre source sur son Mac. Ajouté un repli
  "bundled" via `Bundle.main.resourceURL`, cherché EN PREMIER (portage du
  `sys._MEIPASS`/`frozen` côté Python), avec repli sur l'ancien chemin
  source si absent (mode dev, `swift run`/`dev_run.sh`). Le script copie
  `blender_side/headless.py` et tout `templates/` dans
  `Contents/Resources/`. Vérifié : structure du bundle inspectée (fichiers
  bien présents), `codesign --verify --deep --strict` passe,
  `swift run AgenceTemplate3DSelfTest` toujours 62/62 après le changement
  (résolution dev non cassée), app packagée lancée et tourne sans crash.
  **Vérifié depuis (2026-09-02)** avec un vrai appel Blender DEPUIS le
  `.app` empaqueté lui-même — voir `SelfTestRunner.swift` juste en dessous.
  **Icône remplacée (2026-09-08)** : `packaging/assets/icon.icns` régénéré
  depuis un SVG fourni par l'utilisateur (`packaging/assets/icon.svg`,
  gardé à côté pour pouvoir la refaire) — 4 carrés noirs en croix sur fond
  blanc. Conversion SVG→iconset via `qlmanage -t -s 1024` (rendu, seul
  outil dispo sur cette machine — ni `rsvg-convert` ni ImageMagick
  installés) puis `sips -z` pour chaque taille requise
  (16/32/128/256/512, x1 et x2) et `iconutil -c icns`. `dev_run.sh` copie
  aussi ce fichier et déclare `CFBundleIconFile` désormais (avant : pas
  d'icône du tout en dev, seul le build signé `packaging/build_app.sh`
  en avait une) — pour voir la vraie icône dès les tests locaux.
- ~~Renommage auto dossier/.blend d'après le nom du site~~ **FAIT**
  (2026-09-02, trouvé en balayant `main_window.py` plus large — n'était
  dans aucune liste jusqu'ici) : portage de
  `_rename_project_to_site_name`/`_on_site_changed`. Important : `Project.
  outputName()` dérive le nom des rendus du nom du FICHIER .blend — sans
  ça, tous les rendus restaient nommés `"Preset 1_<site>_…"` quel que soit
  le nom du dossier. `ProjectService.renameProjectToSiteName(_:)` (Core,
  `RenameOutcome` — 5 cas, ne lève jamais, comme côté Python qui ne fait
  que des messages de statut) : renomme le dossier ET le `.blend` ET son
  `.agence_project.json`, gère la collision (dossier cible déjà pris →
  `.blocked`) et l'échec partiel (dossier renommé mais pas le fichier →
  `.renamedWithWarning`, pas une erreur bloquante). `AppState.
  siteNameChanged(_:)` programme l'exécution 1200ms après la dernière
  frappe (`DispatchWorkItem`, même délai que le `QTimer` Python) ;
  `closeProject()` (bouton "Menu") flushe immédiatement un renommage en
  attente avant de fermer — équivalent du `closeEvent` Python qui ne
  laisse jamais un renommage tapé juste avant de quitter. Vérifié par 9
  nouvelles étapes du self-test avec de VRAIES opérations disque (73/73
  au total) : renommage réussi, re-renommage inutile évité une fois à
  jour, collision bloquée.
- Fonctionnalités avancées du côté Python pas encore portées : thème
  clair/sombre.
- ~~Panneau de debug d'espacement~~ **FAIT PUIS RETIRÉ** (ajouté le
  2026-09-02, retiré le 2026-09-03 sur demande explicite — "retire les
  boutons de panneau de contrôle", chantier considéré clos) : les
  espacements de `TemplatePickerView`/`ProjectView` trouvés à la main via
  ces panneaux (curseurs, fenêtres séparées `Window(...)`) sont restés
  figés en constantes dans `TemplatePickerSpacing.swift`/
  `ProjectViewSpacing.swift` — plus de bouton règle 🔧 ni de fenêtre
  séparée dans l'app, `SpacingDebugPanel.swift`/`SpacingRegistry.swift`
  supprimés.
- ~~Thème clair/sombre~~ **FAIT** (2026-09-03, demandé explicitement) :
  `ThemePreference` (`@Observable`, persisté dans UserDefaults, clé
  "theme_mode" — même clé/défaut "dark" que QSettings côté Python) +
  interrupteur soleil/lune à droite de "Aperçu du rendu" dans
  `RenderPreviewPanel` (même emplacement que
  `preview_panel.py:ToggleSwitch`). Indépendant de l'apparence système
  macOS, comme côté Python. N'est visible que dans `ProjectView` (pas
  encore sur l'écran d'accueil) — même limite de portée que la version
  Python d'origine.
- ~~Vérifier un vrai appel Blender depuis le `.app` empaqueté~~ **FAIT**
  (2026-09-02) : `SelfTestRunner.swift` (nouveau, cible `AgenceTemplate3D`)
  — même principe que `AGENCE_SELFTEST=video` côté Python (`app/main.py`) :
  variable d'environnement `AGENCE_SELFTEST=blender` posée au lancement →
  l'app saute son UI, liste les templates, vérifie que `headless.py` est
  résolu, fait un VRAI appel Blender (`list_shots` sur "tablette"),
  imprime PASS/FAIL sur stdout, quitte. Appelé depuis `App.swift:init()`
  avant toute Scene. **Test rigoureux effectué** : `blender_side/` et
  `templates/` (arbre source) renommés temporairement pour de vrai, `.app`
  empaqueté lancé directement (`AGENCE_SELFTEST=blender
  ".../DigitalMockup.app/Contents/MacOS/AgenceTemplate3D"`) SANS l'arbre
  source disponible → résolution correcte vers `Contents/Resources/`
  (templates_root et headless_script pointent bien dedans), 5 templates
  trouvés, VRAI appel Blender réussi (9 plans), PASS, code de sortie 0.
  Arbre source restauré immédiatement après. Preuve directe que le repli
  "bundled" n'est pas une coïncidence de dev — ça marche vraiment sans
  l'arbre source du projet.
