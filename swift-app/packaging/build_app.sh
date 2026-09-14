#!/bin/zsh
# Construit "DigitalMockup.app" (version Swift) — à lancer depuis swift-app/ :
#   ./packaging/build_app.sh
#
# Compile et assemble HORS de ce dossier de projet, volontairement : ce
# dossier est synchronisé par iCloud Drive, et sur cette machine iCloud
# retague en continu les dossiers .app avec le xattr com.apple.FinderInfo
# (bit "bundle" de Finder) — codesign --deep échoue dessus de façon
# intermittente ("resource fork, Finder information, or similar detritus
# not allowed"), même après xattr -cr, parce qu'iCloud repose le tag
# presque aussitôt. Même contournement que côté Python
# (packaging/build_app.sh à la racine, voir son README) : construire et
# signer entièrement hors d'iCloud, ne copier vers dist/ qu'à la toute fin
# (un .app déjà signé survit à cette copie — seul le RE-signer sur place
# échoue).
# VERSION / BUILD_NUMBER — 2 arguments optionnels (ex.
# `./build_app.sh 1.2.0 5`). `CFBundleVersion` (build number, entier
# croissant) DOIT augmenter à chaque release publiée — c'est lui que
# Sparkle compare en premier pour savoir si une mise à jour existe (voir
# README "Mises à jour automatiques"). Ce script sert aussi à un simple
# build de test local (pas de release) : défauts sensés dans ce cas
# (version "0.0.0", build = timestamp Unix — toujours croissant, jamais
# en conflit avec une VRAIE release). `packaging/release.sh` (le script
# qui publie une vraie version) appelle celui-ci avec les 2 vrais
# arguments plutôt que de dupliquer toute la logique de build.
set -e
cd "$(dirname "$0")/.."  # swift-app/

APP_NAME="DigitalMockup"
BUNDLE_ID="fr.digitalcover.agencetemplate3d.swift"
BUILD_ROOT="$HOME/Library/Caches/AgenceTemplate3D-Swift/build"
PROJECT_ROOT="$(pwd)/.."

VERSION="${1:-0.0.0}"
BUILD_NUMBER="${2:-$(date +%s)}"
echo "Version : $VERSION (build $BUILD_NUMBER)"

mkdir -p "$BUILD_ROOT"

echo "Compilation (release)…"
swift build -c release

APP_DIR="$BUILD_ROOT/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp .build/release/AgenceTemplate3D "$APP_DIR/Contents/MacOS/AgenceTemplate3D"

# Bundle de ressources SwiftPM (police Monument Grotesk, voir Package.swift
# resources:) — Bundle.module (Theme.swift:registerBundledFonts) le cherche
# dans Contents/Resources/, même principe que blender_side/templates.
cp -R .build/release/AgenceTemplate3D_AgenceTemplate3D.bundle "$APP_DIR/Contents/Resources/"

# Sparkle.framework (mises à jour auto, 2026-09-14) — l'exécutable le lie
# en `@rpath/Sparkle.framework/...`, et `@loader_path` (déjà présent parmi
# ses rpaths, posé par SwiftPM, vérifié via `otool -l`) résout au dossier
# CONTENANT l'exécutable, donc Contents/MacOS/ ici — pas
# Contents/Frameworks/ (convention Xcode habituelle, inutile ici : aucun
# rpath ne pointe dessus). Sans lui, l'app ne lance même pas (dylib
# manquant au chargement, pas une erreur Sparkle).
cp -R .build/release/Sparkle.framework "$APP_DIR/Contents/MacOS/"

# Ressources nécessaires à l'exécution — voir BlenderBridge.headlessScriptPath()
# et TemplateCatalog.templatesRoot() (Core) : un .app empaqueté les cherche
# ICI en premier (Bundle.main), avant tout repli sur l'arbre source.
mkdir -p "$APP_DIR/Contents/Resources/blender_side"
cp "$PROJECT_ROOT/blender_side/headless.py" "$APP_DIR/Contents/Resources/blender_side/"
rm -rf "$APP_DIR/Contents/Resources/templates"
cp -R "$PROJECT_ROOT/templates" "$APP_DIR/Contents/Resources/templates"

if [ -f "$PROJECT_ROOT/packaging/assets/icon.icns" ]; then
  cp "$PROJECT_ROOT/packaging/assets/icon.icns" "$APP_DIR/Contents/Resources/icon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AgenceTemplate3D</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>icon.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>NSHumanReadableCopyright</key>
    <string>Digital Cover</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/gyarado04/digitalmockup/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>SuVy1WH7MgRGyvQMab9jGI/dbh1J/lHYGNxRLh7T/Fg=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
</dict>
</plist>
PLIST

echo "Signature ad-hoc…"
xattr -cr "$APP_DIR"
# --options runtime + entitlements.plist (2026-09-14) : nécessaires pour
# Sparkle (voir packaging/entitlements.plist et README "Mises à jour
# automatiques" pour le détail) — SANS ÊTRE SUFFISANTS en ad-hoc pur : la
# "Library Validation" du runtime durci continue de rejeter
# Sparkle.framework tant qu'il n'y a pas un VRAI certificat développeur
# Apple (Developer ID, payant) derrière la signature. Gardé quand même :
# c'est la configuration CORRECTE qu'il faudra de toute façon le jour où
# un vrai certificat est disponible — rien à changer ici à ce moment-là,
# juste `--sign -` à remplacer par l'identité du certificat.
codesign --force --deep --options runtime --entitlements packaging/entitlements.plist --sign - "$APP_DIR"

echo "Vérification…"
codesign --verify --deep --strict "$APP_DIR"

ZIP_PATH="$BUILD_ROOT/$APP_NAME.zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

DIST_DIR="$(pwd)/dist"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/$APP_NAME.app"
ditto "$APP_DIR" "$DIST_DIR/$APP_NAME.app"
cp "$ZIP_PATH" "$DIST_DIR/"

echo ""
echo "✓ App construite : $DIST_DIR/$APP_NAME.app (et .zip à côté)"
echo "  Glisse-la dans /Applications puis lance-la en double-clic."
echo "  Non signée par un compte développeur Apple (signature ad-hoc"
echo "  seulement) : au premier lancement, macOS peut bloquer — clic droit"
echo "  → Ouvrir, une seule fois."
