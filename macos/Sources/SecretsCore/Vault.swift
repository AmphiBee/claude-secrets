import Foundation
import Security

/// Un secret du coffre. La valeur ne doit jamais être journalisée : `description` la masque.
public struct VaultSecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let name: String
    public let value: String
    public let exported: Bool
    public let source: String

    public init(name: String, value: String, exported: Bool = true, source: String = "local") {
        self.name = name; self.value = value; self.exported = exported; self.source = source
    }
    public var description: String { "VaultSecret(\(name), valeur masquée)" }
    public var debugDescription: String { description }
}

public enum VaultError: Error, CustomStringConvertible {
    case keychain(OSStatus)      // jamais de valeur dans un message d'erreur
    case malformed
    case lock(Int32)
    public var description: String {
        switch self {
        case .keychain(let rc):
            return "trousseau inaccessible (code \(rc)) : ouvre une session graphique (verrouillé en SSH)"
        case .malformed: return "coffre illisible"
        case .lock(let e): return "verrou du coffre inaccessible (errno \(e))"
        }
    }
}

/// Stockage du coffre. Derrière un protocole pour pouvoir basculer sur la CLI en repli.
public protocol VaultStore: Sendable {
    /// `includeReserved` : noms en `_…` (clé de session Bitwarden) ; faux pour tout ce qui est affiché.
    func load(includeReserved: Bool) throws -> [VaultSecret]
    /// Écriture atomique entre processus : verrou exclusif, relecture, modification, réécriture,
    /// régénération du cache du shell. Retourne le coffre (sans les noms réservés) après modification.
    @discardableResult
    func transaction(_ body: (inout [VaultSecret]) throws -> Void) throws -> [VaultSecret]
    /// Oublie la copie en mémoire des valeurs (masquage prolongé).
    func dropCache()
}

public enum Vault {
    public static let defaultService = "claude-secrets-vault"
    public static let account = "vault"
    public static let nameRegex = try! NSRegularExpression(pattern: "^[A-Z][A-Z0-9_]*$")

    /// Même surcharge que la couche d'adaptation Python (tests).
    public static var service: String {
        ProcessInfo.processInfo.environment["CLAUDE_SECRETS_SERVICE"] ?? defaultService
    }

