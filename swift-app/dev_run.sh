#!/bin/zsh
# Lance AgenceTemplate3D (SwiftUI) pour du test local, empaqueté dans un
# .app minimal — `swift run AgenceTemplate3D` seul NE MARCHE PAS pour tester
# à l'écran : sans identifiant de bundle (Info.plist), AppKit refuse de
# créer la fenêtre ("Cannot index window tabs due to missing main bundle
# identifier" / "No windows open yet" dans `log show`, confirmé le
# 2026-09-02, aucune fenêtre n'apparaît jamais, le process tourne pour
# rien). Ce script construit un .app jetable non signé juste pour le
# développement — PAS le packaging final (voir README "Empaquetage en vrai
# .app signé", qui restera un script séparé une fois signature/icône en
# place).
set -e
cd "$(dirname "$0")"

swift build

APP_DIR=".build/dev-app/DigitalMockup.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/debug/AgenceTemplate3D "$APP_DIR/Contents/MacOS/AgenceTemplate3D"

# Bundle de ressources SwiftPM (police Monument Grotesk, voir Package.swift
# resources:) — Bundle.module (Theme.swift:registerBundledFonts) le cherche
# dans Contents/Resources/, comme blender_side/templates.
rm -rf "$APP_DIR/Contents/Resources/AgenceTemplate3D_AgenceTemplate3D.bundle"
cp -R .build/debug/AgenceTemplate3D_AgenceTemplate3D.bundle "$APP_DIR/Contents/Resources/"

# Sparkle.framework (mises à jour auto, 2026-09-14) — l'exécutable le lie
# en `@rpath/Sparkle.framework/...`, et `@loader_path` (déjà présent parmi
# ses rpaths, posé par SwiftPM lui-même, vérifié via `otool -l`) résout au
# dossier CONTENANT l'exécutable, donc Contents/MacOS/ ici — PAS
# Contents/Frameworks/ (convention Xcode habituelle, mais inutile ici :
# aucun rpath ne pointe dessus, ça aurait juste ajouté une étape
# `install_name_tool -add_rpath` pour rien). Sans lui, l'app ne lance même
# pas (dylib manquant, échec au chargement, pas une erreur Sparkle).
rm -rf "$APP_DIR/Contents/MacOS/Sparkle.framework"
cp -R .build/debug/Sparkle.framework "$APP_DIR/Contents/MacOS/"

# Icône (2026-09-08) — même fichier que le build signé
# (packaging/build_app.sh) : la voir aussi en dev évite les surprises
# ("ça avait l'air bien mais elle n'apparaît que dans le vrai build").
if [ -f "../packaging/assets/icon.icns" ]; then
  cp "../packaging/assets/icon.icns" "$APP_DIR/Contents/Resources/icon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AgenceTemplate3D</string>
    <key>CFBundleIdentifier</key>
    <string>dev.local.agence-template-3d.dev</string>
    <key>CFBundleName</key>
    <string>DigitalMockup</string>
    <key>CFBundleIconFile</key>
    <string>icon.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.0-dev</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "✓ Lancement de $APP_DIR"
open "$APP_DIR"
