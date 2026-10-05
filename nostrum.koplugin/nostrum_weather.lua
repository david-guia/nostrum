--[[
Météo Open-Meteo : pas de clé d'API, pas de compte, un simple GET.
Dijon par défaut ; coordonnées surchargeables dans config.lua.
]]

local Net = require("nostrum_net")
local ok_json, json = pcall(require, "rapidjson")

local Weather = {}

-- Codes WMO -> libellés courts. Volontairement regroupés : sur 600 px de large,
-- « bruine verglaçante d'intensité forte » ne tient pas et n'apprend rien.
local WMO = {
    [0] = "CIEL CLAIR",
    [1] = "PEU NUAGEUX", [2] = "NUAGES EPARS", [3] = "COUVERT",
    [45] = "BROUILLARD", [48] = "BROUILLARD GIVRANT",
    [51] = "BRUINE", [53] = "BRUINE", [55] = "BRUINE FORTE",
    [56] = "BRUINE VERGLACANTE", [57] = "BRUINE VERGLACANTE",
    [61] = "PLUIE FAIBLE", [63] = "PLUIE", [65] = "PLUIE FORTE",
    [66] = "PLUIE VERGLACANTE", [67] = "PLUIE VERGLACANTE",
    [71] = "NEIGE FAIBLE", [73] = "NEIGE", [75] = "NEIGE FORTE",
    [77] = "GRAINS DE NEIGE",
    [80] = "AVERSES", [81] = "AVERSES", [82] = "AVERSES FORTES",
    [85] = "AVERSES DE NEIGE", [86] = "AVERSES DE NEIGE",
    [95] = "ORAGE", [96] = "ORAGE ET GRELE", [99] = "ORAGE ET GRELE",
}

function Weather.label(code)
    return WMO[code] or ("CODE " .. tostring(code))
end

local URL = "https://api.open-meteo.com/v1/forecast"
    .. "?latitude=%s&longitude=%s"
    .. "&current=temperature_2m,weather_code,wind_speed_10m"
    .. "&daily=temperature_2m_max,temperature_2m_min,weather_code"
    .. "&timezone=auto&forecast_days=1"

-- Les champs `daily` sont des tableaux (un par jour demandé) ; `current` non.
local function first(t, key)
    local v = t and t[key]
    if type(v) == "table" then return v[1] end
    return v
end

-- Mise en forme d'une réponse déjà décodée. Séparée de fetch() pour être
-- testable sans réseau.
function Weather.shape(data, name)
    if type(data) ~= "table" then return nil, "meteo: reponse illisible" end
    local cur, day = data.current, data.daily
    if type(cur) ~= "table" then return nil, "meteo: pas de releve courant" end

    local code = tonumber(cur.weather_code)
    return {
        place = name or "?",
        temp = tonumber(cur.temperature_2m),
        wind = tonumber(cur.wind_speed_10m),
        code = code,
        label = Weather.label(code),
        tmax = tonumber(first(day, "temperature_2m_max")),
        tmin = tonumber(first(day, "temperature_2m_min")),
    }
end

function Weather.fetch(cfg)
    local w = (cfg and cfg.weather) or {}
    if w.enabled == false then return nil end
    if not ok_json then return nil, "meteo: rapidjson absent" end

    local lat = w.lat or 47.3220   -- Dijon
    local lon = w.lon or 5.0415
    local body, code, err = Net.get(string.format(URL, tostring(lat), tostring(lon)))
    if err then return nil, err end
    if code ~= 200 then return nil, "meteo: HTTP " .. tostring(code) end

    local ok, data = pcall(json.decode, body)
    if not ok then return nil, "meteo: JSON invalide" end
    return Weather.shape(data, w.name or "DIJON")
end

return Weather
