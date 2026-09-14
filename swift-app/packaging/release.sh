#!/bin/zsh
# Publie une nouvelle version de DigitalMockup, avec mise à jour
# automatique (Sparkle, 2026-09-14 — demande explicite : "sans qu'ils
# aient besoin de la réinstaller") :
#   ./packaging/release.sh 1.0.1
#
# Fait, dans l'ordre : build release signé (build_app.sh) → signature
# EdDSA du zip (sign_update, via la clé exportée en fichier — voir
# packaging/sparkle_private_key.pem, JAMAIS committée, voir .gitignore) →
# ajout d'une entrée dans appcast.xml (racine du repo) → commit + push de
# l'appcast et du compteur de build → publication d'une Release GitHub
# avec le zip en pièce jointe, à l'URL que l'appcast référence.
#
# Après ça, toute app DigitalMockup déjà installée (qui vérifie
# périodiquement cet appcast, voir SUFeedURL) détecte la nouvelle version
# et propose de l'installer — sans repasser par un zip envoyé à la main.
set -e
cd "$(dirname "$0")/.."  # swift-app/
REPO_ROOT="$(pwd)/.."
REPO_SLUG="gyarado04/digitalmockup"

VERSION="$1"
if [ -z "$VERSION" ]; then
  echo "Usage : ./packaging/release.sh <version, ex: 1.0.1>"
  exit 1
fi

BUILD_NUMBER_FILE="packaging/BUILD_NUMBER"
BUILD_NUMBER=$(( $(cat "$BUILD_NUMBER_FILE" 2>/dev/null || echo 0) + 1 ))

KEY_FILE="packaging/sparkle_private_key.pem"
if [ ! -f "$KEY_FILE" ]; then
  echo "✗ Clé privée Sparkle introuvable : $KEY_FILE"
  echo "  Voir README.md \"Mises à jour automatiques\" pour la générer."
  exit 1
fi

echo "→ Build $VERSION (build $BUILD_NUMBER)…"
./packaging/build_app.sh "$VERSION" "$BUILD_NUMBER"

ZIP_PATH="dist/DigitalMockup.zip"
SIGN_TOOL=".build/artifacts/sparkle/Sparkle/bin/sign_update"

echo "→ Signature EdDSA…"
SIGN_OUTPUT=$("$SIGN_TOOL" --ed-key-file "$KEY_FILE" "$ZIP_PATH")
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | sed -E 's/.*edSignature="([^"]*)".*/\1/')
LENGTH=$(echo "$SIGN_OUTPUT" | sed -E 's/.*length="([^"]*)".*/\1/')
if [ -z "$ED_SIGNATURE" ] || [ -z "$LENGTH" ]; then
  echo "✗ Signature échouée ou format inattendu : $SIGN_OUTPUT"
  exit 1
fi
echo "  $SIGN_OUTPUT"

echo "→ Mise à jour de l'appcast…"
APPCAST_PATH="$REPO_ROOT/appcast.xml"
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="https://github.com/$REPO_SLUG/releases/download/v$VERSION/DigitalMockup.zip"

python3 - "$APPCAST_PATH" "$VERSION" "$BUILD_NUMBER" "$PUB_DATE" "$DOWNLOAD_URL" "$ED_SIGNATURE" "$LENGTH" << 'PY'
import sys

path, version, build, pub_date, url, signature, length = sys.argv[1:8]

item = f"""        <item>
            <title>Version {version}</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="{url}"
                       sparkle:edSignature="{signature}"
                       length="{length}"
                       type="application/octet-stream" />
        </item>
"""

with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# Le plus récent <item> en tête de liste (convention Sparkle courante,
# même si Sparkle trie de toute façon par version — plus lisible pour un
# humain qui ouvrirait ce fichier). Inséré juste après </channel>'s
# ouverture réelle, ici juste après la balise <language> qui est
# toujours la dernière ligne fixe du header.
marker = "<language>fr</language>"
idx = content.index(marker) + len(marker)
content = content[:idx] + "\n" + item.rstrip("\n") + content[idx:]

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PY

echo "→ Compteur de build + commit…"
echo "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"
cd "$REPO_ROOT"
git add appcast.xml swift-app/packaging/BUILD_NUMBER
git commit -m "Release v$VERSION (build $BUILD_NUMBER)

🤖 Generated with Claude Code
Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
git push

echo "→ Publication de la Release GitHub…"
gh release create "v$VERSION" "swift-app/$ZIP_PATH" \
  --repo "$REPO_SLUG" \
  --title "Version $VERSION" \
  --notes "Voir swift-app/README.md pour le détail des changements."

echo ""
echo "✓ v$VERSION publiée — https://github.com/$REPO_SLUG/releases/tag/v$VERSION"
echo "  Les apps déjà installées la détecteront à leur prochaine vérification"
echo "  (auto, ou immédiat via le menu \"Rechercher les mises à jour…\")."
