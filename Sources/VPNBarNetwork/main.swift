import Foundation
import Darwin
import VPNBarCore

func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    process.standardOutput = output; process.standardError = output
    try process.run()
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit(); watchdog.cancel()
    let text = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else { throw FeatureError("\(URL(fileURLWithPath: executable).lastPathComponent): \(text.prefix(1200))") }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct SystemDNS: DNSBackend {
    func services() throws -> [String] {
        try run("/usr/sbin/networksetup", ["-listallnetworkservices"]).components(separatedBy: "\n")
            .dropFirst().filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }
    func servers(for service: String) throws -> [String] {
        let output = try run("/usr/sbin/networksetup", ["-getdnsservers", service])
        if output.hasPrefix("There aren't any DNS Servers") { return [] }
        let values = output.components(separatedBy: "\n")
        guard values.allSatisfy(Validation.ip) else { throw FeatureError("Impossibile leggere i DNS di \(service).") }
        return values
    }
    func setServers(_ servers: [String], for service: String) throws {
        guard servers.allSatisfy(Validation.ip) else { throw FeatureError("Backup DNS non valido.") }
        _ = try run("/usr/sbin/networksetup", ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers))
    }
}

func ensureRegularRootPath(_ path: String, directory: Bool = false) throws {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_uid == 0,
          info.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG),
          info.st_mode & 0o022 == 0 else { throw FeatureError("Percorso di sistema non sicuro: \(path).") }
}

do {
    guard geteuid() == 0 else { throw FeatureError("Le modifiche di rete richiedono l’autorizzazione amministratore di macOS.") }
    guard CommandLine.arguments.count == 2, CommandLine.arguments[1].count <= 50000,
          let data = Data(base64Encoded: CommandLine.arguments[1]) else { throw FeatureError("Richiesta di rete non valida.") }
    let request = try JSONDecoder().decode(NetworkRequest.self, from: data)
    try request.validate()
    let directory = URL(fileURLWithPath: "/Library/Application Support/VPNBarNetwork", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try ensureRegularRootPath(directory.path, directory: true)
    let lock = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw FeatureError("Impossibile bloccare le impostazioni di rete.") }
    defer { flock(lock, LOCK_UN); close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw FeatureError("Un’altra modifica di rete è in corso.") }
    let stateURL = directory.appendingPathComponent("dns-backup.json")
    var state: [String: DNSOwnership] = [:]
    if FileManager.default.fileExists(atPath: stateURL.path) {
        try ensureRegularRootPath(stateURL.path)
        state = try JSONDecoder().decode([String: DNSOwnership].self, from: Data(contentsOf: stateURL))
    }
    let persist: ([String: DNSOwnership]) throws -> Void = { value in
        try JSONEncoder().encode(value).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    var message = ""
    switch request.operation {
    case .dns:
        _ = try DNSTransaction.apply(request.servers, backend: SystemDNS(), previous: state, persist: persist)
        message = "DNS configurati: " + request.servers.joined(separator: ", ")
    case .restoreDNS:
        let preserved = try DNSTransaction.restore(backend: SystemDNS(), previous: state, persist: persist)
        message = "DNS originali ripristinati."
        if !preserved.isEmpty { message += " Conservate le modifiche esterne su: " + preserved.joined(separator: ", ") }
    case .domains:
        let hosts = URL(fileURLWithPath: "/private/etc/hosts")
        try ensureRegularRootPath(hosts.path)
        let original = try String(contentsOf: hosts, encoding: .utf8)
        guard original.utf8.count <= 1_000_000 else { throw FeatureError("Il file hosts è troppo grande.") }
        let updated = try HostsDocument.replacing(original, domains: request.domains)
        let attributes = try FileManager.default.attributesOfItem(atPath: hosts.path)
        try updated.write(to: hosts, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([
            .posixPermissions: attributes[.posixPermissions] ?? 0o644,
            .ownerAccountID: attributes[.ownerAccountID] ?? 0,
            .groupOwnerAccountID: attributes[.groupOwnerAccountID] ?? 0
        ], ofItemAtPath: hosts.path)
        message = "\(request.domains.count) domini locali applicati."
    }
    _ = try? run("/usr/bin/dscacheutil", ["-flushcache"])
    _ = try? run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    print(message)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
