-- Auto-contrôle de ics.lua. `cd nostrum.koplugin && lua test.lua`
-- Ne touche pas au réseau : c'est la logique de parsing/patch qui casse en silence.

package.path = "./?.lua;" .. package.path
local ICS = require("nostrum_ics")

local function eq(got, want, msg)
    assert(got == want, string.format("%s : attendu %s, obtenu %s",
        msg, tostring(want), tostring(got)))
end

-- Dépliage RFC 5545
eq(ICS.unfold("SUMMARY:une ligne\r\n  suite"), "SUMMARY:une ligne suite", "unfold")

-- Dates : UTC -> epoch, journée entière -> minuit local
local off = 0
local ts = ICS.parse_dt("20260726T143000Z", "", off)
eq(os.date("!%Y-%m-%d %H:%M", ts), "2026-07-26 14:30", "parse_dt UTC (ete, DST actif)")

-- Même contrôle hors heure d'été : la conversion UTC ne doit pas dépendre du DST local.
eq(os.date("!%Y-%m-%d %H:%M", ICS.parse_dt("20260115T143000Z", "", off)),
    "2026-01-15 14:30", "parse_dt UTC (hiver)")

local ad, allday = ICS.parse_dt("20260726", "VALUE=DATE", off)
eq(allday, true, "parse_dt journee entiere")
eq(os.date("%Y-%m-%d %H:%M", ad), "2026-07-26 00:00", "parse_dt DATE local")

-- Événements : tri, journée entière en tête, échappements
local cal = table.concat({
    "BEGIN:VCALENDAR",
    "BEGIN:VEVENT", "UID:b", "SUMMARY:Rendez-vous\\, dentiste",
    "DTSTART:20260726T113000Z", "DTEND:20260726T120000Z", "LOCATION:Paris", "END:VEVENT",
    "BEGIN:VEVENT", "UID:a", "SUMMARY:Standup",
    "DTSTART:20260726T070000Z", "END:VEVENT",
    "BEGIN:VEVENT", "UID:c", "SUMMARY:Anniversaire",
    "DTSTART;VALUE=DATE:20260726", "END:VEVENT",
    "END:VCALENDAR",
}, "\r\n")

