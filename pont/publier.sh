#!/bin/sh
# Publie la version déclarée dans nostrum.koplugin/main.lua.
#
#   ./publier.sh
#
# Construit et signe sur ce Mac — le certificat ne quitte jamais le trousseau —
# pousse les sources, puis crée la Release « vX.Y.Z » du dépôt public
# david-guia/nostrum avec le DMG sous le nom fixe Nostrum.dmg. D'où deux liens
# qui ne changent jamais :
#   - téléchargement client : https://github.com/david-guia/nostrum/releases/latest/download/Nostrum.dmg
#   - version officielle     : https://api.github.com/repos/david-guia/nostrum/releases/latest
# Les applications installées lisent la seconde à chaque démarrage (puis toutes
# les 6 h) et, si elles sont plus anciennes, proposent de télécharger le DMG.
# Une fois le Mac à jour, chaque Kindle propose à son tour la version du Mac.
#
# Pour une nouvelle version : changer `local VERSION`, committer, lancer ce
# script. Numérotation X.Y.Z : correction de bug → Z+1 (1.3.1), nouvelle
# fonctionnalité → Y+1 et Z à 0 (1.4.0), changement majeur → X+1 (2.0.0).

set -e
cd "$(dirname "$0")"
REPO=david-guia/nostrum

VERSION=$(sed -n 's/^local VERSION = "\(.*\)"/\1/p' ../nostrum.koplugin/main.lua)
[ -n "$VERSION" ] || { echo "VERSION introuvable dans main.lua"; exit 1; }

# Des sources non committées publieraient une version que le dépôt ne connaît pas.
if [ -n "$(git status --porcelain)" ]; then
    echo "Modifications non committees : committer avant de publier."
    exit 1
fi

if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "Nostrum $VERSION est deja publie. Changer VERSION dans main.lua pour publier."
    exit 1
fi

./build.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Nom fixe : c'est ce qui rend le lien « latest/download/Nostrum.dmg » stable.
cp -X "../dist/Nostrum-$VERSION.dmg" "$TMP/Nostrum.dmg"

git push -q origin HEAD
git tag -f "v$VERSION" >/dev/null
git push -q -f origin "v$VERSION"
gh release create "v$VERSION" "$TMP/Nostrum.dmg" --repo "$REPO" --latest \
    --title "Nostrum $VERSION" \
    --notes "Télécharger : https://github.com/$REPO/releases/latest/download/Nostrum.dmg"

echo
echo "Nostrum $VERSION publie. Les applications installees le proposeront a leur prochain demarrage."
echo "Lien client : https://github.com/$REPO/releases/latest/download/Nostrum.dmg"
