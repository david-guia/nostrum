--[[
Client du pont EventKit tournant sur le Mac.

Rend des tâches de la même forme que CalDAV.todos : la vue ne fait pas la
différence entre les deux sources. C'est ce qui permet de contourner iCloud,
qui ne publie pas les listes de Rappels en CalDAV, sans toucher à l'interface.
]]

local Net = require("nostrum_net")
local ok_json, json = pcall(require, "rapidjson")

local Bridge = {}

-- Port par defaut du pont Nostrum. bridge_port dans config.lua le remplace.
Bridge.PORT = 8843

-- bridge_url accepte une adresse ou plusieurs : le Mac a une IP par interface
-- (Ethernet, Wi-Fi) et le bail DHCP change. On essaie chacune et on retient
-- celle qui repond, pour ne pas repayer les timeouts a chaque synchro.
local last_ok

-- Derniere adresse trouvee par la recherche sur le reseau : memorisee dans les
-- reglages de KOReader, elle survit au redemarrage et passe avant config.lua,
-- dont les adresses datent de l'installation.
local SEEN_KEY = "nostrum_bridge_url"

local function remembered()
    return G_reader_settings and G_reader_settings:readSetting(SEEN_KEY) or nil
end

local function candidates(cfg)
    local u = cfg.bridge_url
    local list, dup = {}, {}
    local function add(v)
        if type(v) == "string" and v ~= "" then
            v = v:gsub("/+$", "")
            if not dup[v] then dup[v] = true; list[#list + 1] = v end
        end
    end
    add(remembered())
    for _, v in ipairs(type(u) == "table" and u or { u }) do add(v) end
    if last_ok then
        for i, v in ipairs(list) do
            if v == last_ok then table.remove(list, i); table.insert(list, 1, v); break end
        end
    end
    return list
end

local function base(cfg)
    return last_ok or candidates(cfg)[1] or ""
end

local function headers(cfg)
    local h = { ["Accept"] = "application/json" }
    if cfg.bridge_token then h["X-Nostrum-Token"] = cfg.bridge_token end
    return h
end

--== Recherche du pont sur le reseau local ===================================
-- Le Kindle ne resout pas les noms .local et le bail DHCP du Mac change : quand
-- aucune adresse connue ne repond, on frappe a toutes les portes du /24 en
-- parallele, puis on presente le jeton a celles qui s'ouvrent. Seul le pont de
-- ce client repond 200 avec ce jeton : impossible de se tromper d'hote.

local SCAN_BATCH = 64   -- sockets ouvertes a la fois, loin des limites du Kindle
local SCAN_WAIT = 1.5   -- secondes par lot : un hote du reseau local repond en ms
local SCAN_EVERY = 300  -- pas plus d'une recherche toutes les 5 min
local scanned_at

-- Un connect UDP n'envoie aucun paquet : il fait seulement choisir au systeme
-- l'interface de sortie, dont on lit alors l'adresse.
function Bridge.local_ip(socket)
    local u = socket.udp()
    if not u then return nil end
    u:setpeername("192.0.2.1", 9)
    local ip = u:getsockname()
    u:close()
    if ip and ip ~= "0.0.0.0" and ip:match("^%d+%.%d+%.%d+%.%d+$") then return ip end
end

-- Hotes du /24 dont le port accepte une connexion TCP.
function Bridge.open_hosts(socket, ip, port)
    local prefix = ip:match("^(%d+%.%d+%.%d+%.)")
    local found = {}
    for first = 1, 254, SCAN_BATCH do
        local socks, addr = {}, {}
        for h = first, math.min(first + SCAN_BATCH - 1, 254) do
            local a = prefix .. h
            local c = a ~= ip and socket.tcp()
            if c then
                c:settimeout(0)
                c:connect(a, port)
                socks[#socks + 1], addr[c] = c, a
            end
        end
        -- Une connexion refusee devient elle aussi « ecrivable » : seule
        -- getpeername distingue la porte ouverte de la porte claquee.
        local waiting, deadline = socks, socket.gettime() + SCAN_WAIT
        while #waiting > 0 and socket.gettime() < deadline do
            local _, ready = socket.select(nil, waiting, deadline - socket.gettime())
            local done, rest = {}, {}
            for _, c in ipairs(ready or {}) do
                done[c] = true
                if c:getpeername() then found[#found + 1] = addr[c] end
            end
            for _, c in ipairs(waiting) do if not done[c] then rest[#rest + 1] = c end end
            waiting = rest
        end
        for _, c in ipairs(socks) do c:close() end
    end
    table.sort(found)
    return found
end

function Bridge.discover(cfg)
    if scanned_at and os.time() - scanned_at < SCAN_EVERY then return nil end
    local ok_sock, socket = pcall(require, "socket")
    if not ok_sock then return nil end
    scanned_at = os.time()
    local ip = Bridge.local_ip(socket)
    if not ip then return nil end
    local port = cfg.bridge_port or Bridge.PORT
    for _, host in ipairs(Bridge.open_hosts(socket, ip, port)) do
        local url = "http://" .. host .. ":" .. port
        local _, code = Net.get(url .. "/prefs", headers(cfg))
        if code == 200 then
            if G_reader_settings then G_reader_settings:saveSetting(SEEN_KEY, url) end
            return url
        end
    end
end

-- Toutes les lectures passent par ici : une seule adresse essayee, c'etait le
-- timeout de la mise a jour quand le bail DHCP passait d'une interface a
-- l'autre. Une reponse HTTP, meme en erreur, prouve que c'est le bon hote :
-- inutile d'essayer les suivants pour un jeton refuse.
-- Delai court : le pont est sur le reseau local, une adresse qui ne repond pas
-- en 5 s est morte, et l'interface du Kindle est figee pendant l'attente.
local function get_any(cfg, path)
    local saved = Net.timeout
    Net.timeout = 5
    local body, code, err
    for _, url in ipairs(candidates(cfg)) do
        body, code, err = Net.get(url .. path, headers(cfg))
        if not err then last_ok = url; break end
    end
    if err or not code then
        last_ok = Bridge.discover(cfg)
        if last_ok then
            body, code, err = Net.get(last_ok .. path, headers(cfg))
        else
            body, code = nil, nil
            err = err or "pont: introuvable sur le reseau local"
        end
    end
    Net.timeout = saved
    return body, code, err
end

-- Convertit la charge JSON en tâches. Séparée de todos() pour être testable
-- sans réseau. Troisième retour : toutes les listes vues dans la charge, filtre
-- compris — c'est ce qui permet au menu du Kindle de proposer les listes qu'on
-- n'affiche pas encore.
function Bridge.shape(data, only_lists)
    if type(data) ~= "table" or type(data.todos) ~= "table" then
        return nil, "pont: reponse illisible"
    end

    local keep, filtered = {}, false
    for _, n in ipairs(only_lists or {}) do
        keep[n] = true
        filtered = true
    end

    local out, seen, names = {}, {}, {}
    for _, t in ipairs(data.todos) do
        if t.list and not seen[t.list] then
            seen[t.list] = true
            names[#names + 1] = t.list
        end
        if not filtered or keep[t.list] then
            out[#out + 1] = {
                summary = t.summary or "(SANS TITRE)",
                uid = t.id,
                -- href porte l'identifiant EventKit : c'est lui qui repart au POST.
                href = t.id,
                list = t.list,
                due = tonumber(t.due),
                priority = tonumber(t.priority) or 0,
                done = t.done == true,
            }
        end
    end

    table.sort(out, function(a, b)
        local pa = a.priority == 0 and 9 or a.priority
        local pb = b.priority == 0 and 9 or b.priority
        if pa ~= pb then return pa < pb end
        return (a.due or math.huge) < (b.due or math.huge)
    end)
    table.sort(names)
    return out, nil, names
end

function Bridge.todos(cfg)
    if not ok_json then return nil, "pont: rapidjson absent" end
    local body, code, err = get_any(cfg, "/todos")
    if err then return nil, err end
    if code == 401 then return nil, "pont: jeton refuse" end
    if code ~= 200 then return nil, "pont: HTTP " .. tostring(code) end

    local ok, data = pcall(json.decode, body)
    if not ok then return nil, "pont: JSON invalide" end
    return Bridge.shape(data, cfg.reminder_lists)
end

-- Les noms de calendriers portent parfois un espace final invisible : on compare
-- sans les espaces de bord, comme main.lua pour CalDAV.
local function trim(s)
    return type(s) == "string" and s:match("^%s*(.-)%s*$") or s
end

-- Agenda lu par EventKit sur le Mac : meme forme que CalDAV.events, la vue ne
-- voit pas la difference. Plus aucun identifiant iCloud sur le Kindle.
-- Une journee entiere arrive en « AAAA-MM-JJ » et non en epoch : minuit est
-- recalcule ici, dans le fuseau du Kindle, comme le fait ics.lua — un epoch
-- calcule par le Mac tomberait la veille au soir sur un Kindle en UTC.
function Bridge.shape_events(data, only_cals, tz_shift)
    if type(data) ~= "table" or type(data.events) ~= "table" then
        return nil, "pont: agenda illisible"
    end
    local keep, filtered = {}, false
    for _, n in ipairs(only_cals or {}) do keep[trim(n)] = true; filtered = true end

    local shift = tz_shift or 0
    local out, seen, names = {}, {}, {}
    for _, e in ipairs(data.events) do
        local cal = e.calendar
        if cal and not seen[cal] then seen[cal] = true; names[#names + 1] = cal end
        if not filtered or keep[trim(cal)] then
            local start, finish, allday
            local y, m, d = tostring(e.day or ""):match("^(%d+)-(%d+)-(%d+)$")
            if y then
                allday = true
                start = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 }) + shift
                finish = start + 86400 * math.max(1, tonumber(e.days) or 1)
            else
                start = tonumber(e.start) and tonumber(e.start) + shift
                finish = tonumber(e["end"]) and tonumber(e["end"]) + shift
            end
            if start then
                out[#out + 1] = {
                    summary = e.summary or "(SANS TITRE)",
                    location = e.location,
                    start = start,
                    finish = finish,
                    allday = allday or false,
                    uid = e.id,
                }
            end
        end
    end
    table.sort(names)
    return out, nil, names
end

function Bridge.events(cfg)
    if not ok_json then return nil, "pont: rapidjson absent" end
    local body, code, err = get_any(cfg, "/events?days=" .. (tonumber(cfg.days) or 1))
    if err then return nil, err end
    if code == 401 then return nil, "pont: jeton refuse" end
    if code ~= 200 then return nil, "pont: HTTP " .. tostring(code) end
    local ok, data = pcall(json.decode, body)
    if not ok then return nil, "pont: JSON invalide" end
    return Bridge.shape_events(data, cfg.calendars, cfg.tz_offset)
end

-- Sources du plugin servies par le pont : c'est ce qui permet au Kindle de se
-- mettre a jour sans cable. Rien n'est ecrit ici, main.lua s'en charge.
function Bridge.manifest(cfg)
    if not ok_json then return nil, "pont: rapidjson absent" end
    local body, code, err = get_any(cfg, "/plugin")
    if err then return nil, err end
    if code == 404 then return nil, "pont: mise a jour non servie" end
    if code ~= 200 then return nil, "pont: HTTP " .. tostring(code) end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" or type(data.files) ~= "table" then
        return nil, "pont: manifeste illisible"
    end
    return data
end

-- Sources choisies dans la fenetre du pont. Un tableau vide veut dire « rien de
-- coche », donc aucun filtre impose : l'appel reussit quand meme, c'est a
-- l'appelant de decider ce qu'il en fait.
function Bridge.prefs(cfg)
    if not ok_json then return nil, "pont: rapidjson absent" end
    local body, code, err = get_any(cfg, "/prefs")
    if err then return nil, err end
    -- 404 compris : un pont plus ancien ne connait pas cette route. Rien a
    -- distinguer, l'appelant continue sans reglages dans les deux cas.
    if code ~= 200 then return nil, "pont: HTTP " .. tostring(code) end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then return nil, "pont: reglages illisibles" end
    return { calendars = type(data.calendars) == "table" and data.calendars or {},
             lists = type(data.lists) == "table" and data.lists or {} }
end

function Bridge.file(cfg, name)
    local body, code, err = get_any(cfg, "/plugin/" .. name)
    if err then return nil, err end
    if code ~= 200 then return nil, "pont: HTTP " .. tostring(code) end
    return body
end

function Bridge.set_done(cfg, todo, done)
    if not ok_json then return nil, "pont: rapidjson absent" end
    local id = todo.href or todo.uid
    if not id then return nil, "pont: tache sans identifiant" end

    local payload = json.encode({ id = id, done = done and true or false })
    local body, code, err = Net.post(base(cfg) .. "/toggle", payload, headers(cfg))
    if err then return nil, err end
    if code == 401 then return nil, "pont: jeton refuse" end
    if code ~= 200 then
        return nil, "pont: HTTP " .. tostring(code) .. " " .. tostring(body)
    end
    return true
end

return Bridge
