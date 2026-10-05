#!/bin/sh
# Construit Nostrum.app (Apple Silicon + Intel) et le DMG à distribuer, dans
# ../dist/.
#
#   ./build.sh                     signe avec la première identité du trousseau
#   SIGN_ID="Apple Development: …" ./build.sh
#
# Signature : un certificat, même gratuit (Apple Development), donne à
# l'application une identité stable : macOS garde l'accès aux Rappels et au
# Calendrier quand le client remplace une version par la suivante. À défaut,
# signature ad-hoc : tout fonctionne, mais macOS redemande ces accès à chaque
# nouvelle version.
#
# Dans les deux cas l'application n'est pas notarisée : au premier lancement,
# macOS la bloque et le client passe par Réglages Système → Confidentialité et
# sécurité → « Ouvrir quand même » (expliqué dans « Lisez-moi.html »).

set -e
cd "$(dirname "$0")"

PLUGIN=../nostrum.koplugin
VERSION=$(sed -n 's/^local VERSION = "\(.*\)"/\1/p' "$PLUGIN/main.lua")
[ -n "$VERSION" ] || { echo "VERSION introuvable dans main.lua"; exit 1; }

DIST=../dist
# Construction hors de Documents : ce dossier pose sur chaque fichier des
# attributs proteges (provenance, macl) que xattr ne peut pas retirer, et que
# codesign refuse (« resource fork, Finder information, or similar detritus »).
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
APP="$BUILD/Nostrum.app"
STAGE="$BUILD/dmg"
DMG="$DIST/Nostrum-$VERSION.dmg"

echo "1/6  controles du plugin"
(cd "$PLUGIN" && lua test.lua >/dev/null && lua render.lua >/dev/null 2>&1) \
    || { echo "controles du plugin en echec : cd $PLUGIN && lua test.lua"; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST" "$APP/Contents/MacOS" "$APP/Contents/Resources/nostrum.koplugin"

echo "2/6  compilation arm64 + x86_64"
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos12.0" -o "$BUILD/nostrum-$arch" nostrum-pont.swift
done
lipo -create "$BUILD/nostrum-arm64" "$BUILD/nostrum-x86_64" -output "$APP/Contents/MacOS/Nostrum"

echo "3/6  icone"
# Versionnee : la construction ne depend pas de Pillow, seulement a la creation.
# Supprimer nostrum.icns pour la regenerer depuis make-icon.py.
if [ ! -f nostrum.icns ]; then
    python3 make-icon.py "$BUILD/nostrum.iconset" >/dev/null
    iconutil -c icns "$BUILD/nostrum.iconset" -o nostrum.icns
fi
cp -X nostrum.icns "$APP/Contents/Resources/nostrum.icns"

echo "4/6  plugin Kindle embarque"
# Seulement ce qui tourne sur l'appareil : ni tests, ni apercu, ni config.lua.
for f in _meta.lua main.lua nostrum_bridge.lua nostrum_caldav.lua nostrum_ics.lua nostrum_net.lua nostrum_weather.lua; do
    cp -X "$PLUGIN/$f" "$APP/Contents/Resources/nostrum.koplugin/"
done

cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nostrum</string>
  <key>CFBundleDisplayName</key><string>Nostrum</string>
  <key>CFBundleIdentifier</key><string>me.davidguia.nostrum</string>
  <key>CFBundleExecutable</key><string>Nostrum</string>
  <key>CFBundleIconFile</key><string>nostrum</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Sans la cle correspondante, macOS refuse la demande d'acces sans rien
       afficher : ni invite, ni ligne dans Reglages > Confidentialite. Les
       variantes « FullAccess » sont celles de macOS 14 et suivants. -->
  <key>NSRemindersUsageDescription</key>
  <string>Nostrum lit vos rappels pour les afficher sur le Kindle et les cocher depuis lui.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Nostrum lit vos rappels pour les afficher sur le Kindle et les cocher depuis lui.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Nostrum lit votre agenda pour l'afficher sur le Kindle.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Nostrum lit votre agenda pour l'afficher sur le Kindle.</string>
</dict>
</plist>
PLISTEOF

echo "5/6  signature"
# Obligatoire sur Apple Silicon (un binaire non signe ne s'execute pas), et
# scelle l'Info.plist.
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1 && /\)/ {print $2}')}
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="-"
    echo "     ad-hoc : aucune identite de signature. Acces Rappels redemandes a chaque version."
fi
codesign --force --deep --sign "$SIGN_ID" --identifier me.davidguia.nostrum "$APP"
codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=/     signe : /p' | head -1
codesign --verify --strict "$APP"

echo "6/6  DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp -X Lisez-moi.html "$STAGE/Lisez-moi.html"
hdiutil create -quiet -volname "Nostrum $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
# L'application seule aussi, pour l'essayer sans monter le DMG.
ditto "$APP" "$DIST/Nostrum.app"

echo
echo "Pret : $DMG"
