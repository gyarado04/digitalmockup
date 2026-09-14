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
set -e
cd "$(dirname "$0")/.."  # swift-app/

APP_NAME="DigitalMockup"
BUNDLE_ID="fr.digitalcover.agencetemplate3d.swift"
BUILD_ROOT="$HOME/Library/Caches/AgenceTemplate3D-Swift/build"
PROJECT_ROOT="$(pwd)/.."

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
    <string>0.1.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Digital Cover</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Signature ad-hoc…"
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"

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
