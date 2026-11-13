import Foundation

public enum EntryKind: String, Sendable { case pair, aws, single }

/// Entrée logique : une paire NOM_USER/NOM_PASSWORD, un profil AWS, ou un secret seul.
public struct Entry: Equatable, Sendable {
    public let kind: EntryKind
    public let base: String
    public let user: String?
    public let value: String
    public let exported: Bool
}

public let awsIdSuffix = "_ACCESS_KEY_ID"
public let awsSecretSuffix = "_SECRET_ACCESS_KEY"

/// Port de `grouped()` : (nom, valeur, exporté) → entrées triées par base (tri stable).
public func grouped(_ items: [(name: String, value: String, exported: Bool)]) -> [Entry] {
    var d: [String: String] = [:], exp: [String: Bool] = [:]
    for i in items { d[i.name] = i.value; exp[i.name] = i.exported }
    let names = d.keys.sorted(by: codePointLess)
    var out: [Entry] = [], used = Set<String>()
    for n in names {
        if n.hasSuffix("_USER"), d[String(n.dropLast(5)) + "_PASSWORD"] != nil {
            let base = String(n.dropLast(5))
            out.append(Entry(kind: .pair, base: base, user: d[n], value: d[base + "_PASSWORD"]!, exported: exp[n]!))
            used.formUnion([n, base + "_PASSWORD"])
        } else if n.hasPrefix("AWS_"), n.hasSuffix(awsIdSuffix), exp[n] == false,
                  d[String(n.dropLast(awsIdSuffix.count)) + awsSecretSuffix] != nil {
            let base = String(n.dropLast(awsIdSuffix.count))
            out.append(Entry(kind: .aws, base: base, user: d[n], value: d[base + awsSecretSuffix]!, exported: false))
            used.formUnion([n, base + awsSecretSuffix, base + "_SESSION_TOKEN"])
        }
    }
    for n in names where !used.contains(n) {
        out.append(Entry(kind: .single, base: n, user: nil, value: d[n]!, exported: exp[n]!))
    }
    return out.enumerated().sorted { a, b in
        a.element.base == b.element.base ? a.offset < b.offset : codePointLess(a.element.base, b.element.base)
    }.map(\.element)
}
