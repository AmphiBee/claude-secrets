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
    public var description: String {
        switch self {
        case .keychain(let rc):
            return "trousseau inaccessible (code \(rc)) : ouvre une session graphique (verrouillé en SSH)"
        case .malformed: return "coffre illisible"
        }
    }
}

/// Stockage du coffre. Derrière un protocole pour pouvoir basculer sur la CLI en repli.
public protocol VaultStore: Sendable {
    func load() throws -> [VaultSecret]
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

/// Ordre des points de code Unicode (= ordre UTF-8), celui de `sorted()` en Python.
public func codePointLess(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

/// Lecture de l'élément de trousseau unique (service + compte « vault »).
public struct KeychainVaultStore: VaultStore {
    public let service: String
    public init(service: String = Vault.service) { self.service = service }

    public func load() throws -> [VaultSecret] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: Vault.account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let rc = SecItemCopyMatching(q as CFDictionary, &out)
        if rc == errSecItemNotFound { return [] }
        guard rc == errSecSuccess, let data = out as? Data else { throw VaultError.keychain(rc) }
        return try Vault.decode(data)
    }
}
