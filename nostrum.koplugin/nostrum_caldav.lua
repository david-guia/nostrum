--[[
Client CalDAV minimal pour iCloud.
Découverte principal -> calendar-home-set -> collections, puis REPORT calendar-query.
Les occurrences récurrentes sont dépliées par le serveur (<C:expand>) : zéro code RRULE ici.
]]

-- Requires tolérants : le module doit rester chargeable hors KOReader pour que
-- test.lua puisse exercer le parsing XML, qui est la partie qui casse en silence.
-- L'absence de luasocket est signalée à l'usage, dans request().
local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")
local ok_ltn12, ltn12 = pcall(require, "ltn12")
local ok_mime, mime = pcall(require, "mime")
local ICS = require("nostrum_ics")

local HAS_NET = ok_http and ok_https and ok_ltn12 and ok_mime

-- socketutil n'existe que dans KOReader ; absent en test hors appareil.
local ok_su, socketutil = pcall(require, "socketutil")

local CalDAV = {}

local UA = "Nostrum/1.0 (KOReader; Kindle)"

--== XML : extraction par motifs =============================================
-- ponytail: pas de vrai parseur XML. Plafond : casse si un serveur imbrique
-- <response> dans <response>. iCloud ne le fait pas. Si un jour ça arrive,
-- passer sur luaxml (déjà livré avec KOReader).

local function strip_ns(xml)
    return (xml:gsub("<(/?)%s*[%w_%-]+:", "<%1"))
end

local function unent(s)
    s = s:gsub("&#x(%x+);", function(h) return string.char(tonumber(h, 16) % 256) end)
    s = s:gsub("&#(%d+);", function(d) return string.char(tonumber(d) % 256) end)
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
    return (s:gsub("&amp;", "&"))
end

-- Contenu d'un élément, attributs tolérés. Apple émet régulièrement
-- <supported-calendar-component-set xmlns:C="...">, qu'un motif sans attributs rate.
local function element(xml, name)
    return xml:match("<" .. name .. "[^>]*>(.-)</" .. name .. ">")
end

local function tag(xml, name)
    local v = xml:match("<" .. name .. "[^>]*>(.-)</" .. name .. ">")
    return v and unent(v) or nil
end

-- Attributs obligatoirement tolérés : iCloud répète le namespace sur chaque
-- élément, y compris <response xmlns="DAV:">.
local function responses(xml)
    return strip_ns(xml):gmatch("<response[^>]*>(.-)</response>")
end

-- iCloud écrit <comp name='VEVENT'/> en guillemets simples ; d'autres serveurs
-- utilisent des doubles. Les deux sont valides en XML.
local function declares_comp(comps, name)
    return comps:find("name=['\"]" .. name) ~= nil
end

-- Extrait le <href> d'une propriété DAV dans tout le document.
-- Les propstat 404 renvoient la propriété sous forme d'élément vide
-- (<current-user-principal/>) : on les retire d'abord, sinon on croit l'avoir
-- trouvée alors qu'elle est vide.
function CalDAV.prop_href(xml, prop)
    local doc = strip_ns(xml or ""):gsub("<" .. prop .. "[^>]*/>", "")
    local block = doc:match("<" .. prop .. "[^>]*>(.-)</" .. prop .. ">")
    local href = block and block:match("<href[^>]*>(.-)</href>")
    if href and href:match("%S") then return unent(href) end
    return nil
end

--== HTTP ====================================================================

-- Résolution d'URL, limitée aux trois cas que produit CalDAV : absolue,
-- chemin absolu, ou relative. Écrit à la main plutôt que via socket.url pour que
-- le parsing reste testable hors appareil.
local function abs_url(base, href)
    if href:match("^https?://") then return href end
    local scheme, host, path = tostring(base):match("^(https?://)([^/]+)(.*)$")
    if not scheme then return href end
    if href:sub(1, 1) == "/" then return scheme .. host .. href end
    return scheme .. host .. (path:match("^(.*/)") or "/") .. href
end
CalDAV.abs_url = abs_url

function CalDAV.hasNetwork() return HAS_NET end