local evs = ICS.events(cal, off)
eq(#evs, 3, "nombre d'evenements")
eq(evs[1].summary, "Anniversaire", "journee entiere en premier")
eq(evs[2].summary, "Standup", "tri chronologique")
eq(evs[3].summary, "Rendez-vous, dentiste", "deséchappement virgule")
eq(evs[3].location, "Paris", "lieu")

-- Tâches : priorité, détection du terminé sous ses trois formes
local todos_ics = table.concat({
    "BEGIN:VCALENDAR",
    "BEGIN:VTODO", "UID:1", "SUMMARY:Basse priorite", "PRIORITY:9", "END:VTODO",
    "BEGIN:VTODO", "UID:2", "SUMMARY:Urgent", "PRIORITY:1", "END:VTODO",
    "BEGIN:VTODO", "UID:3", "SUMMARY:Deja fait", "STATUS:COMPLETED", "END:VTODO",
    "BEGIN:VTODO", "UID:4", "SUMMARY:Fait via pourcentage", "PERCENT-COMPLETE:100", "END:VTODO",
    "BEGIN:VTODO", "UID:5", "SUMMARY:Annulee", "STATUS:CANCELLED", "END:VTODO",
    "END:VCALENDAR",
}, "\r\n")

local tds = ICS.todos(todos_ics, off)
eq(#tds, 5, "nombre de taches")
eq(tds[1].summary, "Urgent", "priorite 1 en tete")
eq(tds[2].summary, "Basse priorite", "priorite 9 ensuite")
eq(tds[3].done or tds[4].done, true, "terminees repoussees en fin")
local by_uid = {}
for _, t in ipairs(tds) do by_uid[t.uid] = t end
eq(by_uid["3"].done, true, "STATUS:COMPLETED detecte")
eq(by_uid["4"].done, true, "PERCENT-COMPLETE:100 detecte")
eq(by_uid["2"].done, false, "tache ouverte non marquee")

-- Régression : le filtre STATUS côté serveur excluait toute tâche sans STATUS,
-- c'est-à-dire la quasi-totalité des rappels iCloud. Le tri se fait ici.
eq(by_uid["1"].cancelled, false, "tache sans STATUS n'est pas annulee")
eq(by_uid["5"].cancelled, true, "STATUS:CANCELLED detecte")
eq(by_uid["5"].done, false, "annulee n'est pas terminee")

-- Patch de complétion : ce qui part en PUT sur iCloud
local raw = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:x\r\nSUMMARY:Appeler client\r\n" ..
            "STATUS:NEEDS-ACTION\r\nSEQUENCE:3\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"

local done = ICS.set_done(raw, true, 1785000000)
assert(done:find("STATUS:COMPLETED", 1, true), "STATUS passe a COMPLETED")
assert(not done:find("NEEDS-ACTION", 1, true), "ancien STATUS remplace, pas duplique")
assert(done:find("PERCENT-COMPLETE:100", 1, true), "PERCENT-COMPLETE ajoute")
assert(done:find("COMPLETED:", 1, true), "horodatage COMPLETED ajoute")
assert(done:find("SEQUENCE:4", 1, true), "SEQUENCE incremente")
assert(done:find("SUMMARY:Appeler client", 1, true), "reste de la tache preserve")
assert(done:find("END:VTODO", 1, true), "structure VTODO intacte")
eq(select(2, done:gsub("STATUS:", "")), 1, "un seul STATUS")

-- Idempotence : recocher une tâche déjà cochée ne duplique rien
local twice = ICS.set_done(done, true, 1785000001)
eq(select(2, twice:gsub("COMPLETED:", "")), 1, "un seul COMPLETED apres double coche")
eq(select(2, twice:gsub("PERCENT%-COMPLETE:", "")), 1, "un seul PERCENT-COMPLETE")

-- Décochage : on repasse en NEEDS-ACTION sans laisser de trace de complétion
local reopened = ICS.set_done(done, false, 1785000002)
assert(reopened:find("STATUS:NEEDS-ACTION", 1, true), "retour a NEEDS-ACTION")
assert(not reopened:find("COMPLETED:", 1, true), "COMPLETED retire")
assert(not reopened:find("PERCENT-COMPLETE", 1, true), "PERCENT-COMPLETE retire")

--== caldav.lua : extraction des href de propriétés ==========================
-- Le parsing XML est la partie qui a cassé trois fois de suite. Il se teste
-- sans réseau : caldav.lua se charge même sans luasocket.

local CalDAV = require("nostrum_caldav")

-- Cas nominal : réponse iCloud avec préfixe de namespace.
local ok_doc = [[<?xml version="1.0" encoding="UTF-8"?>
<D:multistatus xmlns:D="DAV:"><D:response>
<D:href>/</D:href><D:propstat><D:prop>
<D:current-user-principal><D:href>/1234567890/principal/</D:href></D:current-user-principal>
</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>]]
eq(CalDAV.prop_href(ok_doc, "current%-user%-principal"), "/1234567890/principal/",
    "href du principal extrait malgre le prefixe de namespace")

-- Le cas qui échouait : 207 mais propriété vide dans un propstat 404.
local empty_doc = [[<?xml version="1.0" encoding="UTF-8"?>
<multistatus xmlns="DAV:"><response><href>/</href>
<propstat><prop><current-user-principal/></prop>
<status>HTTP/1.1 404 Not Found</status></propstat></response></multistatus>]]
eq(CalDAV.prop_href(empty_doc, "current%-user%-principal"), nil,
    "element vide (propstat 404) traite comme absent, pas comme trouve")

-- Mélange : une propriété vide puis la vraie, dans le même document.
local mixed_doc = [[<multistatus xmlns="DAV:"><response>
<propstat><prop><current-user-principal/></prop><status>HTTP/1.1 404 Not Found</status></propstat>
</response><response>
<propstat><prop><current-user-principal><href>/42/principal/</href></current-user-principal></prop>
<status>HTTP/1.1 200 OK</status></propstat></response></multistatus>]]
eq(CalDAV.prop_href(mixed_doc, "current%-user%-principal"), "/42/principal/",
    "la propriete vide ne masque pas la vraie")

-- calendar-home-set : URL absolue sur la partition, entites XML échappées
local home_doc = [[<multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
<response><propstat><prop><C:calendar-home-set>
<href>https://p42-caldav.icloud.com/1234567890/calendars/</href>
</C:calendar-home-set></prop></propstat></response></multistatus>]]
eq(CalDAV.prop_href(home_doc, "calendar%-home%-set"),
    "https://p42-caldav.icloud.com/1234567890/calendars/", "calendar-home-set absolu")

eq(CalDAV.prop_href(home_doc, "current%-user%-principal"), nil, "propriete absente -> nil")
eq(CalDAV.prop_href("", "current%-user%-principal"), nil, "document vide -> nil")
eq(CalDAV.prop_href("<multistatus/>", "current%-user%-principal"), nil, "document minimal -> nil")

-- href blanc : à traiter comme absent
eq(CalDAV.prop_href("<current-user-principal><href>   </href></current-user-principal>",
    "current%-user%-principal"), nil, "href blanc -> nil")

--== caldav.lua : résolution d'URL ==========================================

local A = CalDAV.abs_url
eq(A("https://p42-caldav.icloud.com/1/calendars/", "https://autre.example/x"),
    "https://autre.example/x", "url absolue conservee")
eq(A("https://p42-caldav.icloud.com/1/calendars/", "/1/calendars/work/"),
    "https://p42-caldav.icloud.com/1/calendars/work/", "chemin absolu recolle a lhote")
eq(A("https://p42-caldav.icloud.com/1/calendars/", "work/"),
    "https://p42-caldav.icloud.com/1/calendars/work/", "chemin relatif")
eq(A("https://p42-caldav.icloud.com/1/calendars/home.ics", "work.ics"),
    "https://p42-caldav.icloud.com/1/calendars/work.ics", "relatif depuis un fichier")

--== caldav.lua : filtrage des collections ==================================

-- Reproduction fidèle de ce qu'iCloud renvoie réellement (relevé sur appareil).
-- Trois pièges bien réels ici :
--   1. <response xmlns="DAV:"> porte un attribut : un motif <response> le rate,
--      et on ne voit alors aucune ressource ;
--   2. les attributs sont en guillemets simples : name='VEVENT' ;
--   3. la collection racine et schedule-inbox déclarent aussi des composants,
--      donc seul le resourcetype peut décider.
local coll_doc = [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<multistatus xmlns="DAV:">
<response xmlns="DAV:"><href>/1/calendars/</href><propstat><prop>
 <displayname xmlns="DAV:">David Guia</displayname>
 <resourcetype xmlns="DAV:"><collection/></resourcetype>
 <supported-calendar-component-set xmlns="urn:ietf:params:xml:ns:caldav"><comp name='VEVENT' xmlns='urn:ietf:params:xml:ns:caldav'/><comp name='VTODO' xmlns='urn:ietf:params:xml:ns:caldav'/></supported-calendar-component-set>
 </prop><status>HTTP/1.1 200 OK</status></propstat></response>
<response xmlns="DAV:"><href>/1/calendars/ABCD/</href><propstat><prop>
 <displayname xmlns="DAV:">Organisation Générale</displayname>
 <resourcetype xmlns="DAV:"><collection/><calendar /><shared-owner /></resourcetype>
 <supported-calendar-component-set xmlns="urn:ietf:params:xml:ns:caldav"><comp name='VEVENT' xmlns='urn:ietf:params:xml:ns:caldav'/></supported-calendar-component-set>
 </prop><status>HTTP/1.1 200 OK</status></propstat></response>
<response xmlns="DAV:"><href>/1/calendars/EFGH/</href><propstat><prop>
 <displayname xmlns="DAV:">Rappels</displayname>
 <resourcetype xmlns="DAV:"><collection/><calendar /></resourcetype>
 <supported-calendar-component-set xmlns="urn:ietf:params:xml:ns:caldav"><comp name='VTODO' xmlns='urn:ietf:params:xml:ns:caldav'/></supported-calendar-component-set>
 </prop><status>HTTP/1.1 200 OK</status></propstat></response>
<response xmlns="DAV:"><href>/1/calendars/weather/</href><propstat><prop>
 <displayname xmlns="DAV:">Dijon Weather</displayname>
 <resourcetype xmlns="DAV:"><collection/><subscribed /></resourcetype>
 </prop><status>HTTP/1.1 200 OK</status></propstat></response>
<response xmlns="DAV:"><href>/1/calendars/inbox/</href><propstat><prop>
 <resourcetype xmlns="DAV:"><collection/><schedule-inbox /></resourcetype>
 <supported-calendar-component-set xmlns="urn:ietf:params:xml:ns:caldav"><comp name='VEVENT' xmlns='urn:ietf:params:xml:ns:caldav'/></supported-calendar-component-set>
 </prop><status>HTTP/1.1 200 OK</status></propstat></response>
<response xmlns="DAV:"><href>/1/calendars/notification/</href><propstat><prop>
 <resourcetype xmlns="DAV:"><collection/><notification /></resourcetype>
 </prop><status>HTTP/1.1 200 OK</status></propstat></response>
</multistatus>]]

local colls, seen = CalDAV.parse_collections(coll_doc, "https://p42-caldav.icloud.com/1/calendars/")
eq(seen, 6, "les <response xmlns=...> sont bien decoupees")
eq(#colls, 3, "calendrier + rappels + abonnement retenus, le reste ecarte")

local by_name = {}
for _, c in ipairs(colls) do by_name[c.name] = c end

eq(by_name["Organisation Générale"].events, true, "calendrier VEVENT")
eq(by_name["Organisation Générale"].todos, false, "un calendrier nest pas une liste de taches")
eq(by_name["Organisation Générale"].url, "https://p42-caldav.icloud.com/1/calendars/ABCD/", "url de collection")
eq(by_name["Rappels"].todos, true, "liste VTODO detectee malgre les guillemets simples")
eq(by_name["Rappels"].events, false, "une liste de taches nest pas un calendrier")
eq(by_name["Dijon Weather"].events, true, "calendrier abonne retenu")
eq(by_name["David Guia"], nil, "collection racine ecartee malgre ses composants declares")
eq(by_name["inbox"], nil, "schedule-inbox ecartee malgre ses composants declares")
eq(by_name["notification"], nil, "collection de notifications ecartee")

-- calendar-proxy-* ne doit pas etre confondu avec calendar
local proxy = [[<multistatus xmlns="DAV:"><response xmlns="DAV:"><href>/1/p/</href>
<propstat><prop><resourcetype xmlns="DAV:"><collection/><calendar-proxy-read /></resourcetype>
</prop></propstat></response></multistatus>]]
eq(#CalDAV.parse_collections(proxy, "https://x.example/"), 0, "calendar-proxy-read ecarte")

-- Calendrier sans déclaration de composants : événements par défaut (RFC 4791).
local bare = [[<multistatus xmlns="DAV:"><response><href>/1/calendars/perso/</href>
<propstat><prop><displayname>Perso</displayname>
<resourcetype><collection/><calendar/></resourcetype></prop></propstat></response></multistatus>]]
local bare_colls = CalDAV.parse_collections(bare, "https://x.example/")
eq(#bare_colls, 1, "calendrier sans declaration retenu")
eq(bare_colls[1].events, true, "defaut RFC : evenements")

-- Collection nommée uniquement par son href
local noname = [[<multistatus xmlns="DAV:"><response><href>/1/calendars/abcd/</href>
<propstat><prop><resourcetype><collection/><calendar/></resourcetype></prop></propstat></response></multistatus>]]
eq(CalDAV.parse_collections(noname, "https://x.example/")[1].name, "abcd",
    "repli sur le dernier segment du href")

eq(#CalDAV.parse_collections("<multistatus/>", "https://x.example/"), 0, "document vide -> aucune")

--== weather.lua : mise en forme, sans réseau ================================

local Weather = require("nostrum_weather")

eq(Weather.label(0), "CIEL CLAIR", "code WMO 0")
eq(Weather.label(95), "ORAGE", "code WMO 95")
eq(Weather.label(1234), "CODE 1234", "code WMO inconnu reste lisible")

local wx = Weather.shape({
    current = { temperature_2m = 12.4, weather_code = 3, wind_speed_10m = 11.2 },
    daily = {
        temperature_2m_max = { 15.1 },
        temperature_2m_min = { 7.8 },
        weather_code = { 3 },
    },
}, "DIJON")
eq(wx.place, "DIJON", "ville reportee")
eq(wx.temp, 12.4, "temperature courante")
eq(wx.label, "COUVERT", "libelle deduit du code")
-- daily arrive en tableaux, current non : la confusion des deux est le piege.
eq(wx.tmax, 15.1, "max du jour extrait du tableau")
eq(wx.tmin, 7.8, "min du jour extrait du tableau")

local _, werr = Weather.shape({}, "DIJON")
assert(werr, "reponse sans releve courant rejetee")
local _, werr2 = Weather.shape("pas une table", "DIJON")
assert(werr2, "reponse non structuree rejetee")

--== bridge.lua : conversion JSON -> taches ==================================

-- rapidjson n'existe qu'a l'interieur de KOReader. Doublure minimale : les
-- controles ci-dessous portent sur le choix d'adresse, pas sur le parseur.
package.preload["rapidjson"] = function()
    return { decode = function(s) return load("return " .. s)() end }
end
local Bridge = require("nostrum_bridge")

local bt = Bridge.shape({ todos = {
    { id = "A", summary = "Basse", priority = 0, done = false, list = "Pense Bête" },
    { id = "B", summary = "Urgente", priority = 1, done = false, list = "Pense Bête" },
    { id = "C", summary = "Ailleurs", priority = 0, done = false, list = "Courses" },
} })
eq(#bt, 3, "sans filtre, toutes les listes remontent")
eq(bt[1].summary, "Urgente", "priorite 1 en tete")
-- href porte l'identifiant EventKit : sans lui, cocher est impossible.
eq(bt[1].href, "B", "identifiant EventKit conserve pour le POST")

local only = Bridge.shape({ todos = {
    { id = "A", summary = "Garde", list = "Pense Bête" },
    { id = "C", summary = "Ecarte", list = "Courses" },
} }, { "Pense Bête" })
eq(#only, 1, "filtre reminder_lists applique")
eq(only[1].summary, "Garde", "bonne liste conservee")
eq(only[1].priority, 0, "priorite absente vaut 0")

-- Les noms remontent meme filtres : sans ca le menu du Kindle ne pourrait
-- jamais reproposer une liste qu'on vient de decocher.
local _, _, noms = Bridge.shape({ todos = {
    { id = "A", summary = "Garde", list = "Pense Bête" },
    { id = "C", summary = "Ecarte", list = "Courses" },
    { id = "D", summary = "Doublon", list = "Courses" },
} }, { "Pense Bête" })
eq(#noms, 2, "les listes ecartees restent proposees")
eq(noms[1], "Courses", "listes triees")

-- Reglages servis par le pont. Un pont plus ancien repond 404 : ce n'est pas
-- une panne, c'est juste qu'il n'a rien a dire, et la synchro doit continuer.
-- La meme table que celle capturee par bridge.lua : la remplacer ici suffit.
local NetMod = require("nostrum_net")
local vrai_get = NetMod.get
-- Syntaxe de table Lua : la doublure de rapidjson ci-dessus n'est pas un
-- parseur JSON, et ce controle porte sur la forme du retour, pas sur elle.
NetMod.get = function() return '{ calendars = { "David" }, lists = {} }', 200 end
local pr = Bridge.prefs({ bridge_url = "http://x" })
eq(pr.calendars[1], "David", "calendrier choisi cote pont")
eq(#pr.lists, 0, "rien de coche = tableau vide, pas nil")
-- Un pont plus ancien ne connait pas la route : la synchro doit continuer sans
-- reglages, pas s'arreter.
NetMod.get = function() return "", 404 end
eq(Bridge.prefs({ bridge_url = "http://x" }), nil, "pont ancien: pas de reglages")

-- Charge incomplete : une seule colonne renvoyee. L'appelant parcourt les deux,
-- un nil a la place d'un tableau le ferait tomber en pleine synchro.
NetMod.get = function() return '{ calendars = { "David" } }', 200 end
local partiel = Bridge.prefs({ bridge_url = "http://x" })
eq(#partiel.lists, 0, "colonne absente = tableau vide, jamais nil")
NetMod.get = function() return "pas du json", 200 end
eq(Bridge.prefs({ bridge_url = "http://x" }), nil, "reponse illisible refusee")
NetMod.get = vrai_get

local _, berr = Bridge.shape({})
assert(berr, "charge sans champ todos rejetee")

print("OK — tous les controles ics / caldav / weather / bridge passent")

--== bridge.lua : bascule entre plusieurs bridge_url ==========================
-- Le Mac a une IP par interface et le bail DHCP bouge : la premiere adresse
-- morte ne doit pas condamner la synchro.
local Net = require("nostrum_net")
local vrai_get = Net.get
local vus = {}
Net.get = function(url)
    vus[#vus + 1] = url
    if url:match("192%.168%.0%.99") then return nil, nil, "connection refused" end
    return '{todos={{id="1",summary="T",list="L",done=false}}}', 200
end

local cfg = { bridge_url = { "http://192.168.0.99:8843", "http://192.168.0.50:8843" } }
local got = assert(Bridge.todos(cfg), "la seconde adresse doit repondre")
assert(#got == 1 and got[1].summary == "T")
assert(#vus == 2, "les deux adresses doivent etre essayees")

-- L'adresse qui a repondu passe en tete a la synchro suivante.
vus = {}
assert(Bridge.todos(cfg))
assert(#vus == 1 and vus[1]:match("192%.168%.0%.50"), "l'adresse retenue doit etre essayee seule")

-- Meme bascule pour la mise a jour : c'etait le « reseau : timeout » quand la
-- premiere adresse etait morte, manifest/file/prefs n'essayaient qu'elle.
Net.get = function() return nil, nil, "timeout" end
Bridge.todos(cfg) -- vide l'adresse retenue
vus = {}
Net.get = function(url)
    vus[#vus + 1] = url
    if url:match("192%.168%.0%.99") then return nil, nil, "timeout" end
    return '{files={{name="main.lua",sha1="x"}},version="4.2"}', 200
end
local man = assert(Bridge.manifest(cfg), "le manifeste doit venir de la seconde adresse")
eq(man.version, "4.2", "manifeste servi malgre la premiere adresse morte")
assert(#vus == 2, "manifest doit essayer les deux adresses")

Net.get = vrai_get
print("OK — bascule bridge_url")

--== bridge.lua : agenda servi par le pont ===================================
-- Journee entiere en « AAAA-MM-JJ » : minuit recalcule dans le fuseau du Kindle.
local ev, _, cals = Bridge.shape_events({ events = {
    { id = "a", summary = "Reunion", calendar = "Travail", start = 1000, ["end"] = 4600, location = "Salle 2" },
    { id = "b", summary = "Anniversaire", calendar = "Perso ", day = "2026-07-26" },
    { id = "c", summary = "Vacances", calendar = "Perso ", day = "2026-07-26", days = 3 },
} })
eq(#ev, 3, "tous les evenements sans filtre")
eq(ev[1].finish, 4600, "fin horaire conservee")
eq(ev[1].location, "Salle 2", "lieu conserve")
eq(ev[2].allday, true, "journee entiere reconnue")
eq(os.date("%Y-%m-%d %H:%M", ev[2].start), "2026-07-26 00:00", "minuit local du Kindle")
eq(ev[3].finish - ev[3].start, 3 * 86400, "evenement sur plusieurs jours")
eq(#cals, 2, "calendriers vus remontes pour le menu")

-- Filtre sur le nom sans espaces de bord : « Perso » attrape « Perso ».
local seul = Bridge.shape_events({ events = {
    { id = "a", summary = "Reunion", calendar = "Travail", start = 1000 },
    { id = "b", summary = "Anniversaire", calendar = "Perso ", day = "2026-07-26" },
} }, { "Perso" })
eq(#seul, 1, "filtre calendars applique")
eq(seul[1].summary, "Anniversaire", "espace final ignore au filtre")
eq(Bridge.shape_events({}), nil, "charge sans events rejetee")

-- tz_offset applique aux deux formes, comme ics.lua.
local dec = Bridge.shape_events({ events = { { calendar = "T", start = 1000 } } }, nil, 3600)
eq(dec[1].start, 4600, "tz_offset applique")

--== bridge.lua : recherche du pont sur le reseau local ======================
-- Doublure de luasocket : seul 192.168.1.20 a le port ouvert, .30 l'a ouvert
-- aussi mais n'est pas notre pont (jeton refuse).
local ouverts = { ["192.168.1.20"] = true, ["192.168.1.30"] = true }
local horloge = 0
local function faux_tcp()
    local s = {}
    function s:settimeout() end
    function s:connect(a) self.a = a end
    function s:getpeername() return ouverts[self.a] and self.a or nil end
    function s:close() end
    return s
end
package.loaded["socket"] = {
    udp = function()
        return { setpeername = function() end, getsockname = function() return "192.168.1.42" end,
                 close = function() end }
    end,
    tcp = faux_tcp,
    gettime = function() horloge = horloge + 0.1; return horloge end,
    -- Tout est pret au premier select : ouvert ou refuse, c'est getpeername qui tranche.
    select = function(_, w) return nil, w end,
}
local sock = package.loaded["socket"]
eq(Bridge.local_ip(sock), "192.168.1.42", "adresse locale lue sur l'interface de sortie")
local hotes = Bridge.open_hosts(sock, "192.168.1.42", 8843)
eq(#hotes, 2, "les deux portes ouvertes sont trouvees")

local demandes = {}
Net.get = function(url)
    demandes[#demandes + 1] = url
    if url:match("^http://192%.168%.1%.20:8843") then
        return url:match("/todos$") and '{todos={{id="9",summary="Trouvee",list="L"}}}' or "{}", 200
    end
    if url:match("^http://192%.168%.1%.30:8843") then return "{}", 401 end
    return nil, nil, "reseau: timeout"
end
-- Adresse de config.lua perimee : la synchro doit retrouver le pont seule.
local trouve = assert(Bridge.todos({ bridge_token = "t", bridge_url = "http://10.0.0.9:8843" }),
    "le pont doit etre retrouve par la recherche")
eq(trouve[1].summary, "Trouvee", "taches lues sur le pont retrouve")

-- Recherche limitee dans le temps : un Mac eteint ne doit pas couter un
-- balayage a chaque appel de la synchro (prefs, agenda, taches).
demandes = {}
Net.get = function(url) demandes[#demandes + 1] = url; return nil, nil, "reseau: timeout" end
Bridge.todos({ bridge_token = "t", bridge_url = "http://10.0.0.9:8843" })
for _, u in ipairs(demandes) do
    assert(not u:match("/prefs$"), "pas de second balayage avant 5 minutes")
end
package.loaded["socket"] = nil
Net.get = vrai_get
print("OK — agenda par le pont, recherche du pont")
