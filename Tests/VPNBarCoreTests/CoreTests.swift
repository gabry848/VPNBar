import Foundation
import Testing
@testable import VPNBarCore

@Test func domainsAreNormalizedAndCannotInjectHostsLines() throws {
    let domain = try LocalDomain(name: " API.Progetto.TEST ", address: "127.0.0.1")
    #expect(domain.name == "api.progetto.test")
    #expect(throws: (any Error).self) { try LocalDomain(name: "api.test\nexample.com", address: "127.0.0.1") }
    #expect(throws: (any Error).self) { try LocalDomain(name: "example.com", address: "127.0.0.1") }
    #expect(throws: (any Error).self) { try LocalDomain(name: "api.test", address: "127.0.0.1:3000") }
    let malicious = Data(#"{"name":"api.test\n","address":"127.0.0.1"}"#.utf8)
    let decoded = try JSONDecoder().decode(LocalDomain.self, from: malicious)
    #expect(throws: (any Error).self) { try NetworkRequest(operation: .domains, domains: [decoded]).validate() }
}

@Test func hostsPreserveUnrelatedContentAndRefuseAmbiguousOwnership() throws {
    let base = "127.0.0.1 localhost\n::1 localhost\n# keep me\n10.0.0.2 existing.test\n"
    let domain = try LocalDomain(name: "api.test", address: "127.0.0.1")
    let updated = try HostsDocument.replacing(base, domains: [domain])
    #expect(updated.hasPrefix(base)); #expect(updated.contains("127.0.0.1\tapi.test"))
    #expect(try HostsDocument.replacing(updated, domains: []) == base)
    #expect(try HostsDocument.replacing(updated, domains: [domain]) == updated)
    #expect(throws: (any Error).self) { try HostsDocument.replacing(base, domains: [LocalDomain(name: "existing.test", address: "127.0.0.1")]) }
    #expect(throws: (any Error).self) { try HostsDocument.replacing(base + HostsDocument.begin, domains: []) }
}

@Test func shareAcceptsLocalServicesAndRejectsRemoteTargetsAndSecrets() throws {
    #expect(try Validation.origin("localhost:3000").absoluteString == "http://localhost:3000")
    #expect(try Validation.origin("http://[::1]:8080").port == 8080)
    #expect(try Validation.origin("https://192.168.1.4:8443").scheme == "https")
    for invalid in ["https://example.com", "ftp://localhost", "http://user:pass@localhost:3000", "http://localhost:3000/?token=secret", "http://localhost:3000/admin", "http://localhost:99999", "http://10.a.0.0.1"] {
        #expect(throws: (any Error).self) { try Validation.origin(invalid) }
    }
    let alias = try LocalDomain(name: "api.test", address: "127.0.0.1")
    #expect(try Validation.origin("api.test:3000", domains: [alias]).host == "api.test")
    #expect(throws: (any Error).self) { try Validation.origin("unconfigured.test:3000") }
}

@Test func controlRoundTripAndInvalidCommands() throws {
    let command = ControlRequest(command: "share", argument: "http://localhost:3000")
    #expect(try ControlRequest.decode(command.url) == command)
    #expect(throws: (any Error).self) { try ControlRequest.decode(ControlRequest(command: "arbitrary-shell", argument: "rm").url) }
    #expect(throws: (any Error).self) { try ControlRequest.decode(URL(string: "https://example.com")!) }
}

final class FakeDNS: DNSBackend {
    var values = ["Wi-Fi": ["8.8.8.8"], "Ethernet": [String]()]
    var failService: String?
    func services() -> [String] { values.keys.sorted() }
    func servers(for service: String) -> [String] { values[service]! }
    func setServers(_ servers: [String], for service: String) throws {
        if failService == service { failService = nil; throw FeatureError("injected failure") }
        values[service] = servers
    }
}

@Test func dnsKeepsOriginalAcrossPresetChangesAndRestoresDHCP() throws {
    let backend = FakeDNS(); var saved: [String: DNSOwnership] = [:]
    let original = backend.values
    saved = try DNSTransaction.apply(DNSPreset.adguard.servers, backend: backend, previous: saved) { saved = $0 }
    saved = try DNSTransaction.apply(DNSPreset.quad9.servers, backend: backend, previous: saved) { saved = $0 }
    #expect(saved["Wi-Fi"]?.original == ["8.8.8.8"])
    _ = try DNSTransaction.restore(backend: backend, previous: saved) { saved = $0 }
    #expect(backend.values == original); #expect(saved.isEmpty)
}

@Test func dnsFailureRollsBackAllModifiedServices() throws {
    let backend = FakeDNS(); let original = backend.values; backend.failService = "Wi-Fi"
    var saved: [String: DNSOwnership] = [:]
    #expect(throws: (any Error).self) { try DNSTransaction.apply(DNSPreset.adguard.servers, backend: backend, previous: [:]) { saved = $0 } }
    #expect(backend.values == original); #expect(saved.isEmpty)
}

@Test func restoreDoesNotOverwriteExternalDNSChanges() throws {
    let backend = FakeDNS(); var saved: [String: DNSOwnership] = [:]
    saved = try DNSTransaction.apply(DNSPreset.adguard.servers, backend: backend, previous: saved) { saved = $0 }
    backend.values["Wi-Fi"] = ["10.0.0.1"]
    let preserved = try DNSTransaction.restore(backend: backend, previous: saved) { saved = $0 }
    #expect(preserved == ["Wi-Fi"]); #expect(backend.values["Wi-Fi"] == ["10.0.0.1"]); #expect(saved.isEmpty)
}

@Test func dnsValidationRejectsShellAndEmptyCustomSettings() throws {
    #expect(try DNSPreset.custom.resolvedServers("1.1.1.1, ::1") == ["1.1.1.1", "::1"])
    for input in ["", "1.1.1.1;touch /tmp/x", "dns.example.com", "1.1.1.1\n127.0.0.1:53"] {
        #expect(throws: (any Error).self) { try DNSPreset.custom.resolvedServers(input) }
    }
}

@Test func aNewApplyPreservesAnInterveningExternalConfiguration() throws {
    let backend = FakeDNS(); var saved: [String: DNSOwnership] = [:]
    saved = try DNSTransaction.apply(DNSPreset.adguard.servers, backend: backend, previous: saved) { saved = $0 }
    backend.values["Wi-Fi"] = ["10.0.0.1"]
    saved = try DNSTransaction.apply(DNSPreset.quad9.servers, backend: backend, previous: saved) { saved = $0 }
    _ = try DNSTransaction.restore(backend: backend, previous: saved) { saved = $0 }
    #expect(backend.values["Wi-Fi"] == ["10.0.0.1"])
}
