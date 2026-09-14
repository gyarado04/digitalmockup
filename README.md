# DigitalMockup

Application macOS qui prend l'URL d'un site web, capture des pages
(desktop + mobile), et les injecte automatiquement dans une scène 3D
Blender pré-animée (une tablette/écran qui scrolle la page) pour produire
une vidéo de présentation client — sans jamais ouvrir Blender à la main.

Native SwiftUI, pilote Blender en arrière-plan (headless).

## Structure

```
swift-app/          Code source de l'app (SwiftUI + package Core)
blender_side/        Script Python exécuté PAR Blender en headless
templates/           Templates .blend (presets de scène 3D)
packaging/assets/    Icône de l'app
```

Voir [swift-app/README.md](swift-app/README.md) pour l'historique détaillé
du développement, les décisions techniques et les bugs résolus.

## Build

```bash
cd swift-app
swift build -c release
./packaging/build_app.sh
```

Produit `swift-app/dist/DigitalMockup.app`, signé ad-hoc (pas de compte
développeur Apple) — au premier lancement sur une autre machine, clic
droit → Ouvrir.

## Prérequis

- macOS 14+, Apple Silicon (arm64)
- [Blender](https://www.blender.org/download/) installé dans
  `/Applications/Blender.app` (5.x recommandé — voir la section
  "Compatibilité Blender 5.x" du README détaillé pour l'historique de
  compatibilité)
