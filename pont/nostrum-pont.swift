// NOSTRUM — application Mac.
//
// Sert au Kindle, sur le réseau local, ce qu'il ne peut pas lire seul : les
// Rappels (qu'iCloud ne publie pas en CalDAV) et l'agenda, lus par EventKit.
// Aucun identifiant Apple ne quitte le Mac : le Kindle ne porte qu'un jeton
// propre à cette installation, généré au premier lancement.
//
// Routes, toutes protégées par l'en-tête X-Nostrum-Token :
//   GET  /todos          -> { "todos": [ { id, summary, list, due, priority, done } ] }
//   POST /toggle         <- { "id": "...", "done": true }   -> { "ok": true }
//   GET  /events?days=N  -> { "events": [ { id, summary, location, calendar,
//                                           start, end  |  day, days } ] }
//   GET  /prefs          -> { "calendars": [...], "lists": [...] }   vides = aucun filtre
//   GET  /plugin         -> { "version": "1.0", "files": [ { name, size } ] }
//   GET  /plugin/<nom>   -> le fichier, en texte brut
//
// La fenêtre installe le plugin sur une Kindle branchée en USB, avec un
// config.lua déjà rempli, et permet de choisir les sources affichées.
// Construction : ./build.sh (application universelle + DMG).

import AppKit
import EventKit
import Foundation
import Network
import Security
import SystemConfiguration
import UniformTypeIdentifiers

let appName = "Nostrum"
let bundleID = "me.davidguia.nostrum"

// MARK: - Rappels et agenda

final class Store {
    private let store = EKEventStore()

    func requestAccess(_ kind: EKEntityType) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        let done: (Bool, Error?) -> Void = { ok, _ in granted = ok; sem.signal() }
        if #available(macOS 14.0, *) {
            if kind == .reminder { store.requestFullAccessToReminders(completion: done) }
            else { store.requestFullAccessToEvents(completion: done) }
        } else {
            store.requestAccess(to: kind, completion: done)
        }
        sem.wait()
        return granted
    }

    /// Tâches non terminées, toutes listes confondues. Le tri par liste se fait
    /// côté Kindle, qui a aussi besoin des noms écartés pour son menu.
    func incomplete() -> [[String: Any]] {
        let pred = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)

        let sem = DispatchSemaphore(value: 0)
        var out: [[String: Any]] = []
        store.fetchReminders(matching: pred) { list in
            for r in list ?? [] {
                var row: [String: Any] = [
                    "id": r.calendarItemIdentifier,
                    "summary": r.title ?? "(sans titre)",
                    "list": r.calendar?.title ?? "?",
                    "priority": r.priority,
                    "done": r.isCompleted,
                ]
                if let due = r.dueDateComponents?.date {
                    row["due"] = Int(due.timeIntervalSince1970)
                }
                out.append(row)
            }
            sem.signal()
        }
        sem.wait()
        return out
    }

    /// Événements d'aujourd'hui à minuit jusqu'à `days` jours plus tard, dans
    /// le fuseau du Mac — le seul des deux appareils qui le connaisse vraiment.
    /// Une journée entière part en « AAAA-MM-JJ » : le Kindle recalcule minuit
    /// chez lui, un epoch tomberait la veille au soir sur un Kindle resté en UTC.
    func events(days: Int) -> [[String: Any]] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: max(1, min(days, 14)), to: start) else { return [] }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.dateFormat = "yyyy-MM-dd"

        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: pred).map { e in
            var row: [String: Any] = [
                "id": e.eventIdentifier ?? e.calendarItemIdentifier,
                "summary": e.title ?? "(sans titre)",
                "calendar": e.calendar?.title ?? "?",
            ]
            // Une adresse complète tient sur plusieurs lignes : le Kindle n'en a qu'une.
            if let loc = e.location?.split(whereSeparator: \.isNewline).joined(separator: ", "),
               !loc.isEmpty {
                row["location"] = loc
            }
            if e.isAllDay {
                // EventKit termine une journée entière à 23:59:59 du dernier jour.
                let span = cal.dateComponents([.day], from: cal.startOfDay(for: e.startDate),
                                              to: e.endDate).day ?? 0
                row["day"] = day.string(from: e.startDate)
                row["days"] = max(1, span + 1)
            } else {
                row["start"] = Int(e.startDate.timeIntervalSince1970)
                row["end"] = Int(e.endDate.timeIntervalSince1970)
            }
            return row
        }
    }

    /// Noms des listes de Rappels et des calendriers, tels qu'ils s'affichent
    /// dans les applications d'Apple — donc tels que le Kindle les voit aussi.
    /// Deux comptes peuvent nommer une liste pareil : on ne garde qu'un nom,
    /// puisque c'est sur le nom que le Kindle filtre.
    func sources(_ kind: EKEntityType) -> [String] {
        var seen = Set<String>()
        return store.calendars(for: kind).map(\.title).filter { seen.insert($0).inserted }.sorted()
    }

    /// Renvoie nil si tout s'est bien passé, sinon le message d'erreur.
    func toggle(id: String, done: Bool) -> String? {
        guard let rem = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return "tache introuvable"
        }
        rem.isCompleted = done
        do {
            try store.save(rem, commit: true)
        } catch {
            return error.localizedDescription
        }
        return nil
    }
}

// MARK: - Réglages de l'installation

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent(appName)

/// Jeton, port et ville. Le jeton est tiré au premier lancement : deux clients
/// n'ont jamais le même, et un Kindle d'un autre foyer ne lit pas ces rappels.
/// Droits 600, le fichier porte ce jeton.
struct Settings: Codable {
    var token: String
    var port: Int = 8843
    var city: String?
    var lat: Double?
    var lon: Double?
    /// Identifiant Apple du secours iCloud. Le mot de passe, lui, est dans le
    /// trousseau (ICloudPassword) : ce fichier n'a pas à le porter.
    var icloudUser: String?

    static let file = supportDir.appendingPathComponent("settings.json")

    static func load() -> Settings {
        if let data = try? Data(contentsOf: file),
           let s = try? JSONDecoder().decode(Settings.self, from: data), !s.token.isEmpty {
            return s
        }
        // Deux UUID v4 : 244 bits tirés par le générateur du système, en hex,
        // donc sans caractère à échapper dans config.lua.
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let s = Settings(token: token)
        s.save()
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Settings.file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Settings.file.path)
    }
}

// MARK: - Sources choisies

/// Ce que le Kindle doit afficher, choisi ici et relu par lui à chaque synchro.
/// Un ensemble vide veut dire « aucun filtre », la même convention que
/// config.lua : c'est ce qui permet à ce pont de ne rien imposer tant que
/// personne n'a rien coché, et au réglage de l'appareil de garder la main.
final class Prefs {
    enum Kind: String { case calendars, lists }

    private let file = supportDir.appendingPathComponent("prefs.json")
    private var sets: [Kind: Set<String>] = [.calendars: [], .lists: []]

    init() {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else { return }
        for k in [Kind.calendars, .lists] { sets[k] = Set(obj[k.rawValue] ?? []) }
    }

    func chosen(_ kind: Kind) -> Set<String> { sets[kind] ?? [] }

    func isOn(_ kind: Kind, _ name: String) -> Bool {
        let s = chosen(kind)
        return s.isEmpty || s.contains(name)
    }

