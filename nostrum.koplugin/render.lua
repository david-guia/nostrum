--[[
Peint l'écran hors appareil et écrit la liste des tracés sur la sortie standard.
`render.py` la rejoue avec la vraie police pour obtenir l'image exacte.

    lua render.lua | python3 render.py DroidSansMono.ttf apercu.png

Rebrancher le Kindle à chaque essai de mise en page n'est pas tenable ; c'est le
seul but de ce fichier, il n'a aucun rôle à l'exécution.
]]

local W, H = 600, 800

--== Doublures des modules KOReader =========================================

-- DroidSansMono, mesuré sur la police réelle : chasse fixe round(0.6*taille),
-- ascendante ceil(0.9312*taille). Les positions calculées ici sont donc celles
-- que produira l'appareil.
local function advance(size) return math.floor(size * 0.6 + 0.5) end
local function asc(size) return math.ceil(size * 0.9312) end

local ops = {}

local Blitbuffer = {
    Color8 = function(v) return v end,
    COLOR_WHITE = 255, COLOR_BLACK = 0, COLOR_GRAY = 128,
}

local RenderText = {}
function RenderText:sizeUtf8Text(_x, _w, f, text, _k)
    local n = 0
    for _ in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
    return { x = n * advance(f.size) }
end
function RenderText:renderUtf8Text(_bb, x, base, f, text, _k, bold, color, _w)
    ops[#ops + 1] = string.format("T\t%d\t%d\t%d\t%d\t%d\t%s",
        x, base, f.size, color or 255, bold and 1 or 0, text)
end

