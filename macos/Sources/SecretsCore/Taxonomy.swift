import Foundation

// Port à l'identique de `Taxonomy` (script Python `claude-secrets`, § classement par service).
// Le script Python sert d'oracle : voir Fixtures/ et docs/macos/oracle.py.

private func set(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

let TLDS = set("COM FR NET ORG IO AI DEV CH ME TO EU BE CO APP INFO XYZ TV SH DE ES NL CA US UK LY BEER")
let GENERIC = set("APP LOGIN ID ADMIN WP WWW DASHBOARD DASH API CLOUD CONSOLE PANEL ACCOUNT ACCOUNTS MY PORTAL SSO AUTH MANAGER MAIL SECURE GIT ONE OUTILS PROJETS PMA CONNECT")
let WORDS = set("API KEY TOKEN SECRET CLIENT ID USER USERNAME PASSWORD URL DB ACCESS ADMIN ROOT SUDO PERSONAL BOT WEBHOOK HTTP SSH FTP SMTP MAIL RECIPIENTS ENROLLMENT SECURITY UPDATES TRIGGER INSTANCE ADMINISTRATION MASTER DEFAULT")
private let secondLevel = set("co com org net gov gouv asso ac edu")
private let envRegex = try! NSRegularExpression(
    pattern: #"^(PROD|PRODUCTION|NEWPROD|PRE?PROD\w*|STAGING|STAGE|DEV|DDEV|LOCAL|LOCALHOST|DOCKER|TEST|RECETTE|DEMO|BETA)$"#)

func isEnv(_ s: String) -> Bool {
    envRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// `str.title()` de Python : majuscule après tout caractère non alphabétique.
public func pyTitle(_ s: String) -> String {
    var out = "", prevLetter = false
    for ch in s {
        if ch.isLetter { out += prevLetter ? ch.lowercased() : ch.uppercased(); prevLetter = true }
        else { out.append(ch); prevLetter = false }
    }
    return out
}

func normLabel(_ s: String) -> String {
    s.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
}

/// hubspot.com pour app.hubspot.com ; impots.gouv.fr reste entier.
public func registrable(_ host: String) -> String? {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    if labels.count < 2 { return nil }
    if labels.count >= 3, secondLevel.contains(labels[labels.count - 2]), labels[labels.count - 1].count == 2 {
        return labels.suffix(3).joined(separator: ".")
    }
    return labels.suffix(2).joined(separator: ".")
}

private func learnGeneric(_ split: [[String]]) -> Set<String> {
    var followers: [String: Set<String>] = [:], count: [String: Int] = [:]
    for t in split where t.count >= 3 && TLDS.contains(t[t.count - 1]) {
        let rest = t.dropLast().filter { !isEnv($0) }
        if rest.count >= 2, !(GENERIC.union(WORDS)).contains(rest[0]) {
            followers[rest[0], default: []].insert(rest[1]); count[rest[0], default: 0] += 1
        }
    }
    return Set(followers.filter { $0.value.count >= 4 && count[$0.key]! >= 4 }.keys)
}

private func significant(_ tokens: [String], _ generic: Set<String>) -> [String] {
    var t = tokens
    if t.count > 1, TLDS.contains(t[t.count - 1]) { t.removeLast() }
    let f = t.filter { !isEnv($0) }
    t = f.isEmpty ? t : f
    while t.count > 1, generic.contains(t[0]) { t.removeFirst() }
    return t
}

public struct Group: Equatable, Sendable {
    public enum Kind: String, Sendable { case service, project, sites, acces }
    public let id: String
    public let label: String
    public let kind: Kind
    public let manual: Bool
    public let members: [Entry]
}

public struct Taxonomy: Sendable {
    public private(set) var display: [String: String] = [:]
    public private(set) var key: [String: String?] = [:]
    public private(set) var domain: [String: Bool] = [:]
    public private(set) var projects = Set<String>()
    public private(set) var overridden = Set<String>()

    /// - Parameters:
    ///   - domains: {nom: hôte} issu de l'adresse web des éléments Bitwarden (prime sur le nom).
    ///   - overrides: {nom: groupe} choisi à la main (prime sur tout).
    public init(_ entries: [Entry], domains: [String: String] = [:], overrides: [String: String] = [:]) {
        var split: [String: [String]] = [:]
        for e in entries { split[e.base] = e.base.components(separatedBy: "_") }
        let generic = GENERIC.union(learnGeneric(entries.map { split[$0.base]! }))
        var sig: [String: [String]] = [:]
        for (b, t) in split { sig[b] = significant(t, generic) }
        func usable(_ t: String) -> Bool { t.count > 1 && !WORDS.contains(t) }
        var freq: [String: Int] = [:]
        for s in sig.values { for tok in Set(s) where usable(tok) { freq[tok, default: 0] += 1 } }

        // 1. service d'après l'adresse web
        var site: [String: (reg: String, subs: [String])] = [:]
        var siteOrder: [String] = []
        for e in entries {
            guard let host = domains[e.base], let reg = registrable(host) else { continue }
            let subs = host != reg ? String(host.dropLast(reg.count + 1)).components(separatedBy: ".") : []
            if site[e.base] == nil { siteOrder.append(e.base) }
            site[e.base] = (reg, subs)
        }
        var elsewhere: [String: Set<String>] = [:]
        for e in entries {
            let reg = site[e.base]?.reg
            var toks = Set(sig[e.base]!.filter(usable))
            if let reg { toks.insert(normLabel(String(reg.split(separator: ".")[0]))) }
            for t in toks { elsewhere[t, default: []].insert(reg ?? "\u{0}none") }
        }
        var domainKey: [String: String] = [:]
        for base in siteOrder {
            let (reg, subs) = site[base]!
            let tenants = subs.filter {
                let u = $0.uppercased().replacingOccurrences(of: "-", with: "_")
                return !isEnv(u) && !generic.contains(u)
            }
            let raw: String
            if let tenant = tenants.last, !(elsewhere[normLabel(tenant)] ?? []).subtracting([reg]).isEmpty {
                raw = tenant
            } else { raw = String(reg.split(separator: ".")[0]) }
            domainKey[base] = normLabel(raw)
            if display[normLabel(raw)] == nil { display[normLabel(raw)] = pyTitle(raw.replacingOccurrences(of: "-", with: " ")) }
        }
        let knownDomains = Set(domainKey.values)

        // 2. à défaut, d'après le nom
        for e in entries {
            let base = e.base, tokens = split[base]!
            if e.kind == .aws { key[base] = .some("AWS") }
            else if let k = domainKey[base] { key[base] = .some(k) }
            else {
                key[base] = .some(sig[base]!.first { usable($0) && ((freq[$0] ?? 0) >= 2 || knownDomains.contains($0)) })
            }
            domain[base] = site[base] != nil || (tokens.count > 1 && TLDS.contains(tokens[tokens.count - 1]))
        }
        // 3. le choix de l'utilisateur prime sur tout
        var forced = Set<String>()
        for e in entries {
            let label = (overrides[e.base] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty, !normLabel(label).isEmpty {
                let k = normLabel(label)
                key[e.base] = .some(k)
                if display[k] == nil { display[k] = label }
                overridden.insert(e.base); forced.insert(k)
            }
        }
        // Un mot partagé par une seule entrée n'est pas un service.
        var size: [String: Int] = [:]
        for v in key.values { if let k = v { size[k, default: 0] += 1 } }
        for (base, k) in key {
            if let k, k != "AWS", !forced.contains(k), (size[k] ?? 0) < 2 { key[base] = .some(nil) }
        }
        for (base, k) in key {
            let tokens = split[base]!
            let body = tokens.count > 1 && TLDS.contains(tokens[tokens.count - 1]) ? Array(tokens.dropLast()) : tokens
            let subs = site[base]?.subs ?? []
            if let k, k != "AWS",
               body.contains(where: isEnv) || subs.contains(where: { isEnv($0.uppercased().replacingOccurrences(of: "-", with: "_")) }) {
                projects.insert(k)
            }
        }
    }

    /// Nom du groupe d'une entrée, ou "" si elle n'est dans aucun service.
    public func labelOf(_ base: String) -> String {
        guard let k = key[base] ?? nil else { return "" }
        return display[k] ?? pyTitle(k)
    }

    /// Services d'abord, puis « Autres sites » et « Autres clés et accès ».
    public func group(_ entries: [Entry]) -> [Group] {
        var byKey: [String: [Entry]] = [:], sites: [Entry] = [], acces: [Entry] = []
        for e in entries.sorted(by: { codePointLess($0.base, $1.base) }) {
            if let k = key[e.base] ?? nil { byKey[k, default: []].append(e) }
            else if domain[e.base] == true { sites.append(e) } else { acces.append(e) }
        }
        var out = byKey.keys.sorted(by: codePointLess).map { k -> Group in
            let m = byKey[k]!
            return Group(id: "svc:\(k)", label: display[k] ?? pyTitle(k),
                         kind: projects.contains(k) ? .project : .service,
                         manual: m.allSatisfy { overridden.contains($0.base) }, members: m)
        }
        if !sites.isEmpty { out.append(Group(id: "bucket:sites", label: "Autres sites", kind: .sites, manual: false, members: sites)) }
        if !acces.isEmpty { out.append(Group(id: "bucket:acces", label: "Autres clés et accès", kind: .acces, manual: false, members: acces)) }
        return out
    }
}

// MARK: - Teinte du monogramme

public let tones = 24

private let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    return c
}

public func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

/// Teinte stable d'un service : « Mondial Relay » et MONDIALRELAY ont la même.
public func toneIndex(_ service: String) -> Int {
    let letters = service.decomposedStringWithCanonicalMapping.uppercased()
    let kept = letters.unicodeScalars.filter { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 48 && $0.value <= 57) }
    return Int(crc32(kept.map { UInt8($0.value) }) % UInt32(tones))
}