    /// `all` est la liste complète des sources connues. Elle est indispensable :
    /// décocher le premier nom doit matérialiser le complémentaire, sinon
    /// l'ensemble resterait vide et serait relu comme « tout afficher ». Et
    /// tout recocher revient à vider, pour qu'un calendrier ajouté plus tard
    /// apparaisse de lui-même au lieu d'être exclu par un réglage périmé.
    func set(_ kind: Kind, _ name: String, on: Bool, all: [String]) {
        var s = chosen(kind)
        if s.isEmpty { s = Set(all) }
        if on { s.insert(name) } else { s.remove(name) }
        // Tout décoché = écran vide sans explication : on préfère tout afficher.
        sets[kind] = (s.count == all.count || s.isEmpty) ? [] : s
        save()
    }

    func json() -> [String: Any] {
        [Kind.calendars.rawValue: chosen(.calendars).sorted(),
         Kind.lists.rawValue: chosen(.lists).sorted()]
    }

    private func save() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: json()) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Plugin embarqué

/// Le plugin Kindle voyage dans l'application (Resources/nostrum.koplugin) :
/// il sert à l'installation par USB et aux mises à jour par le réseau. Mettre
/// l'application à jour met donc aussi le Kindle à jour, au prochain
/// « Mettre à jour depuis le pont ».
final class PluginSource {
    let dir: URL

    init(dir: URL) { self.dir = dir }

    /// Sert de liste blanche — un nom absent d'ici n'est jamais lu, ce qui
    /// ferme la porte aux « ../ ». config.lua n'est jamais embarqué : chaque
    /// Kindle a le sien, écrit à l'installation.
    func names() -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return all.filter { $0 != "config.lua" && ($0.hasSuffix(".lua") || $0 == "README.md") }.sorted()
    }

    /// Version déclarée en tête de main.lua : une seule source de vérité, la
    /// même que celle affichée par le bandeau du Kindle.
    func version() -> String {
        guard let src = try? String(contentsOf: dir.appendingPathComponent("main.lua"), encoding: .utf8),
              let r = src.range(of: "local VERSION = \"[^\"]+\"", options: .regularExpression),
              let v = src[r].split(separator: "\"").dropFirst().first
        else { return "?" }
        return String(v)
    }

    /// La taille annoncée est ce qui permet au Kindle de détecter un
    /// téléchargement coupé : sans elle un fichier tronqué passerait.
    func manifest() -> [String: Any] {
        let files: [[String: Any]] = names().map { n in
            let attrs = try? FileManager.default.attributesOfItem(
                atPath: dir.appendingPathComponent(n).path)
            return ["name": n, "size": (attrs?[.size] as? NSNumber)?.intValue ?? 0]
        }
        return ["version": version(), "files": files]
    }

    func read(_ name: String) -> Data? {
        guard names().contains(name) else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    /// Copie le plugin dans `target` (le dossier nostrum.koplugin lui-même) et
    /// y écrit config.lua. Les fichiers du Kindle absents d'ici (debug.txt…)
    /// sont laissés en place.
    func install(into target: URL, config: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in names() {
            let dst = target.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: dir.appendingPathComponent(name), to: dst)
        }
        try Data(config.utf8).write(to: target.appendingPathComponent("config.lua"), options: .atomic)
    }
}

// MARK: - HTTP

/// Une connexion, une requête, une réponse, puis fermeture. Suffisant pour un
/// client unique qui interroge une fois par heure.
final class Peer {
    typealias Route = (_ method: String, _ path: String, _ query: String,
                       _ body: Data, _ token: String?) -> (Int, Data, String)

    private let conn: NWConnection
    private let route: Route
    private var buf = Data()
    /// Appelé une seule fois, pour que le pool relâche cette connexion.
    private var onDone: (() -> Void)?

    init(conn: NWConnection, route: @escaping Route) {
        self.conn = conn
        self.route = route
    }

    func start(on queue: DispatchQueue, onDone: @escaping () -> Void) {
        self.onDone = onDone
        conn.start(queue: queue)
        read()
    }

    private func finish() {
        conn.cancel()
        onDone?()
        onDone = nil
    }

    private func read() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, done, error in
            if let data, !data.isEmpty { buf.append(data) }
            if error != nil { finish(); return }
            if tryRespond() { return }
            if done { finish(); return }
            read()
        }
    }

    /// true dès que la requête est complète et la réponse envoyée.
    private func tryRespond() -> Bool {
        // Garde-fou : une requête sans fin d'en-têtes ne doit pas faire enfler
        // le tampon indéfiniment.
        guard buf.count <= 256 * 1024 else { send(status: 400, body: Data("{}".utf8)); return true }
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return false }

        let head = String(decoding: buf[buf.startIndex..<sep.lowerBound], as: UTF8.self)
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let request = lines.first else { return false }

        let parts = request.split(separator: " ")
        guard parts.count >= 2 else { send(status: 400, body: Data("{}".utf8)); return true }
        let method = String(parts[0])
        let target = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(target.first ?? "")
        let query = target.count > 1 ? String(target[1]) : ""

        var length = 0
        var token: String?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                length = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if lower.hasPrefix("x-nostrum-token:") {
                token = String(line.dropFirst(16)).trimmingCharacters(in: .whitespaces)
            }
        }

        let bodyStart = buf.distance(from: buf.startIndex, to: sep.upperBound)
        guard buf.count - bodyStart >= length else { return false }  // corps incomplet
        let lo = buf.index(buf.startIndex, offsetBy: bodyStart)
        let body = length > 0 ? buf.subdata(in: lo..<buf.index(lo, offsetBy: length)) : Data()

        let (status, payload, type) = route(method, path, query, body, token)
        send(status: status, body: payload, type: type)
        return true
    }

    private func send(status: Int, body: Data, type: String = "application/json; charset=utf-8") {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { [self] _ in finish() })
    }
}

// MARK: - Adresses locales

func localIPv4() -> [String] { localAddresses().map(\.ip) }

/// Type de connexion d'une interface (« en0 »…), demandé à macOS : le nom ne
/// suffit pas, en0 est le Wi-Fi d'un MacBook mais l'Ethernet d'un Mac mini.
func connectionKind(_ bsd: String) -> String {
    let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
    guard let i = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == bsd }),
          let type = SCNetworkInterfaceGetInterfaceType(i)
    else { return "Réseau" }
    if type == kSCNetworkInterfaceTypeIEEE80211 { return "Wi-Fi" }
    if type == kSCNetworkInterfaceTypeEthernet { return "Ethernet" }
    return "Réseau"
}

/// Adresses IPv4 du Mac, avec l'interface qui porte chacune.
func localAddresses() -> [(ip: String, interface: String)] {
    var out: [(ip: String, interface: String)] = []
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return out }
    defer { freeifaddrs(head) }

    for i in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let addr = i.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: i.pointee.ifa_name)
        guard name.hasPrefix("en") else { continue }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                       &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: host)
            // 169.254.x.x = pas de bail DHCP, inutilisable par le Kindle.
            if !ip.hasPrefix("169.254") { out.append((ip, name)) }
        }
    }
    return out
}

// MARK: - config.lua du Kindle