local bb = {}
function bb:paintRect(x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    ops[#ops + 1] = string.format("R\t%d\t%d\t%d\t%d\t%d", x, y, w, h, color or 255)
end

local face_stub = setmetatable({}, {
    __index = function() return nil end,
})

local Font = {}
function Font:getFace(_name, size)
    return setmetatable({ size = size, hash = "f" .. size, ftface = face_stub }, {})
end

local Geom = {}
function Geom:new(t) return t end

local Device = {
    screen = { getWidth = function() return W end, getHeight = function() return H end,
               scaleBySize = function(_, v) return v end },
    firmware_rev = "5.18.1.1.1",
    isTouchDevice = function() return true end,
    getPowerDevice = function() return { getCapacity = function() return 87 end } end,
}

local Widget = {}
function Widget:extend(t)
    t = t or {}
    t.extend = Widget.extend
    t.new = function(cls, o)
        o = o or {}
        setmetatable(o, { __index = cls })
        if o.init then o:init() end
        return o
    end
    return setmetatable(t, { __index = self })
end

package.loaded["ffi/blitbuffer"] = Blitbuffer
package.loaded["device"] = Device
package.loaded["ui/font"] = Font
package.loaded["ui/geometry"] = Geom
package.loaded["ui/gesturerange"] = { new = function(_, t) return t end }
package.loaded["ui/widget/infomessage"] = { new = function(_, t) return t end }
package.loaded["ui/widget/confirmbox"] = { new = function(_, t) t.confirmbox = true; return t end }
package.loaded["ui/widget/container/inputcontainer"] = Widget
package.loaded["ui/widget/container/widgetcontainer"] = Widget
package.loaded["ui/network/manager"] = {}
package.loaded["ui/rendertext"] = RenderText
-- Les differes sont mis de cote au lieu d'etre perdus : c'est ce qui permet de
-- derouler l'attente du reveil sans dormir vraiment.
local differes = {}
local peints = {}
local dernier_delai
package.loaded["ui/uimanager"] = { setDirty = function(_, cible, mode, zone) peints[#peints + 1] = { cible = cible, mode = mode, zone = zone } end,
                                   -- Retire vraiment : un minuteur qui se
                                   -- reprogramme tournerait sinon sans fin.
                                   unschedule = function(_, fn)
                                       for i = #differes, 1, -1 do
                                           if differes[i] == fn then table.remove(differes, i) end
                                       end
                                   end,
                                   scheduleIn = function(_, delai, fn) differes[#differes + 1] = fn; dernier_delai = delai end,
                                   nextTick = function(_, fn) fn() end,
                                   show = function() end }
local function derouler()
    local liste = differes
    differes = {}
    for _, fn in ipairs(liste) do fn() end
    return #liste
end
package.loaded["logger"] = { warn = function() end, info = function() end }
package.loaded["gettext"] = function(s) return s end
package.loaded["nostrum_caldav"] = { trace = {} }
package.loaded["nostrum_bridge"] = {}
package.loaded["nostrum_weather"] = {}
-- Modules homonymes d'un autre plugin, chargés avant nous : ils ne doivent
-- jamais être pris pour les nôtres (le plantage « field 'events' (a nil value) »).
for _, nom in ipairs({ "bridge", "caldav", "ics", "net", "weather" }) do
    package.loaded[nom] = setmetatable({}, { __index = function(_, k)
        error("module etranger « " .. nom .. " » utilise par Nostrum (" .. tostring(k) .. ")")
    end })
end

--== Données d'exemple ======================================================

local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."
local Nostrum = dofile(here .. "/main.lua")

local noon = os.time({ year = 2026, month = 7, day = 27, hour = 12 })
local day_start = os.time({ year = 2026, month = 7, day = 27, hour = 0 })
local day_end = day_start + 86400

-- Jeu de données relevé sur le compte le 27/07 : iCloud renvoie bien l'occurrence
-- du 26 d'« Apple Fitness+ », et un événement partagé peut arriver deux fois.
local brut = {
    { uid = "fitness", summary = "Apple Fitness+", allday = true,
      start = day_start - 86400, finish = day_start },          -- veille, à jeter
    { uid = "fitness", summary = "Apple Fitness+", allday = true,
      start = day_start, finish = day_end },
    { uid = "boulot", summary = "Réunion d'équipe", start = day_start + 7 * 3600,
      finish = day_start + 9 * 3600 },
    { uid = "boulot", summary = "Réunion d'équipe", start = day_start + 7 * 3600 },  -- partagé
    { uid = "dentiste", summary = "RDV chez le dentiste", start = day_start + 16 * 3600 + 900 },
    { uid = "demain", summary = "Hors fenêtre", start = day_end + 3600 },
}
-- Tous les codes servis par weather.lua doivent tomber sur une silhouette :
-- un code non couvert laisserait la zone vide sans que rien ne le signale.
for _, code in ipairs({ 0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67,
                        71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 99 }) do
    assert(Nostrum.sky_kind(code), "code WMO sans pictogramme : " .. code)
end
assert(Nostrum.sky_kind(nil) == nil and Nostrum.sky_kind(200) == nil,
    "un code inconnu doit rendre la main au remplissage")

-- Creneau affiche dans ORBITE : seule la fin du meme jour a un sens, « 00:00 »
-- pour une fin le lendemain tromperait plus que l'absence d'heure.
-- Convention de numerotation : entier pour un gros changement, decimale pour un
-- mineur. Un « 2.1.3 » glisse vite, la ligne du bandeau est calee sur ce format.
-- MAJEUR.FONCTION.CORRECTIF ; « 1.3 » d'avant la regle reste accepte.
assert(Nostrum.VERSION:match("^%d+%.%d+$") or Nostrum.VERSION:match("^%d+%.%d+%.%d+$"),
    "version attendue au format X.Y.Z")

local sl = Nostrum.slot
assert(sl({ allday = true, start = day_start }) == "JOUR", "journee entiere")
assert(sl({ start = day_start + 7 * 3600 }) == "07:00", "sans DTEND, debut seul")
assert(sl({ start = day_start + 7 * 3600, finish = day_start + 9 * 3600 }) == "07:00-09:00",
    "debut et fin le meme jour")
assert(sl({ start = day_start + 7 * 3600, finish = day_end + 3600 }) == "07:00",
    "une fin le lendemain ne doit pas s'afficher")
assert(sl({ start = day_start + 7 * 3600, finish = day_start + 7 * 3600 }) == "07:00",
    "une fin egale au debut ne doit pas s'afficher")

local net = Nostrum.prune_events(brut, day_start, day_end)
assert(#net == 3, "prune_events : attendu 3, obtenu " .. #net)
assert(net[1].summary == "Apple Fitness+" and net[1].start == day_start,
    "l'occurrence gardée doit être celle du jour")
for _, ev in ipairs(net) do
    assert(ev.summary ~= "Hors fenêtre", "événement hors fenêtre non filtré")
end
local view = Nostrum.View:new{
    cfg = {
        bridge_url = "http://192.168.1.172:8843",
        bridge_token = "jeton",
        reminder_lists = { "Pense Bête" },
        weather = { name = "DIJON" },
    },
    status = "LIAISON OK",
    last_sync = noon,
    weather = { place = "DIJON", temp = 23, tmin = 20, tmax = 29,
                -- 2e argument : forcer un code WMO pour revoir chaque silhouette.
                code = tonumber(arg and arg[2]) or 2,
                label = "nuages épars", wind = 7 },
    events = net,
    todos = {
        { summary = "Photos des dégâts", done = true, priority = 0 },
        { summary = "Colis n° AB000000001FR", done = false, priority = 0 },
        { summary = "Colis n° AB000000002FR", done = false, priority = 0 },
        { summary = "Rappeler Camille", done = false, priority = 0, due = noon + 5 * 86400 },
        { summary = "Contacter le plombier", done = false, priority = 1, due = os.time() - 86400 },
    },
}
view:paintTo(bb, 0, 0)

--== Contrôles de mise en page ==============================================
-- Un tracé hors cadre ou une case à cocher sans zone tactile ne se voient pas
-- toujours à l'œil sur une image ; ici ça échoue franchement.

local function check_bounds(where)
    for _, line in ipairs(ops) do
        local kind, a, b, c, d = line:match("^(%a)\t(-?%d+)\t(-?%d+)\t(-?%d+)\t(-?%d+)")
        if kind == "R" then
            local x0, y0 = tonumber(a), tonumber(b)
            assert(x0 >= 0 and y0 >= 0 and x0 + tonumber(c) <= W and y0 + tonumber(d) <= H,
                where .. " : tracé hors écran — " .. line)
        end
    end
end
check_bounds("écran garni")

assert(#view.rows == #view.todos, "chaque tâche doit avoir sa zone tactile")
assert(view.close_zone and view.sync_zone, "zones sortie / synchro absentes")
assert(view.sync_zone.top > view.rows[#view.rows].bottom,
    "la zone de synchro recouvre la dernière tâche")
assert(view.close_zone.bottom < view.rows[1].top,
    "la zone de sortie recouvre la première tâche")

-- Écran dégarni : ni météo, ni agenda, ni tâche. C'est l'état du premier
-- lancement et celui d'une panne réseau, jamais couvert par le cas ci-dessus.
local garni = ops
ops = {}
local vide = Nostrum.View:new{
    cfg = { weather = { name = "DIJON" } },
    status = "LIAISON ROMPUE",
}
vide:paintTo(bb, 0, 0)
check_bounds("écran dégarni")
assert(#vide.rows == 0, "aucune zone tactile sans tâche")
assert(vide.sync_zone and vide.close_zone, "zones sortie / synchro absentes à vide")
local degarni = ops

-- Journée chargée : l'agenda passe avant, DIRECTIVES cède la place, et le
-- surplus est signalé plutôt que de disparaître en silence.
ops = {}
local plein = Nostrum.View:new{
    cfg = view.cfg, status = "LIAISON OK", last_sync = noon,
    weather = view.weather, todos = view.todos, events = {},
}
for i = 1, 14 do
    plein.events[i] = { uid = "e" .. i, summary = "Rendez-vous " .. i,
                        start = day_start + (6 + i) * 3600 }
end
plein:paintTo(bb, 0, 0)
check_bounds("journée chargée")
-- Selection des calendriers : iCloud renvoie « Organisation Générale » avec un
-- espace final. Une comparaison stricte viderait l'agenda sans rien signaler.
local w = Nostrum._wanted
assert(w(nil, "David") and w({}, "David"), "liste vide = tout prendre")
assert(w({ "Organisation Générale" }, "Organisation Générale "), "espace final ignoré")
assert(w({ " David " }, "David"), "espaces du cote config ignorés")
assert(not w({ "David" }, "David Guia"), "un prefixe ne doit pas matcher")

assert(#plein.rows >= 1, "DIRECTIVES doit garder au moins une ligne")
assert(plein.sync_zone.top > plein.rows[#plein.rows].bottom,
    "la zone de synchro recouvre la dernière tâche")
local chargee = ops

-- Bascule de theme : le bouton est pose dans la bande de synchro, il doit donc
-- etre teste avant elle et ne recouvrir aucune ligne de tache.
local tz = view.theme_zone
assert(tz, "zone de bascule de theme absente")
assert(tz.top >= view.sync_zone.top, "le bouton de theme doit rester dans le pied")
for _, row in ipairs(view.rows) do
    assert(tz.top > row.bottom, "le bouton de theme recouvre une ligne de tache")
end

-- Mode clair : exact negatif du sombre. Meme geometrie, encres inversees.
ops = {}
local clair = Nostrum.View:new{
    cfg = view.cfg, status = view.status, last_sync = noon,
    weather = view.weather, events = view.events, todos = view.todos,
    light = true,
}
clair:paintTo(bb, 0, 0)
check_bounds("mode clair")
-- Seule l'encre change : les rectangles gardent la meme geometrie, seule la
-- derniere colonne (couleur) bouge. Le texte est exclu, le libelle du bouton
-- n'a pas la meme longueur dans les deux sens.
local function rects(list)
    local g = {}
    for _, o in ipairs(list) do
        local x, y, w, h, c = o:match("^R\t(%d+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)$")
        if x then g[#g + 1] = { key = x .. "," .. y .. "," .. w .. "," .. h, c = tonumber(c) } end
    end
    return g
end
local rs, rc = rects(garni), rects(ops)
assert(#rs == #rc and #rs > 0, "le theme ne doit pas changer la geometrie")
local inverses = 0
for i = 1, #rs do
    assert(rs[i].key == rc[i].key, "rectangle deplace par le theme : " .. rs[i].key)
    if rc[i].c == 255 - rs[i].c then inverses = inverses + 1 end
end
assert(inverses == #rs, "chaque aplat doit passer a son negatif")
assert(rs[1].c == 0 and rc[1].c == 255, "le fond doit s'inverser entre sombre et clair")
assert(clair.theme_zone and clair.sync_zone, "zones absentes en mode clair")
assert(#clair.rows == #view.rows, "meme nombre de zones tactiles dans les deux themes")
-- Sortie de veille : le Kindle rediffuse « Resume » a toute la pile. Sans
-- resynchro l'ecran garde l'agenda d'avant le sommeil, et sans garde deux
-- appuis sur le bouton veille synchronisent deux fois pour rien.
-- Le reseau n'est pas notre affaire : sync() passe par ensure_network et
-- KOReader applique ses propres reglages de wifi au reveil.
local reveil = Nostrum.View:new{ cfg = view.cfg }
local synchros = 0
reveil.sync = function() synchros = synchros + 1 end
derouler()

reveil.last_sync = os.time() - 3600
reveil:onResume()
assert(synchros == 1, "le reveil doit resynchroniser")

reveil.last_sync = os.time()
reveil:onResume()
assert(synchros == 1, "une synchro de moins d'une minute doit suffire")
reveil:stopTimers()
while derouler() > 0 do end

-- Horloge : l'heure affichee suivait la derniere synchro. Le minuteur repeint
-- le haut de l'ecran a chaque changement de minute, sans plein ecran.
local horloge = Nostrum.View:new{ cfg = view.cfg }
horloge:paintTo(bb, 0, 0)
assert(horloge.clock_zone and horloge.clock_zone.y > 0 and horloge.clock_zone.h > 0,
    "zone de l'horloge non relevee")
assert(horloge.clock_zone.y + horloge.clock_zone.h < view.rows[1].top,
    "la zone de l'horloge ne doit pas couvrir la liste des taches")
horloge:start_clock()
local attendu = 60 - tonumber(os.date("%S"))
assert(dernier_delai >= 1 and dernier_delai <= 60 and math.abs(dernier_delai - attendu) <= 1,
    "le minuteur doit viser le prochain changement de minute : " .. tostring(dernier_delai))
peints = {}
assert(derouler() == 1, "un seul minuteur d'horloge attendu")
assert(#peints == 1 and peints[1].mode == "ui" and peints[1].zone == horloge.clock_zone,
    "chaque minute : rafraichissement partiel de la seule zone de l'horloge")
assert(#differes == 1, "le minuteur doit se reprogrammer pour la minute suivante")
-- Reveil : le minuteur fige est recale, sans en empiler un second.
horloge.sync = function() end
horloge:onResume()
assert(#differes == 1, "le reveil ne doit pas doubler le minuteur")
horloge:stopTimers()
assert(#differes == 0, "fermer l'ecran doit arreter l'horloge")

-- Choix des sources depuis le Kindle. « Rien de coche » veut dire « tout
-- afficher » : c'est la convention de config.lua, et un menu qui la trahirait
-- laisserait l'ecran vide sans que rien ne le dise.
local reglages = {}
G_reader_settings = {
    readSetting = function(_, k) return reglages[k] end,
    saveSetting = function(_, k, v) reglages[k] = v end,
    isTrue = function(_, k) return reglages[k] == true end,
}
local basculer, vu = Nostrum._toggle_pick, Nostrum._wanted
reglages["nostrum_seen_lists"] = { "Courses", "Pense Bete", "Travail" }
local function choisies() return reglages["nostrum_pick_lists"] end

assert(vu(choisies(), "Courses") and vu(choisies(), "Travail"),
    "sans reglage, toutes les listes doivent etre cochees")

-- Premier decochage : le reglage vide doit d'abord se materialiser, sinon il
-- serait relu comme « tout » et le clic n'aurait aucun effet.
basculer("lists", "Courses")
assert(choisies(), "premier decochage : aucun reglage ecrit")
assert(#choisies() == 2 and not vu(choisies(), "Courses"),
    "premier decochage sans effet : " .. #choisies() .. " listes retenues")
assert(vu(choisies(), "Travail"), "les autres listes doivent rester cochees")

basculer("lists", "Travail")
assert(#choisies() == 1 and vu(choisies(), "Pense Bete"), "second decochage rate")

-- Recocher jusqu'au bout ramene au reglage vide : une liste figee se perimerait
-- des qu'une nouvelle liste apparait cote iCloud.
basculer("lists", "Courses")
basculer("lists", "Travail")
assert(#choisies() == 0, "tout recoche doit revenir au reglage vide")

-- Tout decocher affiche tout, plutot qu'un ecran vide sans explication.
for _, nom in ipairs(reglages["nostrum_seen_lists"]) do basculer("lists", nom) end
assert(vu(choisies(), "Courses"), "tout decoche doit revenir a tout afficher")

-- Le reglage de l'appareil prime sur config.lua : c'est le seul des deux qui se
-- change sans cable.
-- Config jetable : le vrai config.lua porte des identifiants et son contenu
-- n'a pas a decider si ce controle passe.
local faux_dir = os.tmpname()
os.remove(faux_dir)
assert(os.execute("mkdir -p '" .. faux_dir .. "'"), "dossier jetable impossible")
local fc = assert(io.open(faux_dir .. "/config.lua", "w"))
fc:write('return { username = "u", password = "p", calendars = { "Agenda" } }')
fc:close()
local faux_plugin = { path = faux_dir, loadConfig = Nostrum.loadConfig }

reglages["nostrum_pick_calendars"] = { "Perso" }
local cfg_menu = assert(faux_plugin:loadConfig())
assert(cfg_menu.calendars[1] == "Perso" and #cfg_menu.calendars == 1,
    "le menu doit primer sur config.lua")
reglages["nostrum_pick_calendars"] = nil
assert(assert(faux_plugin:loadConfig()).calendars[1] == "Agenda",
    "sans reglage, config.lua doit garder la main")
os.execute("rm -rf '" .. faux_dir .. "'")

-- Mise a jour par le pont : rien ne doit etre remplace tant que tout n'est pas
-- telecharge et verifie. Un plugin a moitie remplace ne se charge plus, et il
-- n'y a alors plus d'entree de menu pour reessayer.
local Pont = package.loaded["nostrum_bridge"]
local box_dir = os.tmpname()
os.remove(box_dir)
assert(os.execute("mkdir -p '" .. box_dir .. "'"), "dossier jetable impossible")
local function ecrire(nom, contenu)
    local f = assert(io.open(box_dir .. "/" .. nom, "wb")); f:write(contenu); f:close()
end
local function lire(nom)
    local f = io.open(box_dir .. "/" .. nom, "rb")
    if not f then return nil end
    local c = f:read("*a"); f:close(); return c
end

ecrire("main.lua", "ancien")
local servi = { ["main.lua"] = "return 1", ["net.lua"] = "return 22" }
local function manifeste()
    return { version = "9.9", files = {
        { name = "main.lua", size = #servi["main.lua"] },
        { name = "net.lua", size = #servi["net.lua"] } } }
end
Pont.manifest = manifeste
Pont.file = function(_, n) return servi[n] end
local v, n = Nostrum._update({}, box_dir)
assert(v == "9.9" and n == 2, "mise a jour complete refusee : " .. tostring(n))
assert(lire("main.lua") == "return 1" and lire("net.lua") == "return 22",
    "les fichiers annonces doivent etre en place")
assert(not lire("main.lua.new"), "les fichiers temporaires doivent disparaitre")

-- Transfert coupe sur le second fichier : le premier ne doit pas bouger. Le
-- corps tronque reste du Lua valide, sinon c'est le controle de syntaxe qui
-- attraperait la coupure et celui de taille ne serait jamais exerce.
servi["main.lua"] = "return 3"
Pont.file = function(_, nom) return nom == "net.lua" and "return 2" or servi[nom] end
local ok_t, err_t = Nostrum._update({}, box_dir)
assert(not ok_t and err_t:match("net%.lua : 8 octets sur 9"),
    "taille incoherente non detectee : " .. tostring(err_t))
assert(lire("main.lua") == "return 1", "un fichier a ete remplace malgre l'echec")

-- Syntaxe invalide : meme exigence, et c'est le seul garde-fou contre un
-- fichier complet mais casse a la source.
Pont.file = function(_, nom) return nom == "net.lua" and "return (" or servi[nom] end
Pont.manifest = function()
    local m = manifeste()
    m.files[2].size = 8
    return m
end
local ok_s, err_s = Nostrum._update({}, box_dir)
assert(not ok_s and err_s:match("syntaxe"), "syntaxe invalide non detectee")
assert(lire("main.lua") == "return 1", "remplacement malgre une syntaxe invalide")
-- Echec d'ecriture au milieu du lot : un dossier occupe le nom du fichier
-- temporaire, io.open echoue dessus. Sans le detour par les .new, main.lua
-- serait deja ecrase a ce moment-la.
Pont.manifest = manifeste
Pont.file = function(_, nom) return servi[nom] end
assert(os.execute("mkdir -p '" .. box_dir .. "/net.lua.new'"), "blocage impossible")
local ok_w, err_w = Nostrum._update({}, box_dir)
assert(not ok_w and err_w:match("ecriture impossible"),
    "echec d'ecriture non signale : " .. tostring(err_w))
assert(lire("main.lua") == "return 1", "main.lua remplace malgre un echec d'ecriture")

-- Archives : la version en place est copiee avant d'etre ecrasee, et se
-- remet en place depuis le menu. Sans ca, une mauvaise version ne se defait
-- qu'au cable.
os.execute("rm -rf '" .. box_dir .. "/../nostrum-archives'")
Pont.file = function(_, nom) return servi[nom] end
os.execute("rm -rf '" .. box_dir .. "/net.lua.new'")
ecrire("main.lua", "return 'avant'")
ecrire("net.lua", "return 'aussi avant'")
local v2 = Nostrum._update({}, box_dir)
assert(v2 == "9.9", "seconde mise a jour refusee : " .. tostring(v2))
local archives = Nostrum._archived(box_dir)
assert(#archives == 1 and archives[1] == Nostrum.VERSION,
    "la version en place doit etre archivee : " .. table.concat(archives, ","))
assert(lire("main.lua") == servi["main.lua"], "la mise a jour doit avoir eu lieu")

local vr, nr = Nostrum._restore(Nostrum.VERSION, box_dir)
assert(vr == Nostrum.VERSION and nr == 2, "restauration refusee : " .. tostring(nr))
assert(lire("main.lua") == "return 'avant'" and lire("net.lua") == "return 'aussi avant'",
    "la restauration doit remettre les fichiers archives")

-- Archive corrompue : rien ne doit bouger, sinon le plugin ne se charge plus et
-- il n'y a plus de menu pour reessayer.
ecrire("main.lua", "return 'apres'")
local box_arch = box_dir .. "/../nostrum-archives/" .. Nostrum.VERSION
local fh = io.open(box_arch .. "/net.lua", "wb"); fh:write("return ("); fh:close()
local ok_r, err_r = Nostrum._restore(Nostrum.VERSION, box_dir)
assert(not ok_r and err_r:match("syntaxe"), "archive cassee non detectee : " .. tostring(err_r))
assert(lire("main.lua") == "return 'apres'", "restauration partielle malgre une archive cassee")

-- config.lua n'est jamais archive : il contient les identifiants et une mise a
-- jour n'y touche pas.
assert(not io.open(box_arch .. "/config.lua"), "config.lua ne doit pas etre archive")

os.execute("rm -rf '" .. box_dir .. "/../nostrum-archives'")
os.execute("rm -rf '" .. box_dir .. "'")

-- Synchro en mode pont, sans identifiants iCloud : c'est la config qu'ecrit
-- l'application Mac. CalDAV ne doit jamais etre appele, l'agenda vient du pont.
local CalDAVStub = package.loaded["nostrum_caldav"]
CalDAVStub.discover = function() error("CalDAV appele alors que le pont sert l'agenda") end
Pont.prefs = function() return { calendars = {}, lists = {} } end
Pont.events = function() return { { uid = "x", summary = "Dentiste", start = os.time() + 60 } }, nil, { "Perso" } end
Pont.todos = function() return { { summary = "Pain", priority = 0 } }, nil, { "Courses" } end
-- Meme version que celle en place : la synchro ne doit rien installer ici,
-- update_from_bridge viserait le vrai dossier du plugin.
Pont.manifest = function() return { version = Nostrum.VERSION, files = {} } end
package.loaded["nostrum_weather"].fetch = function() return nil end
local synchro = Nostrum.View:new{ cfg = { bridge_token = "t", weather = {} } }
synchro:fetch(1)
assert(synchro.status == "LIAISON OK", "synchro par le pont : " .. tostring(synchro.status))
assert(#synchro.events == 1 and synchro.events[1].summary == "Dentiste", "agenda du pont non affiche")
assert(#synchro.todos == 1, "taches du pont non affichees")
assert(reglages["nostrum_seen_calendars"][1] == "Perso", "calendriers du pont non proposes au menu")

-- Pont injoignable : l'ecran garde l'agenda precedent, apres les relances.
Pont.events = function() return nil, "reseau: timeout" end
synchro:fetch(3)
assert(synchro.status == "PONT INJOIGNABLE", "statut attendu PONT INJOIGNABLE : " .. synchro.status)
assert(#synchro.events == 1, "l'agenda precedent doit rester affiche")
while derouler() > 0 do end

-- Identifiants iCloud fournis depuis l'app Mac : secours seulement. Mac
-- allume, le pont sert l'agenda (il voit aussi Google, Exchange…).
local secours = Nostrum.View:new{ cfg = { bridge_token = "t", username = "moi@icloud.com",
                                          password = "abcd-efgh-ijkl-mnop", weather = {} } }
Pont.events = function() return { { uid = "p", summary = "Vu par le Mac", start = os.time() + 60 } }, nil, { "Perso" } end
secours:fetch(1)
assert(secours.status == "LIAISON OK" and secours.source == "PONT",
    "Mac allume : l'agenda doit venir du pont, pas d'iCloud")
assert(secours.events[1].summary == "Vu par le Mac")
assert(#secours.todos == 1, "taches du pont attendues")

-- Mac eteint : agenda lu sur iCloud, taches d'avant conservees, et le pont
-- n'est sollicite qu'une fois (prefs) — chaque essai coute un delai.
local appels_pont = 0
Pont.prefs = function() appels_pont = appels_pont + 1; return nil, "reseau: timeout" end
Pont.events = function() error("pont redemande alors qu'il vient d'echouer") end
Pont.todos = function() error("pont redemande alors qu'il vient d'echouer") end
CalDAVStub.discover = function() return { { name = "Perso", events = true } } end
CalDAVStub.events = function()
    return { { uid = "i", summary = "Lu sur iCloud", start = os.time() + 120 } }
end
secours:fetch(1)
assert(appels_pont == 1, "le pont ne doit etre essaye qu'une fois par synchro")
assert(secours.status == "MAC ÉTEINT", "statut attendu MAC ÉTEINT : " .. tostring(secours.status))
assert(secours.source == "ICLOUD", "la source affichee doit etre ICLOUD")
assert(secours.events[1].summary == "Lu sur iCloud", "agenda iCloud non affiche")
assert(#secours.todos == 1 and secours.todos[1].summary == "Pain", "les taches d'avant doivent rester")
assert(reglages["nostrum_seen_calendars"][1] == "Perso", "le menu doit garder les calendriers du Mac")

-- La resynchro horaire programmee par `secours` ne doit pas tourner sous les
-- doublures du cas suivant : on oublie les differes en attente.
differes = {}

-- Mac eteint sans identifiants : comportement d'avant, rien de lu sur iCloud.
CalDAVStub.discover = function() error("CalDAV appele sans identifiants") end
synchro:fetch(3)
assert(synchro.status == "PONT INJOIGNABLE", "sans identifiants : " .. tostring(synchro.status))
while derouler() > 0 do end
Pont.prefs = function() return { calendars = {}, lists = {} } end

-- Mise a jour proposee : le Kindle suit la version du Mac. Rien ne s'installe
-- sans accord, et la question n'est posee qu'une fois par version.
local UI = package.loaded["ui/uimanager"]
local montres = {}
UI.show = function(_, w) montres[#montres + 1] = w end
UI.close = function() end

local maj_dir = os.tmpname()
os.remove(maj_dir)
assert(os.execute("mkdir -p '" .. maj_dir .. "'"))
local installs = 0
Pont.manifest = function() return { version = "99.0", files = { { name = "main.lua", size = 8 } } } end
Pont.file = function() installs = installs + 1; return "return 9" end

synchro:propose_update(maj_dir)
local question = montres[#montres]
assert(question and question.confirmbox, "une version differente doit etre proposee")
assert(question.text:find("99.0", 1, true), "la question doit nommer la version du Mac")
assert(installs == 0, "rien ne doit s'installer avant l'accord")

question.ok_callback()
assert(installs == 1, "accepter doit installer la version du Mac")
local fm = assert(io.open(maj_dir .. "/main.lua")); assert(fm:read("*a") == "return 9"); fm:close()
assert(montres[#montres].text:find("Redémarrer", 1, true), "installer doit inviter a redemarrer KOReader")

local avant = #montres
synchro:propose_update(maj_dir)
assert(#montres == avant, "la meme version ne doit etre proposee qu'une fois")

-- Meme version des deux cotes : aucune question.
Pont.manifest = function() return { version = Nostrum.VERSION, files = {} } end
synchro:propose_update(maj_dir)
assert(#montres == avant, "aucune question quand les versions concordent")
UI.show = function() end
os.execute("rm -rf '" .. maj_dir .. "' '" .. maj_dir .. "/../nostrum-archives'")

local en_clair = ops

-- `vide`, `plein` ou `clair` sortent l'écran correspondant ; sans argument, l'écran garni.
local mode = arg and arg[1]
if mode == "vide" then
    view, ops = vide, degarni
elseif mode == "plein" then
    view, ops = plein, chargee
elseif mode == "clair" then
    view, ops = clair, en_clair
else
    ops = garni
end

io.stderr:write(string.format("%d tracés, %d rendez-vous, %d lignes de tâches — contrôles OK\n",
    #ops, #view.events, #view.rows))
print(W .. "\t" .. H)
print(table.concat(ops, "\n"))
