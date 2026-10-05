# NOSTRUM

*L'ordinateur de bord de votre journée.* Agenda, rappels Apple et météo sur un
Kindle jailbreaké (KOReader), servis par une application Mac.

```
nostrum.koplugin/   plugin KOReader (ce qui tourne sur le Kindle)
pont/               application Mac, script de construction, guide client
dist/               sortie de pont/build.sh — Nostrum-<version>.dmg
```

## Construire le DMG

```
cd pont && ./build.sh
```

Contrôles du plugin, application universelle (arm64 + x86_64, macOS 12+) signée
(voir ci-dessous), plugin embarqué dans `Nostrum.app/Contents/Resources/nostrum.koplugin`,
puis `dist/Nostrum-<version>.dmg` (application + raccourci Applications +
`Lisez-moi.html`, le guide du client) et `dist/Nostrum-<version>.zip` (mise à jour).

La version est celle de `local VERSION` en tête de `nostrum.koplugin/main.lua` :
un seul endroit, repris par le bandeau du Kindle, l'`Info.plist` et le nom du DMG.

**Sans compte Apple Developer** : l'application est signée avec le certificat
gratuit « Apple Development » mais n'est pas notarisée ; Gatekeeper bloque le
premier lancement. Le client passe par Réglages Système → Confidentialité et
sécurité → *Ouvrir quand même* (expliqué dans le guide). Le certificat donne une
identité stable : macOS garde l'accès aux Rappels d'une version à l'autre. Il
expire au bout d'un an : le renouveler sous le même nom, les mises à jour
restent acceptées. Sans certificat, `build.sh` signe en ad-hoc et la
mise à jour automatique est refusée.

## Fonctionnement

- **Mac** : l'app lit Rappels et Calendrier par EventKit et les sert sur le
  port 8843, protégés par un jeton tiré au premier lancement
  (`~/Library/Application Support/Nostrum/settings.json`, droits 600). Rangée
  dans Applications, elle s'inscrit au démarrage de session
  (`~/Library/LaunchAgents/me.davidguia.nostrum.plist`).
- **Installation sur le Kindle** : le bouton copie le plugin sur tout volume
  monté portant un dossier `koreader/` et écrit `config.lua` (jeton, adresses du
  Mac, ville géocodée par Open-Meteo). *Enregistrer dans un dossier…* fait de
  même pour les Kindle MTP qui ne montent pas comme un disque.
- **Kindle** : avec `bridge_token` et sans identifiants iCloud, agenda et
  tâches passent par le pont. Si aucune adresse ne répond, le Kindle balaie son
  /24 sur le port du pont (connexions TCP non bloquantes, 64 à la fois) et
  présente le jeton aux hôtes ouverts ; l'adresse trouvée est mémorisée. Au plus
  un balayage toutes les 5 minutes.
- **Mises à jour (OTA)** : changer `local VERSION` dans `main.lua` (format N.N),
  committer, puis `pont/publier.sh`. Le script construit et signe sur ce Mac
  (le certificat ne quitte jamais le trousseau) et pousse dans le dépôt public
  `david-guia/nostrum-releases` : `latest.json`, le zip, `Nostrum.dmg`. Il
  pousse aussi les sources et crée la Release du dépôt privé. Les apps
  installées vérifient ce flux à l'ouverture puis toutes les 6 h, contrôlent le
  sha256 **et** que la nouvelle version est signée par le même certificat,
  remplacent leur bundle (l'ancien part à la corbeille) et se relancent. Le
  Kindle installe ensuite le plugin embarqué à sa synchro suivante et propose
  de redémarrer KOReader.
- **Lien de téléchargement client** :
  https://github.com/david-guia/nostrum-releases/raw/main/Nostrum.dmg

Mode avancé : `username` / `password` (mot de passe d'application iCloud) dans
`config.lua` remettent l'agenda en CalDAV direct ; il reste alors lisible Mac
éteint. Voir `config.lua.sample`.

## Contrôles

```
cd nostrum.koplugin
lua test.lua        # ics, caldav, météo, pont : agenda, bascule d'adresses, recherche réseau
lua render.lua | python3 render.py DroidSansMono.ttf apercu.png   # écran + synchro par le pont
```

Routes du pont : en-tête de `pont/nostrum-pont.swift`.
