#!/bin/sh
# Publie la version déclarée dans nostrum.koplugin/main.lua.
#
#   ./publier.sh
#
# Construit et signe sur ce Mac — le certificat ne quitte jamais le trousseau —
# puis pousse dans le dépôt public david-guia/nostrum-releases ce que les
# clients téléchargent : Nostrum.dmg (lien fixe), le zip de mise à jour et
# latest.json. Les applications installées le lisent à l'ouverture puis
# toutes les 6 h et se mettent à jour seules ; chaque Kindle suit à sa synchro.
#
# Pour une nouvelle version : changer `local VERSION` (format N.N), committer,
# lancer ce script. Il pousse aussi les sources et crée la Release du dépôt privé.

set -e
cd "$(dirname "$0")"
SRC=david-guia/nostrum
REL=david-guia/nostrum-releases

VERSION=$(sed -n 's/^local VERSION = "\(.*\)"/\1/p' ../nostrum.koplugin/main.lua)
[ -n "$VERSION" ] || { echo "VERSION introuvable dans main.lua"; exit 1; }

# Des sources non committées publieraient une version que le dépôt ne connaît pas.
if [ -n "$(git status --porcelain)" ]; then
    echo "Modifications non committees : committer avant de publier."
    exit 1
fi

PUB=$(curl -fsSL "https://raw.githubusercontent.com/$REL/main/latest.json" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)
if [ "$PUB" = "$VERSION" ]; then
    echo "Nostrum $VERSION est deja publie. Changer VERSION dans main.lua pour publier."
    exit 1
fi

./build.sh

# Une version ad-hoc serait refusee par toutes les applications installees :
# elles n'acceptent qu'une mise a jour signee par le meme certificat.
if codesign -dv ../dist/Nostrum.app 2>&1 | grep -q 'Signature=adhoc'; then
    echo "Signature ad-hoc : aucune application installee n'accepterait cette version. Abandon."
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if ! gh repo view "$REL" >/dev/null 2>&1; then
    gh repo create "$REL" --public --add-readme \
        --description "Téléchargements de Nostrum — l'ordinateur de bord de votre journée"
fi
gh repo clone "$REL" "$TMP/rel" -- --depth 1 -q

cd "$TMP/rel"
# Une seule archive en ligne : la derniere.
git rm -q --ignore-unmatch 'Nostrum-*.zip'
cp -X "$OLDPWD/../dist/Nostrum-$VERSION.zip" .
# Nom fixe : le lien de telechargement donne aux clients ne change jamais.
cp -X "$OLDPWD/../dist/Nostrum-$VERSION.dmg" Nostrum.dmg
SUM=$(shasum -a 256 "Nostrum-$VERSION.zip" | cut -d' ' -f1)
printf '{"version":"%s","url":"https://raw.githubusercontent.com/%s/main/Nostrum-%s.zip","sha256":"%s"}\n' \
    "$VERSION" "$REL" "$VERSION" "$SUM" > latest.json
git add -A
git -c user.name="Nostrum" -c user.email="hello@davidguia.me" commit -q -m "Nostrum $VERSION"
git push -q origin HEAD
cd "$OLDPWD"

# Sources et Release du depot prive : la trace de ce qui a ete publie.
git push -q origin HEAD
git tag -f "v$VERSION" >/dev/null
git push -q -f origin "v$VERSION"
if gh release view "v$VERSION" --repo "$SRC" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "../dist/Nostrum-$VERSION.dmg" --repo "$SRC" --clobber
else
    gh release create "v$VERSION" "../dist/Nostrum-$VERSION.dmg" --repo "$SRC" \
        --title "Nostrum $VERSION" --notes "Publiée dans $REL."
fi

echo
echo "Nostrum $VERSION publie. Les applications installees se mettront a jour sous 6 h."
echo "Lien client : https://github.com/$REL/raw/main/Nostrum.dmg"
