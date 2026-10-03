import Foundation
import Darwin

public struct FeatureError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum DNSPreset: String, CaseIterable, Codable, Sendable {
    case system, adguard, quad9, cloudflare, custom
    public var title: String {
        switch self {
        case .system: "DNS originali"
        case .adguard: "AdGuard · pubblicità e tracker"
        case .quad9: "Quad9 · domini malevoli"
        case .cloudflare: "Cloudflare · senza filtri"
        case .custom: "Personalizzati"
        }
    }
    public var servers: [String] {
        switch self {
        case .system, .custom: []
        case .adguard: ["94.140.14.14", "94.140.15.15"]
        case .quad9: ["9.9.9.9", "149.112.112.112"]
        case .cloudflare: ["1.1.1.1", "1.0.0.1"]
        }
    }
    public func resolvedServers(_ custom: String) throws -> [String] {
        let values = self == .custom ? custom.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) : servers
        guard self == .system || !values.isEmpty else { throw FeatureError("Inserisci almeno un indirizzo DNS.") }
        guard values.count <= 6, values.allSatisfy(Validation.ip) else { throw FeatureError("Usa fino a 6 indirizzi DNS IPv4 o IPv6, separati da virgole.") }
        return Array(NSOrderedSet(array: values)) as! [String]
    }
}

public struct LocalDomain: Codable, Identifiable, Equatable, Sendable {
    public var name: String
    public var address: String
    public var id: String { name }
    public init(name: String, address: String) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ip = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Validation.hostname(normalized), normalized.hasSuffix(".test") else {
            throw FeatureError("Usa un dominio locale .test, per esempio api.progetto.test. Non inserire URL o porte.")
        }
        guard Validation.ip(ip) else { throw FeatureError("Inserisci un indirizzo IPv4 o IPv6, senza porta.") }
        self.name = normalized; self.address = ip
    }
    public func validated() throws -> LocalDomain { try LocalDomain(name: name, address: address) }
}

public enum Validation {
    public static func ip(_ value: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
    public static func hostname(_ value: String) -> Bool {
        guard value.utf8.count <= 253, value.contains("."), !value.hasSuffix(".") else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
    public static func localAddress(_ value: String) -> Bool {
        guard ip(value) else { return false }
        let parts = value.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
        }
        return value == "::1" || (ip(value) && (value.lowercased().hasPrefix("fc") || value.lowercased().hasPrefix("fd")))
    }
    public static func origin(_ text: String, domains: [LocalDomain] = []) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let components = URLComponents(string: input), let url = components.url,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/", let rawHost = components.host,
              components.port == nil || (1...65535).contains(components.port!) else {
            throw FeatureError("Inserisci l’URL del servizio locale, per esempio http://localhost:3000, senza percorso o credenziali.")
        }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard host == "localhost" || localAddress(host) || domains.contains(where: { $0.name == host && localAddress($0.address) }) else {
            throw FeatureError("Puoi condividere localhost, un IP privato o un dominio .test configurato su un IP privato.")
        }
        return url
    }
}

public struct FeatureSettings: Codable, Sendable {
    public var dns: DNSPreset = .system
    public var appliedDNS: DNSPreset? = .system
    public var customDNS = ""
    public var domains: [LocalDomain] = []
    public var origin = "http://localhost:3000"
    public var usePersonalDomain = false
    public var publicHostname = ""
    public var tunnelID = ""
    public var credentialsPath = ""
    public init() {}
}

public enum AppPaths {
    public static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["VPNBAR_DATA_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VPNBar", isDirectory: true)
    }
    public static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public static func save<T: Encodable>(_ value: T, to file: String) throws {
        try prepare()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let path = directory.appendingPathComponent(file)
        try encoder.encode(value).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}

public struct NetworkRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case dns, restoreDNS, domains }
    public var operation: Operation
    public var servers: [String]
    public var domains: [LocalDomain]
    public init(operation: Operation, servers: [String] = [], domains: [LocalDomain] = []) {
        self.operation = operation; self.servers = servers; self.domains = domains
    }
    public func validate() throws {
        switch operation {
        case .dns:
            guard !servers.isEmpty, servers.count <= 6, servers.allSatisfy(Validation.ip) else { throw FeatureError("Indirizzi DNS non validi.") }
        case .restoreDNS: break
        case .domains:
            guard domains.count <= 100, Set(domains.map(\.name)).count == domains.count else { throw FeatureError("Domini duplicati o troppi domini (massimo 100).") }
            for domain in domains {
                guard try domain.validated() == domain else { throw FeatureError("Il dominio deve essere normalizzato, senza spazi o caratteri di controllo.") }
            }
        }
    }
}