/// Chaîne Lua entre guillemets. Le nom de ville vient d'un service tiers : rien
/// ne doit pouvoir sortir de la chaîne et devenir du code sur le Kindle.
func luaString(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n", "\r": out += " "
        default: out.unicodeScalars.append(c)
        }
    }
    return out + "\""
}

// MARK: - Écran de veille de la Kindle

/// Image choisie dans la fenêtre, servie au Kindle sur /screensaver. Le Kindle
/// la télécharge quand son identifiant (date + taille) change, à sa synchro.
let screensaverFile = supportDir.appendingPathComponent("veille.png")

func screensaverInfo() -> [String: Any]? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: screensaverFile.path),
          let size = (attrs[.size] as? NSNumber)?.intValue, size > 0,
          let date = attrs[.modificationDate] as? Date
    else { return nil }
    return ["id": "\(Int(date.timeIntervalSince1970))-\(size)", "size": size]
}

/// PNG, côté le plus long ramené à 1600 px : assez pour tout écran de Kindle,
/// assez léger pour passer vite en Wi-Fi. Le Kindle passe lui-même en gris.
func storeScreensaver(from url: URL) throws {
    guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
        throw NSError(domain: appName, code: 3, userInfo: [NSLocalizedDescriptionKey: "Image illisible."])
    }
    let scale = min(1, 1600 / max(image.size.width, image.size.height))
    let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw NSError(domain: appName, code: 3, userInfo: [NSLocalizedDescriptionKey: "Conversion impossible."]) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: appName, code: 3, userInfo: [NSLocalizedDescriptionKey: "Conversion impossible."])
    }
    try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try png.write(to: screensaverFile, options: .atomic)
}

// MARK: - Secours iCloud

/// Mot de passe d'application du secours iCloud, dans le trousseau de session.
/// Il ne sort de là que pour config.lua, sur la Kindle — qui n'a pas d'autre
/// moyen de lire l'agenda Mac éteint.
enum ICloudPassword {
    private static let service = "\(bundleID).icloud"

