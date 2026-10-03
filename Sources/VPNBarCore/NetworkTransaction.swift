import Foundation

public protocol DNSBackend {
    func services() throws -> [String]
    func servers(for service: String) throws -> [String]
    func setServers(_ servers: [String], for service: String) throws
}

public struct DNSOwnership: Codable, Equatable {
    public var original: [String]
    public var owned: [[String]]
    public init(original: [String], owned: [[String]]) { self.original = original; self.owned = owned }
}

public enum DNSTransaction {
    // Write the recovery journal before changing the OS, including both possible states during a crash.
    public static func apply(_ selected: [String], backend: DNSBackend, previous: [String: DNSOwnership],
                             persist: ([String: DNSOwnership]) throws -> Void) throws -> [String: DNSOwnership] {
        try NetworkRequest(operation: .dns, servers: selected).validate()
        let services = try backend.services()
        guard !services.isEmpty else { throw FeatureError("Nessun servizio di rete attivo da configurare.") }
        var current: [String: [String]] = [:], journal = previous
        for service in services {
            current[service] = try backend.servers(for: service)
            var entry = journal[service] ?? DNSOwnership(original: current[service]!, owned: [])
            if !entry.owned.isEmpty, !entry.owned.contains(current[service]!) {
                entry = DNSOwnership(original: current[service]!, owned: [])
            }
            if !entry.owned.contains(selected) { entry.owned.append(selected) }
            journal[service] = entry
        }
        try persist(journal)
        var changed: [String] = []
        do {
            for service in services {
                changed.append(service)
                try backend.setServers(selected, for: service)
                guard try backend.servers(for: service) == selected else { throw FeatureError("macOS non ha applicato i DNS a \(service).") }
            }
            for service in services { journal[service]?.owned = [selected] }
            try persist(journal)
            return journal
        } catch {
            let failure = error
            var rollbackFailed = false
            for service in changed.reversed() {
                do { try backend.setServers(current[service]!, for: service) } catch { rollbackFailed = true }
            }
            if !rollbackFailed { try persist(previous) }
            // Keep the recovery journal if rollback is incomplete; Restore can repair both possible states.
            if rollbackFailed { throw FeatureError("Modifica DNS interrotta; ripristino parziale. Usa Ripristina DNS originali. \(failure.localizedDescription)") }
            throw failure
        }
    }
    public static func restore(backend: DNSBackend, previous: [String: DNSOwnership],
                               persist: ([String: DNSOwnership]) throws -> Void) throws -> [String] {
        let available = Set(try backend.services())
        var remaining = previous, preserved: [String] = []
        for service in previous.keys.sorted() where available.contains(service) {
            let entry = previous[service]!
            if entry.owned.contains(try backend.servers(for: service)) {
                try backend.setServers(entry.original, for: service)
                guard try backend.servers(for: service) == entry.original else { throw FeatureError("Ripristino DNS non riuscito per \(service).") }
            } else { preserved.append(service) }
            remaining.removeValue(forKey: service)
            try persist(remaining)
        }
        return preserved
    }
}