-- Renvoie body, code, headers, err
function CalDAV.request(cfg, opts)
    if not HAS_NET then return nil, nil, nil, "luasocket/luasec indisponible" end
    local target = opts.url
    local method = opts.method or "GET"
    local body = opts.body

    for _ = 1, 5 do
        local sink = {}
        local headers = {
            ["Authorization"] = "Basic " .. mime.b64(cfg.username .. ":" .. cfg.password),
            ["User-Agent"] = UA,
            ["Content-Length"] = tostring(#(body or "")),
        }
        for k, v in pairs(opts.headers or {}) do headers[k] = v end

        if ok_su then socketutil:set_timeout(15, 60) end
        local requester = target:match("^https://") and https.request or http.request
        local _, code, rheaders = requester({
            url = target,
            method = method,
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = ltn12.sink.table(sink),
            protocol = "any",
            options = "all",
            verify = "none",
        })
        if ok_su then socketutil:reset_timeout() end

        if type(code) ~= "number" then
            return nil, nil, nil, "reseau: " .. tostring(code)
        end

        -- iCloud redirige vers la partition pNN-caldav.icloud.com : même méthode, même corps.
        if code == 301 or code == 302 or code == 307 or code == 308 then
            local loc = rheaders and (rheaders.location or rheaders.Location)
            if not loc then return nil, code, rheaders, "redirection sans Location" end
            target = abs_url(target, loc)
        else
            return table.concat(sink), code, rheaders, nil, target
        end
    end
    return nil, nil, nil, "trop de redirections"
end

-- iCloud explique ses refus dans le corps de la réponse (<error><need-privileges/>...).
-- Sans ça un 403 reste indéchiffrable.
local function snippet(body)
    if not body or body == "" then return "" end
    local s = body:gsub("<%?xml[^>]*%?>", ""):gsub("%s+", " "):gsub("^ ", "")
    if s == "" then return "" end
    return " — " .. s:sub(1, 160)
end

-- Trace de la découverte, pour dump sur disque en cas d'échec.
-- N'enregistre que méthode/url/code/corps : jamais les en-têtes, qui portent
-- l'Authorization.
CalDAV.trace = {}

local function record(step, url, code, body)
    CalDAV.trace[#CalDAV.trace + 1] = {
        step = step, url = url, code = code, body = body,
    }
end

local function propfind(cfg, target, depth, body)
    return CalDAV.request(cfg, {
        url = target,
        method = "PROPFIND",
        body = body,
        headers = { ["Depth"] = tostring(depth), ["Content-Type"] = 'application/xml; charset="utf-8"' },
    })
end

--== Découverte ==============================================================

local PROP_PRINCIPAL = [[<?xml version="1.0" encoding="utf-8"?>
<propfind xmlns="DAV:"><prop><current-user-principal/></prop></propfind>]]

local PROP_HOME = [[<?xml version="1.0" encoding="utf-8"?>
<propfind xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
<prop><C:calendar-home-set/></prop></propfind>]]

local PROP_COLLECTIONS = [[<?xml version="1.0" encoding="utf-8"?>
<propfind xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
<prop><displayname/><resourcetype/><C:supported-calendar-component-set/></prop></propfind>]]

-- Renvoie la liste des collections : { url, name, events=bool, todos=bool }
function CalDAV.discover(cfg)
    CalDAV.trace = {}
    local root = cfg.server or "https://caldav.icloud.com/"

    -- Certains comptes iCloud refusent le PROPFIND à la racine (403) mais répondent
    -- sur le chemin de découverte normalisé (RFC 6764). On tente les deux.
    local candidates = { root, (root:gsub("/+$", "")) .. "/.well-known/caldav" }

    -- Un 207 ne veut pas dire que la propriété est là : quand le serveur ne la
    -- connaît pas à ce chemin, il répond 207 avec un propstat 404 et un élément
    -- vide <current-user-principal/>. Il faut donc chercher le href, pas le code.
    local principal, final, last_err
    for _, candidate in ipairs(candidates) do
        local body, code, _, err, redirected = propfind(cfg, candidate, 0, PROP_PRINCIPAL)
        record("PROPFIND principal", redirected or candidate, code, body)
        if err then return nil, err end
        if code == 401 then
            return nil, "identifiants refuses : utiliser un mot de passe d'application, "
                     .. "et l'Apple ID principal (pas un alias)"
        end
        if code == 207 then
            local href = CalDAV.prop_href(body, "current%-user%-principal")
                      or CalDAV.prop_href(body, "principal%-URL")
            if href then
                final = redirected or candidate
                principal = abs_url(final, href)
                break
            end
            last_err = "principal absent de la reponse 207" .. snippet(body)
        else
            last_err = "principal: HTTP " .. tostring(code) .. snippet(body)
        end
    end
    if not principal then return nil, last_err or "principal introuvable" end

    local xml, code, err, _
    xml, code, _, err, final = propfind(cfg, principal, 0, PROP_HOME)
    record("PROPFIND calendar-home-set", final or principal, code, xml)
    if err then return nil, err end
    if code ~= 207 then return nil, "calendar-home-set: HTTP " .. tostring(code) .. snippet(xml) end

    local home = CalDAV.prop_href(xml, "calendar%-home%-set")
    if not home then return nil, "calendar-home-set absent" .. snippet(xml) end
    home = abs_url(final or principal, home)

    xml, code, _, err, final = propfind(cfg, home, 1, PROP_COLLECTIONS)
    record("PROPFIND collections (Depth 1)", final or home, code, xml)
    if err then return nil, err end
    if code ~= 207 then return nil, "collections: HTTP " .. tostring(code) .. snippet(xml) end

    local out, seen = CalDAV.parse_collections(xml, final or home)
    if #out == 0 then
        return nil, "aucun calendrier parmi " .. seen .. " ressources" .. snippet(xml)
    end
    return out
end

-- Renvoie la liste des collections et le nombre de ressources examinées.
function CalDAV.parse_collections(xml, base)
    local out, seen = {}, 0
    for resp in responses(xml) do
        local href = tag(resp, "href")
        if href then
            seen = seen + 1
            local rtype = element(resp, "resourcetype") or ""
            local comps = element(resp, "supported%-calendar%-component%-set") or ""
            -- Deux signaux indépendants : le resourcetype <calendar/>, ou la
            -- déclaration de composants que seuls les calendriers portent.
            -- La classe de caractères après "calendar" écarte <calendar-proxy-read/>.
            local has_decl = declares_comp(comps, "V")
            -- Le resourcetype seul décide. La collection racine et les boites
            -- schedule-inbox/outbox déclarent aussi des composants : s'y fier
            -- les faisait passer pour des calendriers.
            -- <subscribed/> = calendrier abonné (météo, jours fériés), en lecture seule.
            local is_calendar = rtype:find("<calendar[/%s>]") ~= nil
                             or rtype:find("<subscribed[/%s>]") ~= nil
            if is_calendar then
                -- Collection sans déclaration explicite = calendrier d'événements (défaut RFC).
                out[#out + 1] = {
                    url = abs_url(base, href),
                    name = tag(resp, "displayname") or href:match("([^/]+)/?$") or "?",
                    events = (not has_decl) or declares_comp(comps, "VEVENT"),
                    todos = has_decl and declares_comp(comps, "VTODO") or false,
                }
            end
        end
    end
    return out, seen
end

--== Lecture =================================================================

local function report(cfg, coll_url, body)
    return CalDAV.request(cfg, {
        url = coll_url,
        method = "REPORT",
        body = body,
        headers = { ["Depth"] = "1", ["Content-Type"] = 'application/xml; charset="utf-8"' },
    })
end

local function utcstamp(ts)
    return os.date("!%Y%m%dT%H%M%SZ", ts)
end

-- Chaque <response> porte un href, un getetag et un calendar-data (l'ICS).
local function each_item(xml, base)
    local items = {}
    for resp in responses(xml) do
        local data = resp:match("<calendar%-data[^>]*>(.-)</calendar%-data>")
        if data then
            items[#items + 1] = {
                href = abs_url(base, tag(resp, "href") or ""),
                etag = tag(resp, "getetag"),
                ics = unent(data),
            }
        end
    end
    return items
end

-- Événements entre deux epochs. Le serveur déplie les récurrences.
function CalDAV.events(cfg, coll, from_ts, to_ts)
    local body = string.format([[<?xml version="1.0" encoding="utf-8"?>
<C:calendar-query xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
 <prop><getetag/><C:calendar-data><C:expand start="%s" end="%s"/></C:calendar-data></prop>
 <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">
  <C:time-range start="%s" end="%s"/>
 </C:comp-filter></C:comp-filter></C:filter>
</C:calendar-query>]], utcstamp(from_ts), utcstamp(to_ts), utcstamp(from_ts), utcstamp(to_ts))

    local xml, code, _, err, final = report(cfg, coll.url, body)
    record("REPORT VEVENT " .. coll.name, coll.url, code, xml)
    if err then return nil, err end
    if code ~= 207 then return nil, coll.name .. ": HTTP " .. tostring(code) .. snippet(xml) end

    local out = {}
    for _, item in ipairs(each_item(xml, final or coll.url)) do
        for _, ev in ipairs(ICS.events(item.ics, cfg.tz_offset)) do
            ev.calendar = coll.name
            out[#out + 1] = ev
        end
    end
    return out
end

-- Un seul filtre serveur, et seulement <is-not-defined/>, dont la sémantique est
-- sans ambiguité. Le filtre STATUS précédent excluait TOUTES les taches : selon
-- la RFC 4791, un prop-filter ne matche que si la propriété existe, or la plupart
-- des rappels n'ont pas de STATUS.
local TODO_FILTERED = [[<?xml version="1.0" encoding="utf-8"?>
<C:calendar-query xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
 <prop><getetag/><C:calendar-data/></prop>
 <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VTODO">
  <C:prop-filter name="COMPLETED"><C:is-not-defined/></C:prop-filter>
 </C:comp-filter></C:comp-filter></C:filter>
</C:calendar-query>]]

-- Repli sans le moindre filtre de propriété : tout ce que la collection contient.
-- Sert à distinguer "le serveur filtre trop" de "la liste est vide".
local TODO_ALL = [[<?xml version="1.0" encoding="utf-8"?>
<C:calendar-query xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
 <prop><getetag/><C:calendar-data/></prop>
 <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VTODO"/></C:comp-filter></C:filter>
</C:calendar-query>]]

-- Dernier recours. Apple répond parfois à un calendar-query par la seule
-- collection, sans ses membres ; PROPFIND Depth:1 les liste toujours, et chaque
-- .ics se récupère alors par un GET. Une requête par tâche : réservé au cas où
-- les deux REPORT ont rendu zéro.
local function todos_via_propfind(cfg, coll)
    local body = [[<?xml version="1.0" encoding="utf-8"?>
<propfind xmlns="DAV:"><prop><getetag/><resourcetype/></prop></propfind>]]

    local xml, code, _, err, final = CalDAV.request(cfg, {
        url = coll.url,
        method = "PROPFIND",
        body = body,
        headers = { ["Depth"] = "1", ["Content-Type"] = 'application/xml; charset="utf-8"' },
    })
    record("PROPFIND membres " .. coll.name, coll.url, code, xml)
    if err or code ~= 207 then return nil end

    local base = final or coll.url
    local out = {}
    for resp in responses(xml) do
        local href = tag(resp, "href")
        if href and href:match("%.ics$") then
            local url = abs_url(base, href)
            local ics, gcode = CalDAV.request(cfg, { url = url, method = "GET" })
            if gcode == 200 and ics then
                for _, td in ipairs(ICS.todos(ics, cfg.tz_offset)) do
                    if not td.done and not td.cancelled then
                        td.href, td.etag, td.list = url, tag(resp, "getetag"), coll.name
                        out[#out + 1] = td
                    end
                end
            end
        end
    end
    return out
end

-- Tâches non terminées d'une liste de rappels.
function CalDAV.todos(cfg, coll)
    local function fetch(body, label)
        local xml, code, _, err, final = report(cfg, coll.url, body)
        record("REPORT VTODO " .. label .. " " .. coll.name, coll.url, code, xml)
        if err then return nil, err end
        if code ~= 207 then
            return nil, coll.name .. ": HTTP " .. tostring(code) .. snippet(xml)
        end

        local out = {}
        for _, item in ipairs(each_item(xml, final or coll.url)) do
            for _, td in ipairs(ICS.todos(item.ics, cfg.tz_offset)) do
                -- Terminé/annulé écarté ici : le repli non filtré ramène tout.
                if not td.done and not td.cancelled then
                    td.href, td.etag, td.list = item.href, item.etag, coll.name
                    out[#out + 1] = td
                end
            end
        end
        return out
    end

    local out, err = fetch(TODO_FILTERED, "filtre")
    if out and #out == 0 then
        -- Zéro tâche : soit le serveur a trop filtré, soit la liste est vide.
        -- Rejouer sans filtre tranche, et répare si le filtre était en cause.
        local all = fetch(TODO_ALL, "sans-filtre")
        if all and #all > 0 then return all end
        -- Toujours rien : le REPORT lui-même est peut-être en cause.
        local listed = todos_via_propfind(cfg, coll)
        if listed and #listed > 0 then return listed end
    end
    return out, err
end

--== Écriture ================================================================

-- Coche/décoche une tâche côté serveur. Renvoie true, ou nil + message.
function CalDAV.set_done(cfg, todo, done)
    local ics, code, headers, err = CalDAV.request(cfg, { url = todo.href, method = "GET" })
    if err then return nil, err end
    if code ~= 200 then return nil, "GET tache: HTTP " .. tostring(code) end

    local etag = (headers and (headers.etag or headers.ETag)) or todo.etag
    local patched = ICS.set_done(ics, done)

    local _, put_code, put_headers, put_err = CalDAV.request(cfg, {
        url = todo.href,
        method = "PUT",
        body = patched,
        headers = {
            ["Content-Type"] = "text/calendar; charset=utf-8",
            ["If-Match"] = etag,
        },
    })
    if put_err then return nil, put_err end
    if put_code == 412 then return nil, "conflit: tache modifiee ailleurs" end
    if put_code ~= 200 and put_code ~= 204 and put_code ~= 201 then
        return nil, "PUT: HTTP " .. tostring(put_code)
    end

    todo.etag = put_headers and (put_headers.etag or put_headers.ETag) or nil
    return true
end

return CalDAV
