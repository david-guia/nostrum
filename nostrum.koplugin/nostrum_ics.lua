--[[
iCalendar minimal : dépliage, extraction VEVENT/VTODO, marquage terminé.
Pur Lua 5.1, aucune dépendance KOReader -> testable avec `lua test.lua`.
]]

local ICS = {}

-- Jours écoulés depuis 1970-01-01, calendrier grégorien proleptique.
local function days_from_civil(y, m, d)
    y = y - (m <= 2 and 1 or 0)
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- Équivalent de timegm() : calendrier UTC -> epoch, sans passer par os.time
-- (qui applique l'heure d'été locale et fausserait la conversion en été).
local function timegm(t)
    return days_from_civil(t.year, t.month, t.day) * 86400
         + t.hour * 3600 + t.min * 60 + t.sec
end

-- "20260726T143000Z" / "20260726T143000" / "20260726" -> epoch, is_allday
-- tz_shift : correction manuelle en secondes, 0 par défaut (voir config.lua).
function ICS.parse_dt(value, params, tz_shift)
    if not value then return nil end
    local y, m, d = value:match("^(%d%d%d%d)(%d%d)(%d%d)")
    if not y then return nil end
    local H, M, S = value:match("T(%d%d)(%d%d)(%d%d)")
    local allday = (H == nil) or (params and params:find("VALUE=DATE", 1, true) ~= nil)

    local t = {
        year = tonumber(y), month = tonumber(m), day = tonumber(d),
        hour = tonumber(H) or 0, min = tonumber(M) or 0, sec = tonumber(S) or 0,
    }
    local shift = tz_shift or 0

    -- Journée entière : minuit dans le fuseau de l'appareil.
    if allday then return os.time(t) + shift, true end

    -- Suffixe Z = UTC. Le REPORT <expand> d'iCloud renvoie toujours de l'UTC ;
    -- une valeur flottante est donc rare et traitée comme heure locale.
    -- ponytail: aucune base TZID embarquée. Si un serveur non-Apple renvoie du
    -- TZID brut, le décalage se rattrape avec tz_shift.
    if value:sub(-1) == "Z" then return timegm(t) + shift, false end
    return os.time(t) + shift, false
end

-- Déplie les lignes (RFC 5545 §3.1) et normalise en \n.
function ICS.unfold(text)
    return (text:gsub("\r\n", "\n"):gsub("\n[ \t]", ""))
end

-- Parse un bloc en table { NOM = {value=..., params=...} }.
-- Propriété répétée : seule la première est gardée (suffisant pour VEVENT/VTODO simples).
local function props(block)
    local out = {}
    for line in block:gmatch("[^\n]+") do
        local name, rest = line:match("^([A-Za-z%-]+)([;:].*)$")
        if name then
            name = name:upper()
            local params, value
            if rest:sub(1, 1) == ":" then
                params, value = "", rest:sub(2)
            else
                params, value = rest:match("^;([^:]*):(.*)$")
            end
            if value and not out[name] then
                out[name] = { value = value, params = params or "" }
            end
        end
    end
    return out
end

local function unescape(s)
    if not s then return "" end
    return (s:gsub("\\n", " "):gsub("\\,", ","):gsub("\\;", ";"):gsub("\\\\", "\\"))
end

local function get(p, name)
    return p[name] and unescape(p[name].value) or nil
end

-- Extrait les VEVENT d'un flux ICS.
function ICS.events(text, tz_offset)
    local out = {}
    for block in ICS.unfold(text):gmatch("BEGIN:VEVENT\n(.-)\nEND:VEVENT") do
        local p = props(block)
        if p.DTSTART then
            local start, allday = ICS.parse_dt(p.DTSTART.value, p.DTSTART.params, tz_offset)
            local finish = p.DTEND and ICS.parse_dt(p.DTEND.value, p.DTEND.params, tz_offset)
            out[#out + 1] = {
                summary = get(p, "SUMMARY") or "(SANS TITRE)",
                location = get(p, "LOCATION"),
                start = start,
                finish = finish,
                allday = allday,
                uid = get(p, "UID"),
            }
        end
    end
    table.sort(out, function(a, b)
        if a.allday ~= b.allday then return a.allday end
        return (a.start or 0) < (b.start or 0)
    end)
    return out
end

-- Extrait les VTODO. `href`/`etag` viennent du CalDAV, injectés par l'appelant.
function ICS.todos(text, tz_offset)
    local out = {}
    for block in ICS.unfold(text):gmatch("BEGIN:VTODO\n(.-)\nEND:VTODO") do
        local p = props(block)
        local status = (get(p, "STATUS") or ""):upper()
        local pct = tonumber(get(p, "PERCENT-COMPLETE") or "0") or 0
        out[#out + 1] = {
            summary = get(p, "SUMMARY") or "(SANS TITRE)",
            uid = get(p, "UID"),
            due = p.DUE and ICS.parse_dt(p.DUE.value, p.DUE.params, tz_offset) or nil,
            priority = tonumber(get(p, "PRIORITY") or "0") or 0,
            done = (status == "COMPLETED") or (p.COMPLETED ~= nil) or pct >= 100,
            cancelled = (status == "CANCELLED"),
        }
    end
    table.sort(out, function(a, b)
        if a.done ~= b.done then return b.done end
        local pa = a.priority == 0 and 9 or a.priority
        local pb = b.priority == 0 and 9 or b.priority
        if pa ~= pb then return pa < pb end
        return (a.due or math.huge) < (b.due or math.huge)
    end)
    return out
end

-- Réécrit une propriété dans le corps du VTODO (remplace ou insère avant END:VTODO).
local function set_prop(ics, name, line)
    local pat = "\r?\n" .. name .. "[;:][^\r\n]*"
    if ics:find(pat) then
        return (ics:gsub(pat, "\r\n" .. line, 1))
    end
    return (ics:gsub("(\r?\nEND:VTODO)", "\r\n" .. line .. "%1", 1))
end

-- Marque un VTODO terminé (ou le rouvre). Renvoie l'ICS modifié, prêt pour le PUT.
function ICS.set_done(ics, done, now)
    now = now or os.time()
    local stamp = os.date("!%Y%m%dT%H%M%SZ", now)

    if done then
        ics = set_prop(ics, "STATUS", "STATUS:COMPLETED")
        ics = set_prop(ics, "PERCENT%-COMPLETE", "PERCENT-COMPLETE:100")
        ics = set_prop(ics, "COMPLETED", "COMPLETED:" .. stamp)
    else
        ics = ics:gsub("\r?\nSTATUS:[^\r\n]*", "")
        ics = ics:gsub("\r?\nCOMPLETED:[^\r\n]*", "")
        ics = ics:gsub("\r?\nPERCENT%-COMPLETE:[^\r\n]*", "")
        ics = set_prop(ics, "STATUS", "STATUS:NEEDS-ACTION")
    end

    ics = set_prop(ics, "LAST%-MODIFIED", "LAST-MODIFIED:" .. stamp)
    ics = set_prop(ics, "DTSTAMP", "DTSTAMP:" .. stamp)

    -- SEQUENCE++ : sans ça certains serveurs ignorent la mise à jour.
    local seq = tonumber(ics:match("\r?\nSEQUENCE:(%d+)") or "0") or 0
    ics = set_prop(ics, "SEQUENCE", "SEQUENCE:" .. tostring(seq + 1))

    return ics
end

return ICS
