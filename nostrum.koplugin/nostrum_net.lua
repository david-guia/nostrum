--[[
GET/POST sans authentification, pour la météo et le pont Mac.

Volontairement distinct de CalDAV.request, qui pose un en-tête Authorization :
le réutiliser enverrait les identifiants iCloud à un service tiers.
]]

local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")
local ok_ltn12, ltn12 = pcall(require, "ltn12")

local Net = {}
Net.timeout = 15

-- Renvoie la fonction de requête et les options propres au schéma.
local function backend(url)
    if url:match("^https://") then
        if not ok_https then return nil end
        -- Même posture que caldav.lua : le magasin de CA du Kindle est trop
        -- vieux pour valider les chaînes actuelles.
        return https.request, { protocol = "any", verify = "none", options = "all" }
    end
    if not ok_http then return nil end
    return http.request, {}
end

function Net.request(url, opts)
    opts = opts or {}
    local req, extra = backend(url)
    if not req or not ok_ltn12 then return nil, nil, "reseau: luasocket indisponible" end

    if ok_http then http.TIMEOUT = Net.timeout end
    if ok_https then https.TIMEOUT = Net.timeout end

    -- Copie des en-têtes : la table de l'appelant ne doit pas hériter de
    -- Content-Length d'une requête précédente.
    local hdr = {}
    for k, v in pairs(opts.headers or {}) do hdr[k] = v end

    local sink = {}
    local t = {
        url = url,
        method = opts.method or "GET",
        headers = hdr,
        sink = ltn12.sink.table(sink),
    }
    for k, v in pairs(extra) do t[k] = v end

    if opts.body then
        t.source = ltn12.source.string(opts.body)
        hdr["Content-Length"] = tostring(#opts.body)
        hdr["Content-Type"] = opts.content_type or "application/json"
    end

    local ok, code = req(t)
    if not ok then return nil, nil, "reseau: " .. tostring(code) end
    return table.concat(sink), tonumber(code) or code, nil
end

function Net.get(url, headers)
    return Net.request(url, { method = "GET", headers = headers })
end

function Net.post(url, body, headers)
    return Net.request(url, { method = "POST", body = body, headers = headers })
end

return Net
