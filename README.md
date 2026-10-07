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
`Lisez-moi.html`, le guide du client).

La version est celle de `local VERSION` en tête de `nostrum.koplugin/main.lua` :
un seul endroit, repris par le bandeau du Kindle, l'`Info.plist` et le nom du DMG.
Numérotation X.Y.Z : correction de bug → `1.3.1`, nouvelle fonctionnalité →
`1.4.0`, changement majeur → `2.0.0`.

**Sans compte Apple Developer** : l'application est signée avec le certificat
gratuit « Apple Development » mais n'est pas notarisée ; Gatekeeper bloque le
premier lancement. Le client passe par Réglages Système → Confidentialité et
sécurité → *Ouvrir quand même* (expliqué dans le guide). Le certificat donne une
identité stable : macOS garde l'accès aux Rappels quand le client remplace une
version par la suivante. Il expire au bout d'un an : le renouveler sous le même
nom. Sans certificat, `build.sh` signe en ad-hoc et macOS redemande ces accès à
chaque version.

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
- **Mises à jour** : rien ne s'installe seul. Pour publier : changer
  `local VERSION` dans `main.lua`, committer, puis
  `pont/publier.sh`, qui construit et signe sur ce Mac et pousse dans le dépôt
  public `david-guia/nostrum-releases` le DMG et `latest.json` (la version
  officielle). L'app Mac lit ce fichier à l'ouverture puis toutes les 6 h ; si
  elle est plus ancienne, elle propose de télécharger le DMG (alerte, puis
  bouton en bas de la fenêtre). Le Kindle compare sa version à celle du Mac à
  chaque synchro et, si elles diffèrent, propose d'installer celle du Mac
  (une fois par version et par session) puis de redémarrer KOReader.
- **Lien de téléchargement client** :
  https://github.com/david-guia/nostrum-releases/raw/main/Nostrum.dmg

**Secours iCloud (facultatif)** : dans l'app Mac, section *Agenda sans le Mac*,
identifiant Apple + mot de passe d'application. L'app les vérifie auprès
d'iCloud (`PROPFIND`, même requête que la Kindle), garde le mot de passe dans le
trousseau et l'écrit dans `config.lua` à l'installation (`username` /
`password`). La Kindle interroge toujours le pont d'abord ; s'il est hors
d'atteinte (une seule tentative par synchro), elle lit l'agenda sur iCloud en
CalDAV, garde les tâches déjà affichées et affiche `MAC ÉTEINT`, source
`ICLOUD`. Le menu garde la liste des calendriers apprise du Mac.

## Contrôles

```
cd nostrum.koplugin
lua test.lua        # ics, caldav, météo, pont : agenda, bascule d'adresses, recherche réseau
lua render.lua | python3 render.py DroidSansMono.ttf apercu.png   # écran + synchro par le pont
```

Routes du pont : en-tête de `pont/nostrum-pont.swift`.

## Licence

MIT, voir `LICENSE`. La police `DroidSansMono.ttf`, utilisée seulement pour
l'aperçu de l'écran, reste sous licence Apache 2.0.
