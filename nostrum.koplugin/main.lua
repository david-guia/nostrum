--[[
NOSTRUM — agenda + tâches iCloud sur Kindle, interface d'ordinateur de bord.
Plugin KOReader. Tout est peint à la main : sur 600x800 en 16 gris, les
widgets standard coûtent plus cher qu'un paintTo direct.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- Version du plugin, affichee dans le bandeau. Entier +1 pour un gros
-- changement, +0.1 pour un changement mineur. Elle remplace la revision du
-- firmware, qui n'apprenait rien : c'est ce fichier qui bouge, pas le Kindle.
local VERSION = "1.3"

-- Le chargeur de plugins n'ajoute pas toujours le dossier du plugin au package.path
-- selon la version de KOReader. Sans ça, require("nostrum_caldav") échoue et le plugin
-- est ignoré silencieusement : aucune entrée de menu, aucun message.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")
if here and not package.path:find(here, 1, true) then
    package.path = here .. "/?.lua;" .. package.path
end

-- Tous les plugins partagent le cache de require : un « bridge » ou un « net »
-- déjà chargé par un autre plugin serait rendu à la place du nôtre. C'est ce qui
-- faisait planter Nostrum à côté de l'ancien plugin (Bridge.events absent). D'où
-- le préfixe nostrum_ sur chacun de nos modules.
local CalDAV = require("nostrum_caldav")
-- Optionnels : leur absence ne doit pas empêcher le plugin de se charger.
local ok_bridge, Bridge = pcall(require, "nostrum_bridge")
local ok_weather, Weather = pcall(require, "nostrum_weather")
local Screen = Device.screen

--== Utilitaires =============================================================

-- string.upper ignore l'UTF-8. Table minimale pour le français.
local ACCENTS = {
    ["é"] = "É", ["è"] = "È", ["ê"] = "Ê", ["ë"] = "Ë",
    ["à"] = "À", ["â"] = "Â", ["ä"] = "Ä",
    ["î"] = "Î", ["ï"] = "Ï",
    ["ô"] = "Ô", ["ö"] = "Ö",
    ["ù"] = "Ù", ["û"] = "Û", ["ü"] = "Ü",
    ["ç"] = "Ç", ["œ"] = "Œ", ["æ"] = "Æ",
}

local function upper(s)
    s = tostring(s or ""):gsub("[\194-\244][\128-\191]*", function(c)
        return ACCENTS[c] or c
    end)
    return (s:upper())
end

-- Le mono n'a pas de nom stable selon les versions de KOReader : on essaie.
local face_cache = {}
local FACE_CANDIDATES = { "droid/DroidSansMono.ttf", "DroidSansMono.ttf", "infont", "smallinfont" }

local function face(size)
    size = math.floor(size)
    if face_cache[size] then return face_cache[size] end
    for _, name in ipairs(FACE_CANDIDATES) do
        local ok, f = pcall(Font.getFace, Font, name, size)
        if ok and f then
            face_cache[size] = f
            return f
        end
    end
    face_cache[size] = Font:getFace("cfont", size)
    return face_cache[size]
end

local function hhmm(ts) return ts and os.date("%H:%M", ts) or "--:--" end

-- « 07:00-09:00 » quand la fin est connue et tombe le meme jour. Une fin le
-- lendemain afficherait « 00:00 », plus trompeur que pas d'heure du tout ;
-- DTEND est d'ailleurs souvent absent, l'heure de debut reste alors seule.
local function slot(ev)
    if ev.allday then return "JOUR" end
    local a, b = ev.start, ev.finish
    if a and b and b > a and os.date("%Y%m%d", a) == os.date("%Y%m%d", b) then
        return hhmm(a) .. "-" .. hhmm(b)
    end
    return hhmm(a)
end

-- Deux défauts corrigés en un passage, après que toutes les collections aient
-- répondu : c'est le seul endroit où les deux sont visibles.
--
-- 1. iCloud renvoie l'occurrence de la veille des événements journée entière :
--    leur DTEND tombe pile au début de la fenêtre, ce qui suffit à les faire
--    matcher le time-range. D'où « Apple Fitness+ » affiché deux fois.
-- 2. Un événement partagé figure dans le calendrier de chacun ; deux collections
--    du même compte le renvoient alors tel quel.
local function prune_events(events, day_start, day_end)
    local out, seen = {}, {}
    for _, ev in ipairs(events) do
        local fin = ev.finish or ((ev.start or 0) + (ev.allday and 86400 or 3600))
        if (ev.start or 0) < day_end and fin > day_start then
            local key = (ev.uid or ev.summary or "?") .. "|" .. tostring(ev.start)
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = ev
            end
        end
    end
    return out
end

-- L'API réseau de KOReader a été renommée au fil des versions : on prend celle qui existe.
-- Sur Kindle, l'association WiFi rend la main avant que l'interface ait une IP ;
-- d'où le second filet, la relance différée dans fetch().
local function online()
    if NetworkMgr.isOnline and NetworkMgr:isOnline() then return true end
    if NetworkMgr.isConnected and NetworkMgr:isConnected() then return true end
    -- Aucune des deux API : KOReader trop ancien pour repondre. On suppose le
    -- reseau present plutot que de bloquer la synchro pour toujours.
    return not (NetworkMgr.isOnline or NetworkMgr.isConnected)
end

local function ensure_network(fn)
    if online() then return fn() end
    local runner = NetworkMgr.runWhenOnline or NetworkMgr.runWhenConnected
    if runner then return runner(NetworkMgr, fn) end
    return fn()
end

local function wifi_is_off()
    return NetworkMgr.isWifiOn and not NetworkMgr:isWifiOn()
end

-- Panne de transport (pas de route, DNS, TLS) plutôt que réponse HTTP du serveur.
local function is_transport_error(err)
    err = tostring(err or ""):lower()
    return err:find("reseau:", 1, true) ~= nil
        or err:find("unreachable", 1, true) ~= nil
        or err:find("timeout", 1, true) ~= nil
        or err:find("host not found", 1, true) ~= nil
        or err:find("connection refused", 1, true) ~= nil
        or err:find("introuvable", 1, true) ~= nil
end

-- Le pont prend la main des que config.lua porte son jeton : c'est ce qu'ecrit
-- l'application Mac a l'installation. Les identifiants iCloud deviennent alors
-- facultatifs ; renseignes (depuis l'app Mac), ils servent de secours : Mac
-- eteint, l'agenda est lu directement sur iCloud.
local function via_bridge(cfg) return ok_bridge and cfg.bridge_token ~= nil end
local function has_icloud(cfg) return cfg.username ~= nil and cfg.password ~= nil end

--== Vue =====================================================================

local View = InputContainer:extend{
    covers_fullscreen = true,
    events = nil,
    todos = nil,
    status = "INITIALISATION",
    flash_count = 0,
}

function View:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.rows = {}
    self.events = self.events or {}
    self.todos = self.todos or {}

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
            -- Second filet de sortie : le geste « retour » habituel de KOReader.
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
    -- Sans effet sur Kindle 10 (aucun bouton hors power), utile sur Oasis/Voyage.
    self.key_events = { Close = { { "Back" } } }
end

local function fill(bb, x, y, w, h, color)
    bb:paintRect(x, y, math.max(0, w), math.max(0, h), color)
end

--== Primitives de tracé =====================================================
-- Portage direct de nostrum-maquette.py : mêmes constantes, même ordre.

-- Les constantes de gris de Blitbuffer ont changé de nom au fil des versions.
-- Color8 est stable, on s'en sert quand elle est là.
local function gray(level)
    if Blitbuffer.Color8 then return Blitbuffer.Color8(level) end
    if level >= 208 then return Blitbuffer.COLOR_WHITE end
    if level >= 128 then return Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE end
    if level >= 48 then return Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_WHITE end
    return Blitbuffer.COLOR_BLACK
end

local function utf8_iter(s)
    return tostring(s or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*")
end

-- renderUtf8Text cale sur la ligne de base, PIL sur le haut du jambage : sans
-- cette conversion toute la maquette descend d'une hauteur de police.
local asc_cache = {}
local function ascender(f)
    local key = tostring(f.hash or f.size)
    if not asc_cache[key] then
        local ok, _h, up = pcall(function() return f.ftface:getHeightAndAscender() end)
        asc_cache[key] = (ok and up) and math.ceil(up) or math.floor(f.size * 0.8)
    end
    return asc_cache[key]
end

local function char_w(f, ch)
    return RenderText:sizeUtf8Text(0, 10000, f, ch, true).x
end

local function wide_len(str, f, spacing)
    local w = 0
    for ch in utf8_iter(str) do w = w + char_w(f, ch) + spacing end
    return w
end

-- Capitales espacées : la typo des consoles de bord respire. Un appel de rendu
-- par caractère, mais l'écran ne se repeint qu'à la synchro ou sur un tap.
local function wide(bb, x, top, str, f, color, spacing, bold, maxx)
    local base = top + ascender(f)
    for ch in utf8_iter(str) do
        local cw = char_w(f, ch)
        if maxx and x + cw > maxx then break end
        RenderText:renderUtf8Text(bb, x, base, f, ch, true, bold or false, color)
        x = x + cw + spacing
    end
    return x
end

-- Texte centre dans un cadre. Les cases de la maquette sont a largeur fixe et
-- leur contenu varie (« JOUR » ou « 07:00-09:00 ») : cale a gauche, le cadre
-- parait vide d'un cote. wide_len compte un espacement apres le dernier signe,
-- qu'il faut retirer pour que le centrage soit optique et non arithmetique.
local function wide_mid(bb, x0, x1, top, str, f, color, spacing, bold)
    local w = wide_len(str, f, spacing) - spacing
    -- Un libelle plus large que sa case deborderait par la gauche : mieux vaut
    -- qu'il parte du bord et soit tronque a droite comme partout ailleurs.
    local x = math.max(x0, x0 + math.floor((x1 - x0 - w) / 2))
    return wide(bb, x, top, str, f, color, spacing, bold, x1)
end

local function box(bb, x0, y0, x1, y1, color, w)
    w = w or 1
    local bw, bh = x1 - x0 + 1, y1 - y0 + 1
    fill(bb, x0, y0, bw, w, color)
    fill(bb, x0, y1 - w + 1, bw, w, color)
    fill(bb, x0, y0, w, bh, color)
    fill(bb, x1 - w + 1, y0, w, bh, color)
end

-- Rangée de tirets verticaux — le séparateur des écrans de la passerelle.
local function ticks(bb, x0, x1, y, step, h, color)
    local tx = x0
    while tx < x1 do
        fill(bb, tx, y, 1, h, color)
        tx = tx + step
    end
end

local function crosshair(bb, cx, cy, arm, color)
    fill(bb, cx - arm, cy, arm * 2 + 1, 1, color)
    fill(bb, cx, cy - arm, 1, arm * 2 + 1, color)
end

--== Pictogramme du ciel =====================================================
-- Silhouettes pleines, sans contour : sur une dalle 16 gris un aplat se lit de
-- loin là où un trait fin se noie dans le rémanent.

local function disc(bb, cx, cy, r, color)
    for dy = -r, r do
        local dx = math.floor(math.sqrt(r * r - dy * dy) + 0.5)
        fill(bb, cx - dx, cy + dy, dx * 2 + 1, 1, color)
    end
end

-- Segment épais quelconque. Les traits obliques (pluie, éclair) n'ont pas
-- d'équivalent en rectangles.
local function stroke(bb, x0, y0, x1, y1, w, color)
    local dx, dy = x1 - x0, y1 - y0
    local n = math.max(math.abs(dx), math.abs(dy), 1)
    local h = math.floor(w / 2)
    for i = 0, n do
        fill(bb, math.floor(x0 + dx * i / n + 0.5) - h,
                 math.floor(y0 + dy * i / n + 0.5) - h, w, w, color)
    end
end

local function sun(bb, cx, cy, r, color)
    disc(bb, cx, cy, math.floor(r * 0.52), color)
    local ray, w = math.floor(r * 0.30), math.max(2, math.floor(r * 0.12))
    for i = 0, 7 do
        local a = i * math.pi / 4
        local ix, iy = math.cos(a) * r * 0.70, math.sin(a) * r * 0.70
        local ox, oy = math.cos(a) * (r * 0.70 + ray), math.sin(a) * (r * 0.70 + ray)
        stroke(bb, cx + ix, cy + iy, cx + ox, cy + oy, w, color)
    end
end

-- Trois bosses sur une base plate : la forme lit comme un nuage même à 40 px.
local function cloud(bb, cx, cy, r, color)
    local base = cy + math.floor(r * 0.34)
    disc(bb, cx - math.floor(r * 0.46), cy + math.floor(r * 0.06), math.floor(r * 0.30), color)
    disc(bb, cx - math.floor(r * 0.02), cy - math.floor(r * 0.16), math.floor(r * 0.42), color)
    disc(bb, cx + math.floor(r * 0.50), cy + math.floor(r * 0.02), math.floor(r * 0.34), color)
    fill(bb, cx - math.floor(r * 0.76), cy, math.floor(r * 1.60), base - cy, color)
end

local function sky_glyph(bb, cx, cy, r, kind, ink, dim)
    if kind == "soleil" then
        sun(bb, cx, cy, r, ink)
        return
    end

    -- Le nuage occupe le haut ; le bas reste libre pour ce qui en tombe.
    local top = (kind == "couvert") and cy or cy - math.floor(r * 0.30)
    if kind == "eclaircies" then
        -- Assez haut et à droite pour que le disque sorte franchement du nuage :
        -- à peine dépassant, il se lisait comme une bosse de plus.
        sun(bb, cx + math.floor(r * 0.62), top - math.floor(r * 0.62), math.floor(r * 0.44), ink)
    end
    cloud(bb, cx, top, r, dim)

    local fy = top + math.floor(r * 0.48)
    local w = math.max(2, math.floor(r * 0.11))
    if kind == "pluie" then
        for i = -1, 1 do
            local sx = cx + i * math.floor(r * 0.42)
            stroke(bb, sx + math.floor(r * 0.12), fy, sx - math.floor(r * 0.10),
                   fy + math.floor(r * 0.40), w, ink)
        end
    elseif kind == "neige" then
        for i = -1, 1 do
            -- Écart supérieur au double du bras, sinon les trois flocons se
            -- rejoignent en une seule tache.
            local sx, sy = cx + i * math.floor(r * 0.52), fy + math.floor(r * 0.20)
            local a = math.floor(r * 0.15)
            crosshair(bb, sx, sy, a, ink)
            stroke(bb, sx - a, sy - a, sx + a, sy + a, w, ink)
            stroke(bb, sx - a, sy + a, sx + a, sy - a, w, ink)
        end
    elseif kind == "orage" then
        local b = math.floor(r * 0.42)
        stroke(bb, cx + b * 0.7, fy, cx - b * 0.5, fy + b, w, ink)
        stroke(bb, cx - b * 0.5, fy + b, cx + b * 0.4, fy + b, w, ink)
        stroke(bb, cx + b * 0.4, fy + b, cx - b * 0.6, fy + b * 2.1, w, ink)
    elseif kind == "brouillard" then
        for i = 0, 2 do
            local by = fy + i * math.floor(r * 0.22)
            local inset = math.floor(r * (i % 2 == 0 and 0.30 or 0.10))
            fill(bb, cx - math.floor(r * 0.70) + inset, by,
                 math.floor(r * 1.40) - inset * 2, w, ink)
        end
    end
end

-- Codes WMO regroupés par silhouette : le détail est déjà dans le libellé.
local function sky_kind(code)
    code = tonumber(code)
    if not code then return nil end
    if code == 0 then return "soleil" end
    if code <= 2 then return "eclaircies" end
    if code == 3 then return "couvert" end
    if code <= 48 then return "brouillard" end
    if code <= 67 then return "pluie" end
    if code <= 79 then return "neige" end
    if code <= 82 then return "pluie" end
    if code <= 86 then return "neige" end
    if code <= 99 then return "orage" end
    return nil
end

--== Dates en français =======================================================
-- Le Kindle n'a pas de locale fr : os.date("%A") rendrait « Sunday ».

local JOURS = { "DIM.", "LUN.", "MAR.", "MER.", "JEU.", "VEN.", "SAM." }
local MOIS = { "JANVIER", "FÉVRIER", "MARS", "AVRIL", "MAI", "JUIN", "JUILLET",
               "AOÛT", "SEPTEMBRE", "OCTOBRE", "NOVEMBRE", "DÉCEMBRE" }

local function date_fr(ts)
    local t = os.date("*t", ts)
    return JOURS[t.wday] .. " " .. t.day .. " " .. MOIS[t.month]
end

function View:paintTo(bb, x, y)
    local W, H = self.dimen.w, self.dimen.h
    -- La maquette est calée au pixel sur le 600x800 du Kindle 10. Le facteur
    -- garde l'écran lisible sur un autre appareil sans refaire la mise en page.
    local s = W / 600
    local function p(v) return math.floor(v * s + 0.5) end

    -- Le mode clair est l'exact negatif du sombre : une seule palette, inversee
    -- au besoin. Rien d'autre dans la mise en page ne depend du theme.
    local function tone(v) return gray(self.light and 255 - v or v) end
    local BG, INK, DIM, FAINT, DOT = tone(0), tone(255), tone(168), tone(96), tone(64)
    local f_title, f_body = face(p(21)), face(p(18))
    local f_small, f_tiny = face(p(13)), face(p(10))

    fill(bb, x, y, W, H, BG)
    self.rows = {}

    local function panel(x0, y0, x1, y1, title, sub)
        box(bb, x0, y0, x1, y1, INK)
        local tw = wide_len(title, f_small, 2) + p(14)
        fill(bb, x0, y0 - p(9), tw, p(18), INK)
        wide(bb, x0 + p(7), y0 - p(7), title, f_small, BG, 2, true)
        if sub then
            local sw = wide_len(sub, f_tiny, 1)
            -- Le trait du cadre doit être interrompu derrière le libellé, sinon
            -- il le barre et le rend illisible.
            fill(bb, x1 - sw - p(14), y0 - p(7), sw + p(8), p(14), BG)
            wide(bb, x1 - sw - p(11), y0 - p(6), sub, f_tiny, DIM, 1)
        end
    end

    -- Trame de points et croix de repère : le vide d'un écran de bord n'est
    -- jamais nu. S'efface d'elle-même quand le contenu remplit la zone.
    local function filler(x0, y0, x1, y1)
        if y1 - y0 < p(50) or x1 - x0 < p(60) then return end
        local py = y0
        while py < y1 do
            local px = x0
            while px < x1 do
                fill(bb, px, py, 1, 1, DOT)
                px = px + p(16)
            end
            py = py + p(16)
        end
        local mid = math.floor((y0 + y1) / 2)
        crosshair(bb, x0 + p(22), mid, p(11), FAINT)
        crosshair(bb, x1 - p(22), mid, p(11), FAINT)
        if x1 - x0 > p(220) then
            ticks(bb, x0 + p(70), x1 - p(70), mid - p(2), p(9), p(3), FAINT)
        end
    end

    --== Cadre extérieur double, équerres aux coins ==
    box(bb, x + p(6), y + p(6), x + W - p(7), y + H - p(7), DIM)
    box(bb, x + p(12), y + p(12), x + W - p(13), y + H - p(13), INK)
    local blong, bthick = p(26), p(3)
    for _, c in ipairs({ { p(12), p(12), 1, 1 }, { W - p(13), p(12), -1, 1 },
                         { p(12), H - p(13), 1, -1 }, { W - p(13), H - p(13), -1, -1 } }) do
        local cx, cyy, sx, sy = x + c[1], y + c[2], c[3], c[4]
        fill(bb, math.min(cx, cx + sx * blong), math.min(cyy, cyy + sy * bthick), blong, bthick, INK)
        fill(bb, math.min(cx, cx + sx * bthick), math.min(cyy, cyy + sy * blong), bthick, blong, INK)
    end

    local L, R = x + p(24), x + W - p(25)

    --== Bandeau : plein, texte en négatif. Toucher = sortir. ==
    local band_top, band_bot = y + p(24), y + p(60)
    fill(bb, L, band_top, R - L + 1, band_bot - band_top + 1, INK)
    wide(bb, L + p(10), y + p(32), "NOSTRUM", f_title, BG, 3, true)
    wide(bb, L + p(190), y + p(38), "ORDINATEUR DE BORD", f_tiny, BG, 1)

    local sortie = "SORTIE"
    local sw = wide_len(sortie, f_small, 2)
    box(bb, R - sw - p(22), y + p(30), R - p(8), y + p(54), BG, 2)
    wide_mid(bb, R - sw - p(22), R - p(8), y + p(36), sortie, f_small, BG, 2, true)

    local clock = os.date("%H:%M")
    local cw = wide_len(clock, f_small, 2)
    wide(bb, R - sw - p(34) - cw, y + p(36), clock, f_small, BG, 2)

    self.close_zone = { top = band_top, bottom = band_bot }

    --== Grille libellé / valeur, façon « COMPUTER READY » ==
    local batt = "--"
    local ok_p, pow = pcall(function() return Device:getPowerDevice():getCapacity() end)
    if ok_p and pow then batt = tostring(pow) end

    local st = upper(self.status)
    local link = (st:find("ROMPUE", 1, true) or st:find("COUPE", 1, true)
        or st:find("INJOIGNABLE", 1, true)) and "ROMPUE" or "ÉTABLIE"
    local place = (self.weather and self.weather.place)
        or upper((self.cfg.weather and self.cfg.weather.name) or "—")

    local gy = y + p(70)
    for _, row in ipairs({
        { "ORDINATEUR", st, "VERSION", VERSION },
        { "HEURE LOCALE", clock, "BATTERIE", batt .. " %" },
        { "POSITION", place, "LIAISON", link },
    }) do
        wide(bb, L, gy, row[1], f_tiny, DIM, 1, false, L + p(105))
        wide(bb, L + p(108), gy, row[2], f_small, INK, 1, true, L + p(296))
        wide(bb, L + p(300), gy, row[3], f_tiny, DIM, 1, false, L + p(405))
        wide(bb, L + p(408), gy, row[4], f_small, INK, 1, true, R)
        gy = gy + p(18)
    end
    -- Bandeau + grille : tout ce que la minute fait bouger (heure, batterie).
    self.clock_zone = Geom:new{ x = x, y = band_top, w = W, h = gy - band_top }

    gy = gy + p(6)
    ticks(bb, L, R, gy, p(7), p(4), FAINT)
    gy = gy + p(16)

    --== Colonne de droite : la signature des écrans de bord ==
    local rail_x = R - p(132)
    local body_r = rail_x - p(14)
    local rail_top = gy + p(10)
    panel(rail_x, rail_top, R, rail_top + p(210), "ÉTAT")

    local ry = rail_top + p(16)
    for _, kv in ipairs({
        { "SYNCHRO", self.last_sync and os.date("%H:%M", self.last_sync) or "--:--" },
        { "SOURCE", self.source or (via_bridge(self.cfg) and "PONT" or "ICLOUD") },
        { "DIRECTIVES", tostring(#self.todos) },
        { "CONTACTS", tostring(#self.events) },
    }) do
        wide(bb, rail_x + p(9), ry, kv[1], f_tiny, DIM, 1, false, R - p(9))
        ry = ry + p(13)
        box(bb, rail_x + p(8), ry, R - p(9), ry + p(20), DIM)
        wide_mid(bb, rail_x + p(8), R - p(9), ry + p(3), kv[2], f_small, INK, 1, true)
        ry = ry + p(28)
    end
    ticks(bb, rail_x + p(9), R - p(9), ry + p(2), p(6), p(3), FAINT)
    ry = ry + p(12)

    -- Jauge de charge : 5 blocs, 20 % chacun. Redondant avec BATTERIE, mais
    -- c'est le seul indicateur qui bouge tout seul.
    local lit = math.floor((tonumber(batt) or 0) / 20 + 0.5)
    for i = 0, 4 do
        local bx = rail_x + p(9) + i * p(22)
        if i < lit then fill(bb, bx, ry, p(16), p(10), INK) end
        box(bb, bx, ry, bx + p(16), ry + p(10), DIM)
    end

    --== ATMOSPHÈRE ==
    local function deg(v)
        return v and (string.format("%d", math.floor(v + 0.5)) .. "°") or "--°"
    end
    local ay = gy + p(10)
    local w = self.weather
    panel(L, ay, body_r, ay + p(78), "ATMOSPHÈRE", place)
    if w then
        wide(bb, L + p(12), ay + p(16), deg(w.temp), f_title, INK, 2, true)
        wide(bb, L + p(78), ay + p(22), upper(w.label or ""), f_body, INK, 1, false, body_r - p(8))
        local detail = "MIN " .. deg(w.tmin) .. "   MAX " .. deg(w.tmax)
        if w.wind then
            detail = detail .. "   VENT " .. string.format("%d", math.floor(w.wind + 0.5)) .. " KM/H"
        end
        wide(bb, L + p(12), ay + p(52), detail, f_small, DIM, 1, false, body_r - p(8))
    else
        wide(bb, L + p(12), ay + p(30), "RELEVÉ INDISPONIBLE", f_body, DIM, 1, false, body_r - p(8))
    end

    -- Vide sous la météo, à gauche du rail : la trame, et par-dessus le
    -- pictogramme du ciel s'il a la place de tenir.
    local vx0, vy0 = L + p(20), ay + p(96)
    local vx1, vy1 = body_r - p(20), rail_top + p(210)
    filler(vx0, vy0, vx1, vy1)
    local kind = w and sky_kind(w.code)
    -- La plus haute des silhouettes (soleil, nuage, puis éclair) s'étend de
    -- -1,36 r à +1,06 r : 2,5 r au total, et un centre décalé vers le haut.
    local gr = math.min(math.floor((vy1 - vy0) / 2.5), math.floor((vx1 - vx0) / 2.6))
    if kind and gr >= p(22) then
        local gcx = math.floor((vx0 + vx1) / 2)
        local gcy = math.floor((vy0 + vy1) / 2 + gr * 0.15)
        -- La trame doit être effacée derrière : les points affleurent la
        -- silhouette et la font baver.
        local clear = math.floor(gr * 1.45)
        fill(bb, gcx - clear, vy0, clear * 2, vy1 - vy0, BG)
        sky_glyph(bb, gcx, gcy, gr, kind, INK, DIM)
    end

    --== ORBITE, pleine largeur sous le rail ==
    -- L'agenda passe avant : le panneau grandit avec le nombre de rendez-vous,
    -- et c'est DIRECTIVES qui cède la place, pas l'inverse.
    local oy = rail_top + p(230)
    local d_bot = y + H - p(80)
    -- Plancher laissé à DIRECTIVES : son titre et une ligne. En dessous le
    -- panneau n'apprend plus rien.
    local o_max = d_bot - p(20) - p(54)
    local shown = #self.events
    while shown > 1 and oy + p(20) + shown * p(30) > o_max do shown = shown - 1 end
    local o_bot = oy + p(20) + math.max(shown, 1) * p(30)

    local sub = date_fr(os.time())
    if #self.events > shown then sub = sub .. " · +" .. (#self.events - shown) end
    panel(L, oy, R, o_bot, "ORBITE", sub)

    if #self.events == 0 then
        wide(bb, L + p(12), oy + p(20), "AUCUN CONTACT PROGRAMMÉ", f_small, DIM, 1, false, R - p(12))
    end
    local ey = oy + p(14)
    -- Cadre cale sur le libelle le plus long : a largeur variable la colonne
    -- des titres ondulerait d'une ligne a l'autre.
    local h_r = L + p(15) + wide_len("00:00-00:00", f_small, 1) + p(5)
    for i = 1, shown do
        local ev = self.events[i]
        box(bb, L + p(10), ey, h_r, ey + p(21), DIM)
        wide_mid(bb, L + p(10), h_r, ey + p(3), slot(ev), f_small, INK, 1, true)
        local label = upper(ev.summary)
        if ev.location and ev.location ~= "" then label = label .. " · " .. upper(ev.location) end
        wide(bb, h_r + p(10), ey + p(3), label, f_small, INK, 1, false, R - p(12))
        ey = ey + p(30)
    end

    --== DIRECTIVES, pleine largeur : la lisibilité prime en bas ==
    local dy = o_bot + p(20)
    local lists = self.cfg.reminder_lists
    local d_sub = upper((lists and lists[1]) or "TOUTES LISTES") .. " · " .. #self.todos
    panel(L, dy, R, d_bot, "DIRECTIVES", d_sub)

    local ty = dy + p(16)
    if #self.todos == 0 then
        wide(bb, L + p(12), ty + p(2), "AUCUNE DIRECTIVE EN ATTENTE", f_body, DIM, 1, false, R - p(12))
        ty = ty + p(30)
    end
    for i, td in ipairs(self.todos) do
        if ty + p(30) > d_bot - p(8) then break end
        local bx, by = L + p(12), ty + p(3)
        box(bb, bx, by, bx + p(17), by + p(17), INK, 2)
        if td.done then fill(bb, bx + p(5), by + p(5), p(8), p(8), INK) end

        local label = upper(td.summary)
        if td.priority > 0 and td.priority <= 4 then label = label .. " !!!"
        elseif td.priority == 5 then label = label .. " !!" end
        local lx, rx = bx + p(28), R - p(12)
        -- Echeance calee a droite, en retrait. En retard elle passe en pleine
        -- encre : c'est le seul etat qui merite d'attirer l'oeil. Le titre est
        -- tronque avant elle, sinon un titre long l'effacerait sans le dire.
        if td.due then
            local txt = os.date("%d/%m", td.due)
            local dw = wide_len(txt, f_small, 1)
            local late = not td.done and td.due < os.time()
            wide(bb, rx - dw, ty + p(2) + ascender(f_body) - ascender(f_small), txt,
                f_small, late and INK or DIM, 1, late)
            rx = rx - dw - p(10)
        end
        local lw = wide(bb, lx, ty + p(2), label, f_body, td.done and DIM or INK, 1, false, rx) - lx
        if td.done then fill(bb, lx, ty + p(12), lw, 1, DIM) end

        self.rows[#self.rows + 1] = { top = ty, bottom = ty + p(30), index = i }
        ty = ty + p(30)
    end

    filler(L + p(20), ty + p(10), R - p(20), d_bot - p(10))

    --== Pied ==
    local fy = y + H - p(66)
    ticks(bb, L, R, fy, p(7), p(4), FAINT)
    box(bb, L, fy + p(12), R, fy + p(40), DIM)

    -- Bascule sombre / clair, calee dans le pied. Le libelle annonce ce que le
    -- toucher donnera, comme SORTIE, pas l'etat courant.
    local theme = self.light and "SOMBRE" or "CLAIR"
    -- Largeur calee sur le libelle le plus long : sinon le bouton se deplace a
    -- chaque bascule et le pied se recompose sous le doigt.
    local thw = wide_len("SOMBRE", f_tiny, 1)
    local th_l, th_r = R - thw - p(16), R - p(4)
    local th_t, th_b = fy + p(14), fy + p(38)
    fill(bb, th_l + 1, th_t + 1, th_r - th_l - 1, th_b - th_t - 1, BG)
    box(bb, th_l, th_t, th_r, th_b, INK)
    wide_mid(bb, th_l, th_r, fy + p(19), theme, f_tiny, INK, 1, true)
    self.theme_zone = { top = th_t, bottom = th_b, left = th_l, right = th_r }

    wide(bb, L + p(12), fy + p(19),
        "TOUCHER = COCHER   ·   BAS = SYNCHRO   ·   HAUT = SORTIE", f_tiny, DIM, 1, false,
        th_l - p(8))
    self.sync_zone = { top = fy }
end

--== Interaction =============================================================

function View:redraw(mode)
    self.flash_count = self.flash_count + 1
    -- Rafraîchissement complet périodique : le blanc-sur-noir fantôme vite en e-ink.
    if mode == "full" or self.flash_count % 5 == 0 then
        self.flash_count = 0
        UIManager:setDirty(self, "full")
    else
        UIManager:setDirty(self, "ui")
    end
end

-- Bascule sombre / clair. Le choix survit a la fermeture : sans ca il faut le
-- refaire a chaque ouverture. G_reader_settings est absent hors KOReader.
function View:toggle_theme()
    self.light = not self.light
    if G_reader_settings then
        G_reader_settings:saveSetting("nostrum_light", self.light)
    end
    -- Inversion complete de l'ecran : en e-ink un rafraichissement partiel
    -- laisserait l'ancien fond en remanence.
    self:redraw("full")
    return true
end

function View:onTap(_, ges)
    local py, px = ges.pos.y, ges.pos.x
    -- Bandeau = fermer. Premier test : sans lui, l'écran est sans issue.
    if self.close_zone and py >= self.close_zone.top and py <= self.close_zone.bottom then
        return self:onClose()
    end
    -- Le bouton de theme est pose dans la bande de synchro : il passe avant.
    local tz = self.theme_zone
    if tz and py >= tz.top and py <= tz.bottom and px >= tz.left and px <= tz.right then
        return self:toggle_theme()
    end
    -- Bas de l'écran = resynchroniser.
    if py >= (self.sync_zone and self.sync_zone.top or self.dimen.h - 66) then
        self:sync()
        return true
    end
    for _, row in ipairs(self.rows) do
        if py >= row.top and py < row.bottom then
            self:toggle(self.todos[row.index])
            return true
        end
    end
    return true
end

function View:onSwipe(_, ges)
    if ges.direction == "east" then return self:onClose() end
    return true
end

function View:toggle(todo)
    if not todo then return end
    local target = not todo.done
    -- Optimiste : on peint tout de suite, on corrige si le serveur refuse.
    todo.done = target
    self.status = "ÉCRITURE..."
    self:redraw()

    UIManager:nextTick(function()
        ensure_network(function()
            local ok, err
            if via_bridge(self.cfg) then
                ok, err = Bridge.set_done(self.cfg, todo, target)
            else
                ok, err = CalDAV.set_done(self.cfg, todo, target)
            end
            if ok then
                self.status = "ÉCRITURE OK"
            else
                todo.done = not target
                self.status = "ÉCHEC ÉCRITURE"
                logger.warn("nostrum: set_done:", err)
                UIManager:show(InfoMessage:new{ text = _("Echec: ") .. tostring(err) })
            end
            self:redraw()
        end)
    end)
end

function View:sync(attempt)
    self.status = "SYNCHRONISATION..."
    self:redraw()
    UIManager:nextTick(function()
        ensure_network(function() self:fetch(attempt or 1) end)
    end)
end

-- Écrit la trace brute de la découverte à côté du plugin. Transcrire du XML à la
-- main depuis l'écran du Kindle est ingérable ; le fichier se lit par USB.
-- Ne contient aucun identifiant : les en-têtes ne sont jamais enregistrés.
local function dump_trace()
    if not here then return nil end
    local path = here .. "/debug.txt"
    local f = io.open(path, "w")
    if not f then return nil end
    f:write("NOSTRUM — trace de decouverte CalDAV\n", os.date(), "\n")
    f:write("Aucun identifiant dans ce fichier.\n\n")
    for i, t in ipairs(CalDAV.trace or {}) do
        local body = t.body or ""
        f:write(string.format("[%d] %s\n  url    : %s\n  code   : %s\n  taille : %d octets\n  corps  :\n%s\n\n",
            i, t.step, tostring(t.url), tostring(t.code), #body,
            body == "" and "(vide)" or body))
    end
    if #(CalDAV.trace or {}) == 0 then f:write("(aucune requete enregistree)\n") end
    f:close()
    return path
end

-- Les noms iCloud portent parfois un espace final invisible (« Organisation
-- Generale ») : une comparaison stricte vide alors l'agenda sans rien signaler.
local function trim(s)
    return type(s) == "string" and s:match("^%s*(.-)%s*$") or s
end

local function wanted(list, name)
    if not list or #list == 0 then return true end
    name = trim(name)
    for _, n in ipairs(list) do if trim(n) == name then return true end end
    return false
end

--== Choix des calendriers et des listes ====================================
--
-- config.lua demande un cable ou une mise a jour par le pont pour changer une
-- virgule. Le choix des sources, lui, bouge souvent : il vit donc dans les
-- reglages de KOReader, modifiables depuis l'appareil, et prime sur config.lua.
--
-- Les noms proposes sont ceux vus a la derniere synchro, memorises pour que le
-- menu se construise sans reseau et sans que Nostrum soit ouvert.
local function setting(key)
    if not G_reader_settings then return nil end
    local v = G_reader_settings:readSetting(key)
    return type(v) == "table" and v or nil
end

local function remember(kind, names)
    if G_reader_settings then G_reader_settings:saveSetting("nostrum_seen_" .. kind, names) end
end

-- Bascule un nom. « Rien de coche » veut dire « tout afficher », ici comme dans
-- config.lua : decocher le premier nom doit donc materialiser la liste complete
-- moins celui-la, sinon le reglage resterait vide et le clic serait sans effet.
-- Et tout decocher revient a tout afficher, plutot qu'a un ecran vide.
local function toggle_pick(kind, name)
    if not G_reader_settings then return end
    local seen = setting("nostrum_seen_" .. kind) or {}
    local cur = setting("nostrum_pick_" .. kind)
    local out = {}
    if not cur or #cur == 0 then
        for _, n in ipairs(seen) do
            if trim(n) ~= trim(name) then out[#out + 1] = n end
        end
    else
        local found = false
        for _, n in ipairs(cur) do
            if trim(n) == trim(name) then found = true else out[#out + 1] = n end
        end
        if not found then out[#out + 1] = name end
        -- Tout coche = aucun filtre : on ecrit vide plutot qu'une liste qui se
        -- perimerait des qu'un calendrier apparait cote iCloud.
        if #out == #seen then out = {} end
    end
    G_reader_settings:saveSetting("nostrum_pick_" .. kind, out)
end

function View:fetch(attempt)
    attempt = attempt or 1
    local cfg = self.cfg

    -- Le pont fait autorite des qu'il dicte quelque chose : c'est le seul
    -- endroit ou les deux colonnes se voient cote a cote. Son choix est recopie
    -- dans les reglages de l'appareil, pour que le menu du Kindle montre ce qui
    -- s'applique vraiment et serve encore quand le Mac est eteint.
    -- Rien de coche cote pont = aucun filtre impose, le reglage local garde la main.
    --
    -- C'est aussi la premiere requete au pont : injoignable ici, il l'est pour
    -- toute la synchro. On ne le redemande pas pour l'agenda et les taches —
    -- chaque essai coute un delai d'attente, ecran fige.
    local bridge_down
    if via_bridge(cfg) then
        local pref, perr = Bridge.prefs(cfg)
        if not pref and is_transport_error(perr) then bridge_down = tostring(perr) end
        for kind, names in pairs(pref or {}) do
            if #names > 0 and G_reader_settings then
                G_reader_settings:saveSetting("nostrum_pick_" .. kind, names)
                if kind == "calendars" then cfg.calendars = names else cfg.reminder_lists = names end
            end
        end
    end

    -- Agenda : le pont d'abord, qui voit tous les calendriers du Mac (iCloud,
    -- Google, Exchange). Mac eteint et identifiants iCloud fournis : lecture
    -- directe sur iCloud, sans le Mac. Une panne se traite pareil dans les deux
    -- cas — relance si le wifi s'eveille, sinon on garde l'ecran precedent.
    local by_bridge = via_bridge(cfg) and not bridge_down
    local colls, err, b_events, b_cals
    if by_bridge then
        b_events, err, b_cals = Bridge.events(cfg)
        colls = b_events and {}
    else
        err = bridge_down
    end
    -- Secours iCloud : seulement si le pont est hors d'atteinte. Un jeton
    -- refuse n'est pas une panne, iCloud ne ferait que la masquer.
    local fallback = via_bridge(cfg) and not colls and is_transport_error(err) and has_icloud(cfg)
    if not via_bridge(cfg) or fallback then
        colls, err = CalDAV.discover(cfg)
        by_bridge = false
    end
    if not colls then
        logger.warn("nostrum: agenda (essai " .. attempt .. "):", err)

        -- Le WiFi met quelques secondes à obtenir une IP après l'association :
        -- la première requête part souvent trop tôt. Une relance suffit.
        if is_transport_error(err) and attempt < 3 and not wifi_is_off() then
            self.status = "LIAISON... ESSAI " .. (attempt + 1) .. "/3"
            self:redraw()
            self.retry = function() self:sync(attempt + 1) end
            UIManager:scheduleIn(5, self.retry)
            return
        end

        if wifi_is_off() then
            self.status = "WIFI COUPÉ"
            UIManager:show(InfoMessage:new{ text = _("Wi-Fi désactivé sur le Kindle.") })
        elseif via_bridge(cfg) and not fallback then
            self.status = "PONT INJOIGNABLE"
            UIManager:show(InfoMessage:new{ text = _("Pont Nostrum : ") .. tostring(err) .. "\n\n"
                .. _("Vérifier que le Mac est allumé, sur le même réseau, et que l'app Nostrum tourne.") })
        else
            self.status = "LIAISON ROMPUE"
            local dump = dump_trace()
            local msg = _("CalDAV: ") .. tostring(err)
            if dump then msg = msg .. "\n\n" .. _("Trace brute ecrite dans :") .. "\n" .. dump end
            UIManager:show(InfoMessage:new{ text = msg })
        end
        self:redraw("full")
        return
    end

    -- Journée en cours, bornes locales.
    local now = os.time()
    local d = os.date("*t", now)
    d.hour, d.min, d.sec = 0, 0, 0
    local day_start = os.time(d)
    local day_end = day_start + 86400 * (cfg.days or 1)

    local events, todos, problems = {}, {}, {}
    -- Ce que le compte expose, filtre compris : c'est ce que le menu propose.
    local seen_cal, seen_lists = {}, {}

    -- iCloud ne publie pas les listes de Rappels en CalDAV : quand un pont Mac
    -- est configuré, il remplace entièrement cette source.
    local use_bridge = via_bridge(cfg)
    if by_bridge then
        events, seen_cal = b_events, b_cals or {}
    end
    self.source = by_bridge and "PONT" or "ICLOUD"

    for _, coll in ipairs(colls) do
        if coll.events then seen_cal[#seen_cal + 1] = coll.name end
        if coll.todos and not use_bridge then seen_lists[#seen_lists + 1] = coll.name end
        if coll.events and wanted(cfg.calendars, coll.name) then
            local list, e = CalDAV.events(cfg, coll, day_start, day_end)
            if list then
                for _, ev in ipairs(list) do events[#events + 1] = ev end
            else
                problems[#problems + 1] = tostring(e)
            end
        end
        if not use_bridge and coll.todos and wanted(cfg.reminder_lists, coll.name) then
            local list, e = CalDAV.todos(cfg, coll)
            if list then
                for _, td in ipairs(list) do todos[#todos + 1] = td end
            else
                problems[#problems + 1] = tostring(e)
            end
        end
    end

    local bridge_err = use_bridge and bridge_down or nil
    if use_bridge and not bridge_down then
        local list, e, names = Bridge.todos(cfg)
        if list then
            todos = list
            seen_lists = names or seen_lists
        else
            bridge_err = tostring(e)
        end
    end
    -- Mac injoignable : les taches deja affichees restent, plutot qu'un
    -- ecran vide. Le statut dit qu'elles ne sont plus a jour.
    if bridge_err then
        problems[#problems + 1] = bridge_err
        todos = self.todos or {}
    end

    if ok_weather then
        local w, we = Weather.fetch(cfg)
        if w then
            self.weather = w
        elseif we then
            problems[#problems + 1] = tostring(we)
        end
    end

    events = prune_events(events, day_start, day_end)

    table.sort(events, function(a, b)
        if a.allday ~= b.allday then return a.allday end
        return (a.start or 0) < (b.start or 0)
    end)
    table.sort(todos, function(a, b)
        local pa = a.priority == 0 and 9 or a.priority
        local pb = b.priority == 0 and 9 or b.priority
        if pa ~= pb then return pa < pb end
        return (a.due or math.huge) < (b.due or math.huge)
    end)

    -- En secours iCloud, seuls les calendriers iCloud sont vus : le menu garde
    -- la liste complete apprise du Mac. Pareil pour les listes, invisibles.
    if not fallback then
        table.sort(seen_cal)
        remember("calendars", seen_cal)
        remember("lists", seen_lists)
    end

    self.events, self.todos, self.last_sync = events, todos, os.time()
    self.status = #problems > 0 and ("PARTIEL (" .. #problems .. " ERR)") or "LIAISON OK"
    if #problems > 0 then logger.warn("nostrum:", table.concat(problems, " | ")) end

    -- Aucune tâche remontée : distinguer les trois causes, sinon le diagnostic
    -- se fait à l'aveugle. Le nom d'une liste demandée mais absente est la cause
    -- la plus fréquente : iCloud n'expose pas toutes les listes Rappels.
    if fallback then
        -- Agenda frais (iCloud, voir SOURCE), taches d'avant : le statut le dit.
        self.status = "MAC ÉTEINT"
        logger.warn("nostrum: pont injoignable, agenda lu sur iCloud:", bridge_err)

    elseif bridge_err then
        self.status = "PONT INJOIGNABLE"
        logger.warn("nostrum: pont:", bridge_err)

    elseif #todos == 0 and use_bridge then
        self.status = "PONT SANS TÂCHE"
        logger.warn("nostrum: pont: aucune tache ouverte")

    elseif #todos == 0 then
        local exposed = {}
        for _, c in ipairs(colls) do
            if c.todos then exposed[#exposed + 1] = c.name end
        end
        if #exposed == 0 then
            self.status = "AUCUNE LISTE VTODO"
            problems[#problems + 1] = "aucune collection VTODO exposee par iCloud"
        else
            local missing = {}
            for _, name in ipairs(self.cfg.reminder_lists or {}) do
                if not wanted(exposed, name) then missing[#missing + 1] = name end
            end
            if #missing > 0 then
                self.status = "LISTE INTROUVABLE"
                problems[#problems + 1] = "listes demandees absentes: "
                    .. table.concat(missing, ", ")
                    .. " | exposees par iCloud: " .. table.concat(exposed, ", ")
            else
                -- Collection exposée mais sans aucune ressource : le cas iCloud,
                -- où la liste CalDAV est une coquille et le contenu vit dans
                -- CloudKit. Le dire, plutôt qu'afficher LIAISON OK sur du vide.
                self.status = "RAPPELS VIDES"
                problems[#problems + 1] = "listes trouvees ("
                    .. table.concat(exposed, ", ") .. ") mais 0 tache retournee"
            end
        end
        logger.warn("nostrum:", problems[#problems])
        dump_trace()
    end

    self:redraw("full")
    self:schedule()
    -- Apres l'affichage : la question ne doit pas retarder l'ecran.
    if use_bridge and not bridge_err then self:propose_update() end
end

function View:stopTimers()
    if self.tick then UIManager:unschedule(self.tick) end
    if self.retry then UIManager:unschedule(self.retry) end
    if self.clock_tick then UIManager:unschedule(self.clock_tick) end
end

-- Horloge. L'ecran n'est repeint qu'a la synchro ou sur un toucher : sans ce
-- minuteur, l'heure affichee restait celle de la derniere synchro. Cale sur le
-- changement de minute, et seulement le haut de l'ecran : un rafraichissement
-- partiel clignote moins en e-ink et n'entre pas dans le compte des plein
-- ecran de redraw().
function View:start_clock()
    if self.clock_tick then UIManager:unschedule(self.clock_tick) end
    self.clock_tick = function()
        if self.clock_zone then UIManager:setDirty(self, "ui", self.clock_zone) end
        self:start_clock()
    end
    UIManager:scheduleIn(math.max(1, 60 - tonumber(os.date("%S"))), self.clock_tick)
end

function View:schedule()
    if self.tick then UIManager:unschedule(self.tick) end
    local mins = self.cfg.refresh_minutes or 60
    self.tick = function() self:sync() end
    UIManager:scheduleIn(mins * 60, self.tick)
end

-- Le compteur de UIManager se fige pendant la veille du Kindle : la synchro
-- periodique reprend la ou elle s'etait arretee et l'ecran affiche encore
-- l'agenda d'avant le sommeil. Le reveil resynchronise donc de lui-meme.
-- Le reseau est laisse a KOReader : sync() passe par ensure_network, qui suit
-- les reglages « restaurer le wifi au reveil » de l'appareil.
-- Pas de valeur de retour : l'evenement est diffuse a toute la pile.
function View:onResume()
    -- Le minuteur de l'horloge s'est fige lui aussi : on le recale.
    self:start_clock()
    -- Deux appuis sur le bouton veille ne doivent pas synchroniser deux fois.
    if self.last_sync and os.time() - self.last_sync < 60 then return end
    self:sync()
end

function View:onClose()
    self:stopTimers()
    UIManager:close(self)
    return true
end
View.onCloseWidget = function(self) self:stopTimers() end

--== Mise a jour par le pont =================================================

-- Le pont sert ses propres sources : plus besoin du cable pour deployer.
--
-- Tout est telecharge et verifie AVANT qu'un seul fichier ne soit remplace.
-- Un plugin a moitie remplace ne se charge plus, et il n'y a alors plus
-- d'entree de menu pour reessayer : le cable redevient la seule issue.
-- `dir` est un parametre pour que le controle de render.lua travaille dans un
-- dossier jetable plutot que sur l'installation en cours.
local compile = loadstring or load

-- Archives : une copie de la version en place avant chaque remplacement, dans
-- `plugins/nostrum-archives/<version>/`. A cote du plugin et non dedans, sinon
-- la mise a jour suivante les emporterait ; KOReader ignore ce dossier, il ne
-- charge que les `.koplugin`. config.lua n'y est jamais copie : il ne bouge pas
-- lors d'une mise a jour et contient les identifiants.
local function archives_root(dir) return dir .. "/../nostrum-archives" end

local function read_file(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local body = fh:read("*a")
    fh:close()
    return body
end

local function write_file(path, body)
    local fh = io.open(path, "wb")
    if not fh then return false end
    fh:write(body)
    fh:close()
    return true
end

local function archive(dir, version, files)
    local target = archives_root(dir) .. "/" .. version
    os.execute('mkdir -p "' .. target .. '"')
    local n = 0
    for _, f in ipairs(files) do
        local body = f.name ~= "config.lua" and read_file(dir .. "/" .. f.name)
        if body and write_file(target .. "/" .. f.name, body) then n = n + 1 end
    end
    return n
end

-- ponytail: `ls` plutot que lfs — un dossier d'archives tient en dix lignes et
-- le controle de render.lua tourne alors tel quel hors appareil.
local function list_dir(path)
    local pipe = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
    if not pipe then return {} end
    local out = {}
    for name in pipe:lines() do out[#out + 1] = name end
    pipe:close()
    return out
end

-- Les versions archivees, la plus recente d'abord.
local function archived_versions(dir)
    local out = list_dir(archives_root(dir))
    table.sort(out, function(a, b) return a > b end)
    return out
end

-- Meme prudence que la mise a jour : tout est lu et verifie avant qu'un seul
-- fichier ne bouge, et le remplacement se fait par .new + os.rename.
local function restore_archive(version, dir)
    dir = dir or here
    if not dir then return nil, "dossier du plugin introuvable" end
    local src = archives_root(dir) .. "/" .. version

    local staged = {}
    for _, name in ipairs(list_dir(src)) do
        if name:match("%.lua$") or name:match("%.md$") then
            staged[#staged + 1] = { name = name, body = read_file(src .. "/" .. name) }
        end
    end
    if #staged == 0 then return nil, "archive " .. version .. " vide" end
    for _, f in ipairs(staged) do
        if not f.body then return nil, f.name .. " : lecture impossible" end
        if f.name:match("%.lua$") and not compile(f.body, f.name) then
            return nil, f.name .. " : syntaxe invalide"
        end
    end

    for _, f in ipairs(staged) do
        if not write_file(dir .. "/" .. f.name .. ".new", f.body) then
            return nil, f.name .. " : ecriture impossible"
        end
    end
    for _, f in ipairs(staged) do
        os.rename(dir .. "/" .. f.name .. ".new", dir .. "/" .. f.name)
    end
    return version, #staged
end

local function update_from_bridge(cfg, dir)
    if not ok_bridge then return nil, "module pont absent" end
    dir = dir or here
    if not dir then return nil, "dossier du plugin introuvable" end

    local man, err = Bridge.manifest(cfg)
    if not man then return nil, err end

    local staged = {}
    for _, f in ipairs(man.files or {}) do
        local body, e = Bridge.file(cfg, f.name)
        if not body then return nil, f.name .. " : " .. tostring(e) end
        -- Taille annoncee contre taille recue : c'est ce qui attrape une
        -- coupure de wifi en cours de transfert, la panne la plus probable ici.
        if f.size and #body ~= f.size then
            return nil, f.name .. " : " .. #body .. " octets sur " .. f.size
        end
        if f.name:match("%.lua$") and not compile(body, f.name) then
            return nil, f.name .. " : syntaxe invalide"
        end
        staged[#staged + 1] = { name = f.name, body = body }
    end
    if #staged == 0 then return nil, "le pont ne sert aucun fichier" end

    -- La version en place est archivee juste avant d'etre touchee : une mise a
    -- jour ratee se defait alors depuis le menu, sans cable.
    archive(dir, VERSION, staged)

    -- Les .new d'abord, les renommages ensuite : os.rename est atomique, la
    -- fenetre pendant laquelle le dossier est incoherent se reduit a rien.
    for _, f in ipairs(staged) do
        if not write_file(dir .. "/" .. f.name .. ".new", f.body) then
            return nil, f.name .. " : ecriture impossible"
        end
    end
    for _, f in ipairs(staged) do
        os.rename(dir .. "/" .. f.name .. ".new", dir .. "/" .. f.name)
    end
    return man.version or "?", #staged
end

-- Installation depuis le pont, avec un message pendant le transfert : les
-- requetes sont bloquantes, sans lui l'appareil parait fige. Partagee par le
-- menu et par la proposition faite a la synchro.
-- `dir` : dossier jetable des controles de render.lua, jamais sur l'appareil.
local function install_update(cfg, dir)
    local info = InfoMessage:new{ text = _("Mise à jour depuis le pont...") }
    UIManager:show(info)
    UIManager:nextTick(function()
        ensure_network(function()
            local version, detail = update_from_bridge(cfg, dir)
            UIManager:close(info)
            if not version then
                UIManager:show(InfoMessage:new{
                    text = _("Mise à jour impossible :") .. "\n" .. tostring(detail) })
                return
            end
            local msg = string.format(
                _("Version %s installée (%d fichiers).\nRedémarrer KOReader pour l'activer."), version, detail)
            if UIManager.askForRestart then
                UIManager:askForRestart(msg)
            else
                UIManager:show(InfoMessage:new{ text = msg })
            end
        end)
    end)
end

-- Le Kindle suit la version du Mac, qui embarque le plugin : quand le pont sert
-- une autre version que celle-ci, on propose de l'installer. Une seule fois
-- par version et par session, sinon chaque synchro reposerait la question.
local offered

function View:propose_update(dir)
    if not via_bridge(self.cfg) then return end
    local man = Bridge.manifest(self.cfg)
    if not man or not man.version or man.version == VERSION or offered == man.version then return end
    offered = man.version
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Le Mac propose Nostrum %s (version installée : %s).\nMettre à jour maintenant ?"),
            man.version, VERSION),
        ok_text = _("Mettre à jour"),
        cancel_text = _("Plus tard"),
        ok_callback = function() install_update(self.cfg, dir) end,
    })
end

--== Plugin ==================================================================

local Nostrum = WidgetContainer:extend{
    name = "nostrum",
    is_doc_only = false,
    -- Exposé pour render.lua, qui peint l'écran hors appareil : la mise en page
    -- se vérifie sur une image, pas en rebranchant le Kindle à chaque essai.
    View = View,
    prune_events = prune_events,
    slot = slot,
    VERSION = VERSION,
    sky_kind = sky_kind,
}

function Nostrum:init()
    self.ui.menu:registerToMainMenu(self)
end

function Nostrum:loadConfig()
    local path = (self.path or ".") .. "/config.lua"
    local chunk, err = loadfile(path)
    if not chunk then return nil, "config.lua absent ou invalide (" .. tostring(err) .. ")" end
    local ok, cfg = pcall(chunk)
    if not ok or type(cfg) ~= "table" then return nil, "config.lua ne renvoie pas une table" end
    if not cfg.bridge_token and not (cfg.username and cfg.password) then
        return nil, "config.lua : ni jeton du pont, ni identifiants iCloud. Réinstaller depuis l'app Nostrum du Mac."
    end
    -- Le reglage de l'appareil l'emporte : c'est le seul des deux qui se change
    -- sans cable. Absent, config.lua garde la main.
    cfg.calendars = setting("nostrum_pick_calendars") or cfg.calendars
    cfg.reminder_lists = setting("nostrum_pick_lists") or cfg.reminder_lists
    return cfg
end

-- Un sous-menu a cases par source. Construit a l'ouverture (sub_item_table_func)
-- et non une fois pour toutes : la liste des calendriers change au gre d'iCloud,
-- et surtout elle est vide tant que rien n'a ete synchronise.
local function pick_menu(kind, title)
    return {
        text_func = function()
            local seen, pick = setting("nostrum_seen_" .. kind), setting("nostrum_pick_" .. kind)
            if not seen or #seen == 0 then return title end
            local n = (not pick or #pick == 0) and #seen or #pick
            return title .. string.format(" (%d/%d)", n, #seen)
        end,
        sub_item_table_func = function()
            local seen = setting("nostrum_seen_" .. kind) or {}
            if #seen == 0 then
                return { {
                    text = _("Synchroniser une fois pour voir les sources"),
                    enabled_func = function() return false end,
                } }
            end
            local items = {}
            for _, name in ipairs(seen) do
                items[#items + 1] = {
                    text = name,
                    checked_func = function() return wanted(setting("nostrum_pick_" .. kind), name) end,
                    callback = function() toggle_pick(kind, name) end,
                    keep_menu_open = true,
                }
            end
            return items
        end,
    }
end

function Nostrum:addToMainMenu(menu_items)
    menu_items.nostrum = {
        text = _("Nostrum — agenda & tâches"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Ouvrir"),
                callback = function() self:open() end,
            },
            pick_menu("calendars", _("Calendriers")),
            pick_menu("lists", _("Listes de rappels")),
            {
                text = _("Mettre à jour depuis le pont"),
                callback = function() self:update() end,
            },
            {
                text = _("Restaurer une version archivée"),
                sub_item_table_func = function()
                    local versions = here and archived_versions(here) or {}
                    if #versions == 0 then
                        return { {
                            text = _("Aucune archive : elles sont créées à la mise à jour"),
                            enabled_func = function() return false end,
                        } }
                    end
                    local items = {}
                    for _, v in ipairs(versions) do
                        items[#items + 1] = {
                            text = v,
                            keep_menu_open = true,
                            callback = function() self:restore(v) end,
                        }
                    end
                    return items
                end,
            },
            {
                text_func = function() return _("Version installée : ") .. VERSION end,
                enabled_func = function() return false end,
            },
        },
    }
end

function Nostrum:update()
    local cfg, err = self:loadConfig()
    if not cfg then
        UIManager:show(InfoMessage:new{ text = _("Nostrum: ") .. err })
        return
    end
    install_update(cfg)
end

function Nostrum:restore(version)
    local version_ok, detail = restore_archive(version)
    if not version_ok then
        UIManager:show(InfoMessage:new{
            text = _("Restauration impossible :") .. "\n" .. tostring(detail) })
        return
    end
    UIManager:show(InfoMessage:new{ text = string.format(
        _("Version %s restaurée (%d fichiers).\nRedémarrer KOReader pour l'activer."),
        version_ok, detail) })
end

function Nostrum:open()
    local cfg, err = self:loadConfig()
    if not cfg then
        UIManager:show(InfoMessage:new{ text = _("Nostrum: ") .. err })
        return
    end
    local view = View:new{
        cfg = cfg,
        light = G_reader_settings and G_reader_settings:isTrue("nostrum_light") or false,
    }
    UIManager:show(view)
    view:start_clock()
    view:sync()
end

-- Exposé pour l'auto-contrôle de render.lua ; sans usage sur l'appareil.
Nostrum._wanted = wanted
Nostrum._update = update_from_bridge
Nostrum._restore = restore_archive
Nostrum._archived = archived_versions
Nostrum._toggle_pick = toggle_pick

return Nostrum