    public static func isValidName(_ s: String) -> Bool {
        nameRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Décode le JSON du coffre. Les noms réservés (`_…`) sont écartés, comme store_meta().
    /// Résultat trié par nom (ordre des points de code, comme Python).
    public static func decode(_ data: Data, includeReserved: Bool = false) throws -> [VaultSecret] {
        struct Raw: Decodable { var value: String?; var export: String?; var source: String? }
        guard let map = try? JSONDecoder().decode([String: Raw].self, from: data) else { throw VaultError.malformed }
        return map.compactMap { name, e in
            if name.isEmpty || (name.hasPrefix("_") && !includeReserved) { return nil }
            return VaultSecret(name: name, value: e.value ?? "", exported: (e.export ?? "1") != "0",
                               source: e.source ?? "local")
        }.sorted { codePointLess($0.name, $1.name) }
    }

    /// Encode au format de la CLI : {nom: {value, export: "1"|"0", source}} (l'ordre des clés importe peu à la relecture).
    public static func encode(_ secrets: [VaultSecret]) throws -> Data {
        var m: [String: [String: String]] = [:]
        for s in secrets { m[s.name] = ["value": s.value, "export": s.exported ? "1" : "0", "source": s.source] }
        return try JSONSerialization.data(withJSONObject: m, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

public extension VaultStore {
    func dropCache() {}
    func load() throws -> [VaultSecret] { try load(includeReserved: false) }
}

/// Ordre des points de code Unicode (= ordre UTF-8), celui de `sorted()` en Python.
public func codePointLess(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

/// L'élément de trousseau unique (service + compte « vault »), le même que celui de la CLI.
public struct KeychainVaultStore: VaultStore {
    public let service: String
    public let lockURL: URL
    public let cacheURL: URL?     // nil : pas de cache du shell (tests)

    public init(service: String = Vault.service, lockURL: URL = ShellCache.defaultLockURL,
                cacheURL: URL? = ShellCache.defaultURL) {
        self.service = service; self.lockURL = lockURL; self.cacheURL = cacheURL
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: Vault.account]
    }

    /// Date de modification de l'élément : un attribut, lisible SANS autorisation du trousseau (≈ 7 ms),
    /// alors que lire la valeur déclenche la demande d'autorisation (plusieurs secondes, une boîte de dialogue).
    private func modificationDate() -> Date? {
        var q = base
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return (out as? [String: Any])?[kSecAttrModificationDate as String] as? Date
    }

    /// Une seule lecture de la valeur par changement de l'élément. Le cache n'est fiable que si l'élément était
    /// déjà stable (≥ 2 s) quand on l'a lu : une écriture ultérieure d'un autre processus change alors forcément
    /// la date, même dans la même seconde que la précédente.
    private func readAll() throws -> [VaultSecret] {
        let mdat = modificationDate()
        if let mdat, let c = ItemCache.shared.get(service), c.mdat == mdat, c.readAt.timeIntervalSince(mdat) >= 2 {
            return try Vault.decode(c.data, includeReserved: true)
        }
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let rc = SecItemCopyMatching(q as CFDictionary, &out)
        if rc == errSecItemNotFound { ItemCache.shared.set(service, nil); return [] }
        guard rc == errSecSuccess, let data = out as? Data else { throw VaultError.keychain(rc) }
        // La date lue AVANT les données : si l'élément change entre les deux, la date mémorisée est plus
        // ancienne que la réalité, donc le prochain passage relira (sûr).
        ItemCache.shared.set(service, mdat.map { CachedItem(data: data, mdat: $0, readAt: Date()) })
        return try Vault.decode(data, includeReserved: true)
    }

    private func writeAll(_ secrets: [VaultSecret]) throws {
        let data = try Vault.encode(secrets)
        var rc = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if rc == errSecItemNotFound {
            var add = base; add[kSecValueData as String] = data
            rc = SecItemAdd(add as CFDictionary, nil)
        }
        guard rc == errSecSuccess else { throw VaultError.keychain(rc) }
        ItemCache.shared.set(service, nil)      // la date a changé : la prochaine lecture relira la valeur
    }

    public func dropCache() { ItemCache.shared.set(service, nil) }

    public func load(includeReserved: Bool) throws -> [VaultSecret] {
        let all = try readAll()
        return includeReserved ? all : all.filter { !$0.name.hasPrefix("_") }
    }

    @discardableResult
    public func transaction(_ body: (inout [VaultSecret]) throws -> Void) throws -> [VaultSecret] {
        let lock = try FileLock(url: lockURL)    // tenu jusqu'à la fin de la fonction
        defer { lock.release() }
        var all = try readAll()                  // relire APRÈS le verrou, sinon deux écrivains s'écraseraient
        let before = all
        try body(&all)
        var seen = Set<String>()
        all = all.filter { seen.insert($0.name).inserted }   // jamais de doublon
        let visible = all.filter { !$0.name.hasPrefix("_") }.sorted { codePointLess($0.name, $1.name) }
        // Rien n'a changé : on n'écrit ni le trousseau (l'app deviendrait « dernier écrivain », donc plus lente
        // pour la CLI) ni le cache (il pourrait écraser une photo plus récente).
        let changed = Dictionary(uniqueKeysWithValues: before.map { ($0.name, $0) }) != Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        if changed {
            try writeAll(all)
            if let cacheURL { try? ShellCache.write(visible, to: cacheURL) }
        }
        return visible
    }
}

struct CachedItem { let data: Data; let mdat: Date; let readAt: Date }

/// Mémoire du processus (jamais sur disque) : la valeur brute du coffre, indexée par service.
final class ItemCache: @unchecked Sendable {
    static let shared = ItemCache()
    private let lock = NSLock()
    private var items: [String: CachedItem] = [:]
    func get(_ s: String) -> CachedItem? { lock.lock(); defer { lock.unlock() }; return items[s] }
    func set(_ s: String, _ v: CachedItem?) { lock.lock(); items[s] = v; lock.unlock() }
}

/// Verrou exclusif entre processus : le même fichier que la CLI (flock).
public final class FileLock {
    private var fd: Int32
    public init(url: URL) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else { throw VaultError.lock(errno) }
        guard flock(fd, LOCK_EX) == 0 else { let e = errno; close(fd); throw VaultError.lock(e) }
    }
    public func release() { if fd >= 0 { flock(fd, LOCK_UN); close(fd); fd = -1 } }
    deinit { release() }
}

/// Coffre en mémoire, mêmes règles de transaction : pour les tests (aucun trousseau).
public final class MemoryVaultStore: VaultStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [VaultSecret]
    public init(_ secrets: [VaultSecret] = []) { self.secrets = secrets }

    public func load(includeReserved: Bool) throws -> [VaultSecret] {
        lock.lock(); defer { lock.unlock() }
        let all = secrets.sorted { codePointLess($0.name, $1.name) }
        return includeReserved ? all : all.filter { !$0.name.hasPrefix("_") }
    }

    @discardableResult
    public func transaction(_ body: (inout [VaultSecret]) throws -> Void) throws -> [VaultSecret] {
        lock.lock(); defer { lock.unlock() }
        var all = secrets
        try body(&all)
        var seen = Set<String>()
        secrets = all.filter { seen.insert($0.name).inserted }
        return secrets.filter { !$0.name.hasPrefix("_") }.sorted { codePointLess($0.name, $1.name) }
    }
}