    private static func query(_ user: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service]
        if let user { q[kSecAttrAccount as String] = user }
        return q
    }

    static func read(_ user: String) -> String? {
        var q = query(user)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ user: String, _ password: String) -> Bool {
        delete()
        var q = query(user)
        q[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    /// Tous les comptes du service : un seul secours à la fois.
    static func delete() { SecItemDelete(query(nil) as CFDictionary) }
}

/// Même requête que la Kindle au début de sa découverte CalDAV : si iCloud
/// l'accepte ici, il l'acceptera là-bas. Rend nil si c'est bon, sinon le
/// message à afficher. NOSTRUM_CALDAV remplace le serveur pour les essais.
func verifyICloud(_ user: String, _ password: String, done: @escaping (String?) -> Void) {
    var req = URLRequest(url: URL(string: ProcessInfo.processInfo.environment["NOSTRUM_CALDAV"]
        ?? "https://caldav.icloud.com/")!)
    req.httpMethod = "PROPFIND"
    req.timeoutInterval = 20
    req.setValue("0", forHTTPHeaderField: "Depth")
    req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
    req.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(),
                 forHTTPHeaderField: "Authorization")
    req.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>
        """.utf8)
    URLSession.shared.dataTask(with: req) { _, response, error in
        // Sur un 401, URLSession n'a pas de réponse à rendre : sans délégué pour
        // répondre au défi d'authentification, il l'annule (-1012). C'est
        // donc, ici, un refus d'identifiants et non une panne réseau.
        let refused = (error as? URLError)?.code == .userCancelledAuthentication
        let code = refused ? 401 : (response as? HTTPURLResponse)?.statusCode ?? 0
        let message: String?
        if let error, !refused {
            message = "iCloud injoignable : \(error.localizedDescription)"
        } else if code == 207 {
            message = nil
        } else if code == 401 || code == 403 {
            message = """
                Identifiants refusés par iCloud. Il faut un mot de passe d'application, \
                pas le mot de passe principal de votre compte Apple.
                """
        } else {
            message = "Réponse inattendue d'iCloud (code \(code))."
        }
        DispatchQueue.main.async { done(message) }
    }.resume()
}

func kindleConfig(_ s: Settings) -> String {
    let urls = localIPv4().map { luaString("http://\($0):\(s.port)") }.joined(separator: ", ")
    let weather: String
    if let city = s.city, let lat = s.lat, let lon = s.lon {
        weather = "{ enabled = true, name = \(luaString(city.uppercased())), lat = \(lat), lon = \(lon) }"
    } else {
        weather = "{ enabled = false }"
    }
    // Secours iCloud : seulement s'il a été vérifié et enregistré dans l'app.
    var icloud = ""
    if let user = s.icloudUser, let password = ICloudPassword.read(user) {
        icloud = """

            -- Secours Mac éteint : l'agenda est lu directement sur iCloud.
            -- Mot de passe d'application, révocable sur account.apple.com sans
            -- toucher au compte. Les rappels, eux, demandent toujours le Mac.
            username = \(luaString(user)),
            password = \(luaString(password)),

        """
    }
    let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
    return """
    -- Écrit par l'application Nostrum du Mac le \(date).
    -- Pour le régénérer : rebrancher la Kindle et cliquer « Installer sur la Kindle ».
    -- Le jeton ci-dessous donne accès à vos rappels : ne pas le partager.
    return {
        bridge_token = \(luaString(s.token)),
        bridge_port = \(s.port),
        -- Adresses du Mac à l'installation. Si elles changent, le Kindle
        -- retrouve le Mac seul sur le réseau local.
        bridge_url = { \(urls) },
    \(icloud)
        days = 1,              -- jours d'agenda affichés
        refresh_minutes = 60,  -- resynchro automatique écran ouvert
        tz_offset = 0,         -- correction d'heure en secondes, si décalée

        weather = \(weather),
    }

    """
}

/// Géocodage Open-Meteo : sans clé ni compte, le même service que la météo du
/// Kindle. Rend le nom officiel et les coordonnées de la première réponse.
func geocode(_ city: String, done: @escaping (Result<(String, Double, Double), Error>) -> Void) {
    var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
    c.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"),
                    .init(name: "language", value: "fr"), .init(name: "format", value: "json")]
    URLSession.shared.dataTask(with: c.url!) { data, _, error in
        let fail = { (msg: String) in
            done(.failure(NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: msg])))
        }
        if let error { return fail("Service météo injoignable : \(error.localizedDescription)") }
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["results"] as? [[String: Any]])?.first,
              let name = first["name"] as? String,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double
        else { return fail("Ville « \(city) » introuvable.") }
        done(.success((name, lat, lon)))
    }.resume()
}

// MARK: - Nouvelle version

/// Version officielle, publiée par pont/publier.sh : { "version", "dmg" }.
/// L'application ne se remplace pas elle-même : elle signale la nouvelle
/// version et propose de télécharger le DMG. NOSTRUM_FEED la remplace pour
/// les essais.
let versionFeed = URL(string: ProcessInfo.processInfo.environment["NOSTRUM_FEED"]
    ?? "https://raw.githubusercontent.com/david-guia/nostrum-releases/main/latest.json")!
let downloadDMG = URL(string: "https://github.com/david-guia/nostrum-releases/raw/main/Nostrum.dmg")!
let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

/// « 1.10 » est plus récent que « 1.9 » : comparaison champ par champ. Plus
/// récente seulement : une version de travail en avance ne doit rien proposer.
func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}

/// Rend la version publiée si elle est plus récente que celle qui tourne.
/// Sans réseau ou sans réponse lisible : rien, on réessaiera plus tard.
func checkLatest(_ found: @escaping (String, URL) -> Void) {
    var req = URLRequest(url: versionFeed)
    req.cachePolicy = .reloadIgnoringLocalCacheData
    URLSession.shared.dataTask(with: req) { data, _, _ in
        guard let data,
              let feed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = feed["version"] as? String, isNewer(version, than: currentVersion)
        else { return }
        let dmg = (feed["dmg"] as? String).flatMap(URL.init(string:)) ?? downloadDMG
        DispatchQueue.main.async { found(version, dmg) }
    }.resume()
}

/// Rangée dans un dossier Applications : seule cette copie s'inscrit au
/// démarrage et se met à jour. Lancée depuis le DMG ou un dossier de travail,
/// elle n'a à faire ni l'un ni l'autre.
func isInstalled() -> Bool {
    let path = Bundle.main.bundlePath
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
}

// MARK: - Ouverture de session

let launchAgent = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")

/// Le pont doit tourner pour que le Kindle se synchronise : il démarre donc à
/// l'ouverture de session. Réécrit si l'application a changé de place, sinon
/// launchd lancerait un chemin mort.
func registerAtLogin() {
    guard isInstalled(), let exe = Bundle.main.executablePath else { return }
    let plist: [String: Any] = [
        "Label": bundleID,
        "ProgramArguments": [exe, "--login"],
        "RunAtLoad": true,
    ]
    if let cur = NSDictionary(contentsOf: launchAgent), cur.isEqual(to: plist) { return }
    try? FileManager.default.createDirectory(at: launchAgent.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    (plist as NSDictionary).write(to: launchAgent, atomically: true)
}

// MARK: - Démarrage

setvbuf(stdout, nil, _IOLBF, 0)

func die(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

// Lancé deux fois (ouverture de session + double-clic), le second échouerait sur
// le port déjà pris : il laisse la main au premier.
if let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .first(where: { $0 != NSRunningApplication.current }) {
    other.activate()
    exit(0)
}

let atLogin = CommandLine.arguments.contains("--login")
var settings = Settings.load()
let store = Store()
let prefs = Prefs()
let plugin = PluginSource(dir: (Bundle.main.resourceURL ?? URL(fileURLWithPath: "."))
    .appendingPathComponent("nostrum.koplugin"))

func json(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
}

/// Pastille du Dock : les tâches que le Kindle affiche, pas le total du compte,
/// qui ressemblerait à des notifications en attente.
func updateBadge(_ todos: [[String: Any]]? = nil) {
    let n = (todos ?? store.incomplete()).filter { prefs.isOn(.lists, $0["list"] as? String ?? "") }.count
    DispatchQueue.main.async { NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil }
}

func route(method: String, path: String, query: String, body: Data, given: String?) -> (Int, Data, String) {
    let asJSON = "application/json; charset=utf-8"
    guard given == settings.token else { return (401, json(["error": "jeton invalide"]), asJSON) }

    switch (method, path) {
    case ("GET", "/todos"):
        let todos = store.incomplete()
        updateBadge(todos)
        return (200, json(["todos": todos]), asJSON)

    case ("POST", "/toggle"):
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = payload["id"] as? String
        else {
            return (400, json(["error": "corps invalide"]), asJSON)
        }
        let done = payload["done"] as? Bool ?? true
        if let err = store.toggle(id: id, done: done) {
            return (409, json(["error": err]), asJSON)
        }
        updateBadge()
        return (200, json(["ok": true]), asJSON)

    case ("GET", "/events"):
        let days = URLComponents(string: "?" + query)?.queryItems?
            .first(where: { $0.name == "days" })?.value.flatMap(Int.init) ?? 1
        return (200, json(["events": store.events(days: days)]), asJSON)

    case ("GET", "/prefs"):
        // L'image de veille y est annoncée : le Kindle ne la télécharge que si
        // son identifiant a changé depuis la dernière fois.
        var obj = prefs.json()
        if let veille = screensaverInfo() { obj["screensaver"] = veille }
        return (200, json(obj), asJSON)

    case ("GET", "/screensaver"):
        guard let data = try? Data(contentsOf: screensaverFile) else {
            return (404, json(["error": "aucune image de veille"]), asJSON)
        }
        return (200, data, "image/png")

    case ("GET", "/plugin"):
        return (200, json(plugin.manifest()), asJSON)

    default:
        // Un fichier du plugin. Le nom est validé par PluginSource contre la
        // liste réelle du dossier, jamais concaténé tel quel à un chemin.
        if method == "GET", path.hasPrefix("/plugin/") {
            let name = String(path.dropFirst("/plugin/".count))
            guard let data = plugin.read(name) else {
                return (404, json(["error": "fichier non servi"]), asJSON)
            }
            return (200, data, "text/plain; charset=utf-8")
        }
        return (404, json(["error": "route inconnue"]), asJSON)
    }
}

let params = NWParameters.tcp
params.allowLocalEndpointReuse = true

guard let nwPort = NWEndpoint.Port(rawValue: UInt16(settings.port)),
      let listener = try? NWListener(using: params, on: nwPort)
else {
    die("Impossible d'ecouter sur le port \(settings.port).", 4)
}

let queue = DispatchQueue(label: "nostrum.pont")

// Les connexions doivent être retenues le temps de la requête, sinon elles sont
// libérées dès la sortie du handler et le client ne reçoit jamais de réponse.
// Mutée uniquement depuis `queue`, qui est série : pas de verrou nécessaire.
var peers: [ObjectIdentifier: Peer] = [:]

listener.newConnectionHandler = { conn in
    let peer = Peer(conn: conn, route: route)
    let key = ObjectIdentifier(peer)
    peers[key] = peer
    peer.start(on: queue) { peers.removeValue(forKey: key) }
}

// MARK: - Fenêtre

// MARK: - Style console

/// Le langage de l'écran Kindle : fond noir, encre blanche, gris pour le
/// secondaire, chasse fixe en capitales espacées, cadres à titre inversé.
enum Console {
    static let ink = NSColor.white
    static let dim = NSColor(white: 0.66, alpha: 1)
    static let faint = NSColor(white: 0.36, alpha: 1)
    static let back = NSColor.black
    static let well = NSColor(white: 0.09, alpha: 1)

    static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// Capitales espacées, comme les libellés du Kindle.
    static func caps(_ text: String, size: CGFloat = 11, color: NSColor = ink,
                     bold: Bool = false, kern: CGFloat = 1.6) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: font(size, bold: bold), .foregroundColor: color, .kern: kern])
    }

    static func label(_ text: String, size: CGFloat = 10, color: NSColor = dim, bold: Bool = false) -> NSTextField {
        NSTextField(labelWithAttributedString: caps(text, size: size, color: color, bold: bold))
    }

    /// Phrases : pas de capitales forcées, la lisibilité d'abord.
    static func note(_ text: String, width: CGFloat = 560) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = font(11)
        t.textColor = dim
        t.preferredMaxLayoutWidth = width
        return t
    }

    /// Champ de saisie : un puits sombre cerné d'un trait. Le champ natif ne
    /// sait pas se donner de marge intérieure : il est posé, sans bordure, dans
    /// un cadre qui lui en donne une, et centré verticalement.
    static func boxed(_ f: NSTextField, placeholder: String, width: CGFloat = 440) -> NSView {
        f.font = font(13)
        f.textColor = ink
        f.drawsBackground = false
        f.isBezeled = false
        f.isBordered = false
        f.focusRingType = .none
        f.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font(13), .foregroundColor: faint])
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = well.cgColor
        box.layer?.borderColor = dim.cgColor
        box.layer?.borderWidth = 1
        f.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(f)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            box.heightAnchor.constraint(equalToConstant: 30),
            f.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            f.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            f.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    /// Libellé collé à son champ : la paire se lit comme un seul bloc.
    static func field(_ title: String, _ box: NSView) -> NSStackView {
        column([label(title), box], spacing: 6)
    }

    static func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = spacing
        return r
    }

    /// `fill` : les cadres prennent toute la largeur de la colonne, pour que
    /// tous les onglets s'arrêtent au même bord.
    static func column(_ views: [NSView], spacing: CGFloat = 10, fill: Bool = false) -> NSStackView {
        let c = NSStackView(views: views)
        c.orientation = .vertical
        c.alignment = .leading
        c.spacing = spacing
        if fill {
            for v in views where v is FrameView || v is NSStackView {
                v.widthAnchor.constraint(equalTo: c.widthAnchor).isActive = true
            }
        }
        return c
    }
}

/// Bouton encadré, capitales espacées. « primary » : plein, encre inversée,
/// comme le bandeau du Kindle. S'inverse sous le doigt.
final class ConsoleButton: NSButton {
    private var label = ""
    var primary = false { didSet { paint() } }
    var selectedTab = false { didSet { paint() } }
    private var pressed = false

    convenience init(_ title: String, target: AnyObject?, action: Selector?, primary: Bool = false) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        self.label = title
        self.primary = primary
        isBordered = false
        wantsLayer = true
        layer?.borderWidth = 1.5
        setButtonType(.momentaryChange)
        paint()
    }

    func setLabel(_ text: String) { label = text; paint() }

    override var isEnabled: Bool { didSet { paint() } }

    override var intrinsicContentSize: NSSize {
        let s = attributedTitle.size()
        return NSSize(width: ceil(s.width) + 26, height: 26)
    }

    private func paint() {
        let filled = (primary || selectedTab) != pressed
        let fg = !isEnabled ? Console.faint : filled ? Console.back : Console.ink
        layer?.backgroundColor = (filled && isEnabled ? Console.ink : Console.back).cgColor
        layer?.borderColor = (isEnabled ? (selectedTab || primary ? Console.ink : Console.dim) : Console.faint).cgColor
        attributedTitle = Console.caps(label, size: 11, color: fg, bold: true)
        invalidateIntrinsicContentSize()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; paint()
        super.mouseDown(with: event)   // boucle de suivi : rend la main au relâcher
        pressed = false; paint()
    }
}

/// Case à cocher façon terminal : [■] coché, [ ] non coché.
final class ConsoleCheck: NSButton {
    let name: String

    init(_ name: String, on: Bool, target: AnyObject, action: Selector) {
        self.name = name
        super.init(frame: .zero)
        setButtonType(.pushOnPushOff)
        isBordered = false
        self.target = target
        self.action = action
        state = on ? .on : .off
        paint()
    }

    required init?(coder: NSCoder) { fatalError() }

    func paint() {
        let on = state == .on
        // Espaces de bord retirés à l'affichage seulement (« Organisation
        // Générale » en porte un) : le nom réel reste celui transmis au Kindle.
        let shown = name.trimmingCharacters(in: .whitespaces)
        attributedTitle = NSAttributedString(string: (on ? "[■] " : "[ ] ") + shown, attributes: [
            .font: Console.font(12), .foregroundColor: on ? Console.ink : Console.dim])
    }
}

/// Cadre du Kindle : un trait, le titre en étiquette inversée posée dessus.
final class FrameView: NSView {
    private let title: String
    override var isFlipped: Bool { true }

    init(_ title: String, _ content: NSView) {
        self.title = title
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Console.ink.setStroke()
        let border = NSBezierPath(rect: NSRect(x: 0.5, y: 9.5, width: bounds.width - 1, height: bounds.height - 10))
        border.lineWidth = 1
        border.stroke()
        let text = Console.caps(title, size: 11, color: Console.back, bold: true, kern: 2)
        let size = text.size()
        let tag = NSRect(x: 12, y: 0, width: ceil(size.width) + 16, height: 19)
        Console.ink.setFill()
        tag.fill()
        text.draw(at: NSPoint(x: tag.minX + 8, y: (tag.height - size.height) / 2))
    }
}

/// Bandeau plein du haut, texte en négatif, l'état du pont à droite.
final class BandView: NSView {
    var status = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Console.ink.setFill()
        bounds.fill()
        let title = Console.caps("Nostrum", size: 20, color: Console.back, bold: true, kern: 5)
        title.draw(at: NSPoint(x: 14, y: (bounds.height - title.size().height) / 2))
        let sub = Console.caps("Ordinateur de bord", size: 9, color: Console.back, kern: 2)
        sub.draw(at: NSPoint(x: 14 + title.size().width + 22, y: (bounds.height - sub.size().height) / 2 + 2))
        let right = Console.caps(status, size: 10, color: Console.back, bold: true, kern: 2)
        right.draw(at: NSPoint(x: bounds.width - right.size().width - 14, y: (bounds.height - right.size().height) / 2))
    }
}

/// Fond noir, double cadre et équerres aux coins, comme le pourtour de l'écran.
final class RootView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Console.back.setFill()
        bounds.fill()
        let top: CGFloat = 30   // sous la barre de titre transparente
        for (inset, color) in [(CGFloat(6), Console.faint), (CGFloat(12), Console.ink)] {
            color.setStroke()
            let r = NSRect(x: inset + 0.5, y: top + inset - 6 + 0.5,
                           width: bounds.width - 2 * inset - 1, height: bounds.height - top - 2 * inset + 6 - 1)
            let p = NSBezierPath(rect: r)
            p.lineWidth = 1
            p.stroke()
        }
        // Équerres pleines aux quatre coins du cadre intérieur.
        Console.ink.setFill()
        let x0: CGFloat = 12, y0 = top + 6, x1 = bounds.width - 12, y1 = bounds.height - 12
        let l: CGFloat = 22, t: CGFloat = 3
        for (cx, cy, sx, sy) in [(x0, y0, 1.0, 1.0), (x1, y0, -1.0, 1.0), (x0, y1, 1.0, -1.0), (x1, y1, -1.0, -1.0)] {
            NSRect(x: min(cx, cx + sx * l), y: min(cy, cy + sy * t), width: l, height: t).fill()
            NSRect(x: min(cx, cx + sx * t), y: min(cy, cy + sy * l), width: t, height: l).fill()
        }
    }
}

/// Trois blocs : installer sur la Kindle, choisir les sources, l'état du pont.
/// Ouverte au lancement manuel et par un clic sur l'icône du Dock ; jamais à
/// l'ouverture de session, où elle serait une interruption et pas un service.
final class Panel: NSObject, NSApplicationDelegate {
    private let window = NSWindow(contentRect: .zero,
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
    private var boxes: [(ConsoleCheck, Prefs.Kind, [String])] = []
    private let city = NSTextField(string: "")
    private let icloudUser = NSTextField(string: "")
    private let icloudPassword = NSSecureTextField(string: "")
    private let icloudState = NSTextField(wrappingLabelWithString: "")
    private let screensaverPreview = NSImageView()
    private let kindleState = NSTextField(labelWithString: "")
    private let installButton = ConsoleButton("Installer sur la Kindle", target: nil, action: nil, primary: true)
    private var cityBox = NSView()
    private var userBox = NSView()
    private var passwordBox = NSView()
    private let updateButton = ConsoleButton("", target: nil, action: nil, primary: true)
    private let band = BandView()
    private let tabHost = NSView()
    private var tabButtons: [ConsoleButton] = []
    private var tabViews: [NSView] = []
    private var tab = 0
    /// Version publiée plus récente, et le DMG à télécharger.
    private var available: (version: String, dmg: URL)?
    private var timer: Timer?
    var listening = false
    var accessDenied: [String] = []

    override init() {
        super.init()
        window.title = appName
        // Par défaut une NSWindow est détruite quand on la ferme : la propriété
        // pointerait alors dans le vide et les clics suivants sur l'icône du
        // Dock n'ouvriraient plus rien. On la garde, on la cache.
        window.isReleasedWhenClosed = false
        // Fenêtre noire, barre de titre fondue dans le cadre : tout l'écran est
        // la console. Apparence sombre pour les alertes et le curseur de saisie.
        window.appearance = NSAppearance(named: .darkAqua)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Console.back
        installButton.target = self
        installButton.action = #selector(installOnKindle)
        installButton.keyEquivalent = "\r"
        cityBox = Console.boxed(city, placeholder: "Dijon — vide = sans météo")
        city.stringValue = settings.city ?? ""
        userBox = Console.boxed(icloudUser, placeholder: "adresse@icloud.com")
        icloudUser.stringValue = settings.icloudUser ?? ""
        passwordBox = Console.boxed(icloudPassword, placeholder: "xxxx-xxxx-xxxx-xxxx")
        icloudState.font = Console.font(11)
        icloudState.preferredMaxLayoutWidth = 560
        updateButton.target = self
        updateButton.action = #selector(download)
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(self, selector: #selector(refreshKindle), name: n, object: nil)
        }
    }

    // MARK: Kindle

    /// Un volume portant un dossier koreader/ : la Kindle jailbreakée, quel que
    /// soit le nom qu'elle donne à son volume.
    private func kindleVolume() -> URL? {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                         options: [.skipHiddenVolumes]) ?? []
        return vols.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("koreader").path) }
    }

    @objc func refreshKindle() {
        if let v = kindleVolume() {
            kindleState.attributedStringValue = Console.caps("● Kindle détectée : \(v.lastPathComponent)", color: Console.ink, bold: true)
            installButton.isEnabled = true
        } else {
            kindleState.attributedStringValue = Console.caps("○ Kindle non branchée", color: Console.dim)
            installButton.isEnabled = false
        }
    }

    /// La ville est géocodée seulement si elle a changé : réinstaller sans
    /// réseau reste possible avec la ville déjà connue.
    private func resolveCity(then next: @escaping () -> Void) {
        let wanted = city.stringValue.trimmingCharacters(in: .whitespaces)
        if wanted.isEmpty {
            settings.city = nil; settings.lat = nil; settings.lon = nil
            settings.save()
            return next()
        }
        if wanted.caseInsensitiveCompare(settings.city ?? "") == .orderedSame, settings.lat != nil {
            return next()
        }
        geocode(wanted) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let (name, lat, lon)):
                    settings.city = name; settings.lat = lat; settings.lon = lon
                    settings.save()
                    self.city.stringValue = name
                    next()
                case .failure(let e):
                    self.alert("Météo", e.localizedDescription)
                }
            }
        }
    }

    @objc func installOnKindle() {
        guard let vol = kindleVolume() else { return refreshKindle() }
        resolveCity {
            let target = vol.appendingPathComponent("koreader/plugins/nostrum.koplugin")
            do {
                try plugin.install(into: target, config: kindleConfig(settings))
            } catch {
                return self.alert("Installation impossible", error.localizedDescription)
            }
            let a = NSAlert()
            a.messageText = "Nostrum est installé sur la Kindle."
            a.informativeText = """
                1. Éjectez la Kindle et débranchez-la.
                2. Redémarrez KOReader.
                3. Menu ☰ → Outils → Nostrum → Ouvrir.

                Laissez ce Mac allumé et Nostrum ouvert : c'est lui qui sert l'agenda et les rappels.\(settings.icloudUser == nil ? "" : "\nMac éteint, l'agenda sera lu directement sur iCloud.")
                """
            a.addButton(withTitle: "Éjecter la Kindle")
            a.addButton(withTitle: "Plus tard")
            if a.runModal() == .alertFirstButtonReturn {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: vol) }
                catch { self.alert("Éjection impossible", error.localizedDescription) }
            }
        }
    }

    /// Pour une Kindle qui ne monte pas comme un disque (protocole MTP) : le
    /// dossier est préparé ici et copié à la main dans koreader/plugins/.
    @objc func saveToFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Enregistrer ici"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        resolveCity {
            let target = dir.appendingPathComponent("nostrum.koplugin")
            do {
                try plugin.install(into: target, config: kindleConfig(settings))
            } catch {
                return self.alert("Enregistrement impossible", error.localizedDescription)
            }
            NSWorkspace.shared.activateFileViewerSelecting([target])
            self.alert("Dossier prêt",
                       "Copiez « nostrum.koplugin » dans koreader/plugins/ sur la Kindle, puis redémarrez KOReader.")
        }
    }

    // MARK: Secours iCloud

    private func refreshICloud() {
        if let user = settings.icloudUser, ICloudPassword.read(user) != nil {
            icloudState.stringValue = "● Enregistré pour \(user). Réinstallez sur la Kindle pour le lui transmettre."
            icloudState.textColor = Console.ink
        } else {
            icloudState.stringValue = "○ Non configuré : Mac éteint, la Kindle n'affichera plus l'agenda."
            icloudState.textColor = Console.dim
        }
    }

    @objc func saveICloud() {
        let user = icloudUser.stringValue.trimmingCharacters(in: .whitespaces)
        let password = icloudPassword.stringValue.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !password.isEmpty else {
            return alert("Secours iCloud", "Renseignez l'identifiant Apple et le mot de passe d'application.")
        }
        icloudState.stringValue = "Vérification auprès d'iCloud…"
        verifyICloud(user, password) { problem in
            if let problem {
                self.refreshICloud()
                return self.alert("Secours iCloud non enregistré", problem)
            }
            guard ICloudPassword.save(user, password) else {
                self.refreshICloud()
                return self.alert("Secours iCloud", "Impossible d'enregistrer le mot de passe dans le trousseau.")
            }
            settings.icloudUser = user
            settings.save()
            self.icloudPassword.stringValue = ""
            self.refreshICloud()
            self.alert("Secours iCloud enregistré",
                       "Rebranchez la Kindle et cliquez « Installer sur la Kindle » pour le lui transmettre.")
        }
    }

    @objc func removeICloud() {
        ICloudPassword.delete()
        settings.icloudUser = nil
        settings.save()
        icloudUser.stringValue = ""
        icloudPassword.stringValue = ""
        refreshICloud()
        alert("Secours iCloud retiré",
              "Réinstallez sur la Kindle pour l'effacer aussi de son config.lua, puis révoquez le mot de passe d'application sur account.apple.com.")
    }

    // MARK: Écran de veille

    private func refreshScreensaver() {
        screensaverPreview.image = NSImage(contentsOf: screensaverFile)
    }

    @objc func chooseScreensaver() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choisir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try storeScreensaver(from: url)
        } catch {
            return alert("Image de veille", error.localizedDescription)
        }
        refreshScreensaver()
        alert("Image de veille enregistrée",
              "La Kindle la récupère à sa prochaine synchronisation (ou touchez le bas de son écran).")
    }

    @objc func removeScreensaver() {
        try? FileManager.default.removeItem(at: screensaverFile)
        refreshScreensaver()
        alert("Image de veille retirée",
              "La Kindle garde l'image qu'elle a déjà ; changez-la depuis KOReader si besoin.")
    }

    @objc func openAppleAccount() {
        NSWorkspace.shared.open(URL(string: "https://account.apple.com")!)
    }

    // MARK: Désinstallation

    @objc func uninstall() {
        let a = NSAlert()
        a.messageText = "Désinstaller Nostrum ?"
        a.informativeText = """
            Le lancement à l'ouverture de session et les réglages de ce Mac seront supprimés. \
            Vos rappels et votre agenda ne sont pas touchés.
            Il restera à mettre l'application à la corbeille, et à supprimer \
            koreader/plugins/nostrum.koplugin sur la Kindle.
            """
        a.addButton(withTitle: "Désinstaller")
        a.addButton(withTitle: "Annuler")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: launchAgent)
        try? FileManager.default.removeItem(at: supportDir)
        ICloudPassword.delete()
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApp.terminate(nil)
    }

    // MARK: Construction

    private func sourcesTab() -> NSView {
        var cols: [NSView] = []
        for (kind, titre, entite) in [(Prefs.Kind.calendars, "Calendriers", EKEntityType.event),
                                      (Prefs.Kind.lists, "Listes de rappels", EKEntityType.reminder)] {
            let noms = store.sources(entite)
            var rows: [NSView] = []
            if noms.isEmpty {
                // Le cas d'un accès refusé : le dire, plutôt qu'une colonne
                // vide qu'on prendrait pour un compte sans calendrier.
                rows.append(Console.note("Accès refusé ou aucune source.\nRéglages Système → Confidentialité et sécurité → \(titre == "Calendriers" ? "Calendriers" : "Rappels").", width: 250))
            }
            for nom in noms {
                let b = ConsoleCheck(nom, on: prefs.isOn(kind, nom), target: self, action: #selector(clic(_:)))
                boxes.append((b, kind, noms))
                rows.append(b)
            }
            cols.append(FrameView(titre, Console.column(rows, spacing: 7)))
        }
        let colonnes = Console.row(cols, spacing: 18)
        colonnes.alignment = .top
        colonnes.distribution = .fillEqually
        return Console.column([
            colonnes,
            Console.note("[■] = affiché sur le Kindle. Tout décocher revient à tout afficher."),
        ], spacing: 12, fill: true)
    }

    private func kindleTab() -> NSView {
        let save = ConsoleButton("Enregistrer dans un dossier…", target: self, action: #selector(saveToFolder))
        return Console.column([
            FrameView("Installation", Console.column([
                kindleState,
                Console.field("Ville pour la météo", cityBox),
                Console.row([installButton, save]),
                Console.note("Kindle qui ne s'ouvre pas comme un disque : « Enregistrer dans un dossier », puis copier ce dossier dans koreader/plugins/."),
            ], spacing: 16)),
        ], fill: true)
    }

    private func icloudTab() -> NSView {
        let verify = ConsoleButton("Vérifier et enregistrer", target: self, action: #selector(saveICloud), primary: true)
        let create = ConsoleButton("Créer un mot de passe…", target: self, action: #selector(openAppleAccount))
        let drop = ConsoleButton("Retirer", target: self, action: #selector(removeICloud))
        refreshICloud()
        return Console.column([
            FrameView("Agenda sans le Mac", Console.column([
                Console.note("Mac éteint, la Kindle peut lire l'agenda iCloud directement. Il faut un mot de passe d'application Apple : compte Apple → Connexion et sécurité → Mots de passe pour les apps. Les rappels demandent toujours le Mac."),
                Console.field("Identifiant Apple", userBox),
                Console.field("Mot de passe d'application", passwordBox),
                Console.row([verify, create, drop]),
                icloudState,
            ], spacing: 16)),
        ], fill: true)
    }

    private func veilleTab() -> NSView {
        screensaverPreview.imageScaling = .scaleProportionallyUpOrDown
        screensaverPreview.wantsLayer = true
        screensaverPreview.layer?.borderColor = Console.ink.cgColor
        screensaverPreview.layer?.borderWidth = 1
        screensaverPreview.layer?.backgroundColor = Console.well.cgColor
        if screensaverPreview.constraints.isEmpty {
            screensaverPreview.widthAnchor.constraint(equalToConstant: 120).isActive = true
            screensaverPreview.heightAnchor.constraint(equalToConstant: 160).isActive = true
        }
        refreshScreensaver()
        let pick = ConsoleButton("Choisir une image…", target: self, action: #selector(chooseScreensaver), primary: true)
        let unpick = ConsoleButton("Retirer", target: self, action: #selector(removeScreensaver))
        let col = Console.column([
            Console.note("Image affichée par la Kindle pendant la veille. Elle lui est transmise à sa prochaine synchronisation, sans câble.", width: 380),
            Console.row([pick, unpick]),
        ], spacing: 14)
        let row = Console.row([screensaverPreview, col], spacing: 18)
        row.alignment = .top
        return Console.column([FrameView("Écran de veille", row)], fill: true)
    }

    private func systemTab() -> NSView {
        // Libellé et valeur posés sur la même ligne de base, comme la grille
        // du Kindle : centrés, deux tailles de police se décalent.
        func line(_ key: String, _ value: String) -> NSView {
            let k = Console.label(key)
            k.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let r = Console.row([k, NSTextField(labelWithAttributedString: Console.caps(value, size: 12, bold: true))])
            r.alignment = .firstBaseline
            return r
        }
        // Une adresse par ligne, avec sa connexion : le Mac en a une par
        // interface (câble, Wi-Fi), et le Kindle bascule de l'une à l'autre.
        func addresses() -> NSView {
            let found = localAddresses()
            if found.isEmpty { return line("Adresses", "Aucun réseau local") }
            return Console.column(found.enumerated().map { n, a in
                let k = Console.label(n == 0 ? "Adresses" : "")
                k.widthAnchor.constraint(equalToConstant: 150).isActive = true
                let v = NSTextField(labelWithAttributedString: Console.caps("\(a.ip):\(settings.port)", size: 12, bold: true))
                v.widthAnchor.constraint(equalToConstant: 210).isActive = true
                let r = Console.row([k, v, Console.label(connectionKind(a.interface))])
                r.alignment = .firstBaseline
                return r
            }, spacing: 6)
        }
        let remove = ConsoleButton("Désinstaller…", target: self, action: #selector(uninstall))
        return Console.column([
            FrameView("État du pont", Console.column([
                addresses(),
                line("Version", plugin.version()),
                line("Mise à jour", available.map { "\($0.version) disponible" } ?? "À jour"),
            ], spacing: 9)),
            FrameView("Maintenance", Console.column([
                Console.note("Supprime le lancement à l'ouverture de session et les réglages de ce Mac. Vos rappels et votre agenda ne sont pas touchés."),
                remove,
            ], spacing: 12)),
        ], spacing: 16, fill: true)
    }

    /// Reconstruite à chaque ouverture : un calendrier ajouté côté iCloud doit
    /// apparaître sans relancer l'application, et l'accès peut avoir été
    /// accordé entre-temps.
    private func build() {
        boxes.removeAll()
        refreshKindle()
        let titles = ["Kindle", "Sources", "Secours iCloud", "Veille", "Système"]
        tabViews = [kindleTab(), sourcesTab(), icloudTab(), veilleTab(), systemTab()]
        tabButtons = titles.enumerated().map { i, t in
            let b = ConsoleButton(t, target: self, action: #selector(selectTab(_:)))
            b.tag = i
            return b
        }

        let root = RootView()
        for v in [band, tabHost] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        let tabs = Console.row(tabButtons, spacing: 8)
        let bas = Console.row([updateButton])
        for v in [band, tabs, tabHost, bas] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        // Hauteur du contenu = celle du plus grand onglet : la fenêtre ne
        // saute pas d'un onglet à l'autre.
        let width: CGFloat = 660
        let contentH = tabViews.map { $0.fittingSize.height }.max() ?? 300
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            band.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            band.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            band.heightAnchor.constraint(equalToConstant: 40),
            tabs.topAnchor.constraint(equalTo: band.bottomAnchor, constant: 16),
            tabs.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            tabHost.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 18),
            tabHost.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            tabHost.trailingAnchor.constraint(equalTo: band.trailingAnchor),
            tabHost.heightAnchor.constraint(equalToConstant: contentH),
            bas.topAnchor.constraint(equalTo: tabHost.bottomAnchor, constant: 16),
            bas.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            bas.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -26),
            root.widthAnchor.constraint(equalToConstant: width + 52),
        ])
        refreshFooter()
        window.contentView = root
        showTab(tab)
        window.setContentSize(root.fittingSize)
        window.center()
    }

    private func showTab(_ i: Int) {
        tab = i
        tabHost.subviews.forEach { $0.removeFromSuperview() }
        let v = tabViews[i]
        v.translatesAutoresizingMaskIntoConstraints = false
        tabHost.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: tabHost.topAnchor),
            v.leadingAnchor.constraint(equalTo: tabHost.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: tabHost.trailingAnchor),
        ])
        for b in tabButtons { b.selectedTab = b.tag == i }
    }

    @objc private func selectTab(_ sender: NSButton) { showTab(sender.tag) }

    func refreshFooter() {
        // L'état du pont tient dans le bandeau ; adresses et version sont dans
        // l'onglet Système. Le pied ne porte que la mise à jour, s'il y en a une.
        updateButton.isHidden = available == nil
        updateButton.setLabel(available.map { "Télécharger la version \($0.version)" } ?? "")
        band.status = !listening ? "Démarrage" : "Pont actif"
    }

    @objc private func clic(_ sender: NSButton) {
        guard let check = sender as? ConsoleCheck,
              let (_, kind, noms) = boxes.first(where: { $0.0 === check }) else { return }
        check.paint()
        prefs.set(kind, check.name, on: check.state == .on, all: noms)
        DispatchQueue.global().async { updateBadge() }
    }

    // MARK: Nouvelle version

    @objc func download() {
        if let available { NSWorkspace.shared.open(available.dmg) }
    }

    /// Proposée une fois par version et par lancement : la question revient au
    /// prochain lancement si l'utilisateur a répondu « Plus tard ». Le bouton
    /// du pied de fenêtre, lui, reste tant que la version n'est pas installée.
    private func offer(_ version: String, _ dmg: URL) {
        guard available?.version != version else { return }
        available = (version, dmg)
        refreshFooter()
        let a = NSAlert()
        a.messageText = "Nostrum \(version) est disponible."
        a.informativeText = """
            Vous utilisez la version \(currentVersion). Téléchargez la nouvelle version, \
            ouvrez le DMG et glissez Nostrum dans Applications pour remplacer l'ancienne.
            Le Kindle proposera ensuite sa propre mise à jour à la synchronisation suivante.
            """
        a.addButton(withTitle: "Télécharger")
        a.addButton(withTitle: "Plus tard")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { download() }
    }

    func show() {
        build()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerAtLogin()
        // Version officielle vérifiée à l'ouverture puis toutes les 6 h : l'app
        // tourne en permanence, une vérification au lancement seul ne verrait
        // une publication qu'à l'ouverture de session suivante.
        checkLatest(offer)
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            checkLatest(self.offer)
        }
        if !atLogin { show() }
        // Accès demandés hors du fil principal : une invite système sans réponse
        // ne doit pas figer la fenêtre. La fenêtre se reconstruit ensuite, avec
        // les sources désormais lisibles.
        DispatchQueue.global().async {
            let r = store.requestAccess(.reminder)
            let e = store.requestAccess(.event)
            updateBadge()
            DispatchQueue.main.async {
                if !r || !e, !atLogin { self.alert("Accès refusé",
                    "Nostrum a besoin des Rappels et des Calendriers pour les afficher sur le Kindle.\nRéglages Système → Confidentialité et sécurité.") }
                if self.window.isVisible { self.build() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }
}

/// Menu minimal : sans menu Édition, ⌘V ne colle rien dans le champ de la ville.
func mainMenu() -> NSMenu {
    let menu = NSMenu()
    let app = NSMenu()
    app.addItem(withTitle: "Masquer \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(.separator())
    app.addItem(withTitle: "Quitter \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let edit = NSMenu(title: "Édition")
    edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    for sub in [app, edit] {
        let item = NSMenuItem()
        item.submenu = sub
        menu.addItem(item)
    }
    return menu
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.mainMenu = mainMenu()
let panel = Panel()
application.delegate = panel

listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        print("NOSTRUM — pont en ecoute sur le port \(settings.port) : \(localIPv4().joined(separator: ", "))")
        DispatchQueue.main.async { panel.listening = true; panel.refreshFooter() }
    case .failed(let e):
        // Le port est pris : une autre copie de Nostrum, presque toujours.
        DispatchQueue.main.async {
            panel.alert("Nostrum ne peut pas démarrer",
                        "Le port \(settings.port) est déjà utilisé (\(e)). Nostrum est-il déjà ouvert ?")
            NSApp.terminate(nil)
        }
    default:
        break
    }
}
listener.start(queue: queue)
application.run()
