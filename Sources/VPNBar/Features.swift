import AppKit
import SwiftUI
import VPNBarCore

@MainActor
final class FeatureModel: ObservableObject {
    @Published var settings = FeatureSettings()
    @Published var busy = false
    @Published var message: String?
    @Published var failed = false
    @Published var domainName = ""
    @Published var domainAddress = "127.0.0.1"
    @Published var dnsApplied: DNSPreset = .system
    let share = ShareModel()
    init() {
        let file = AppPaths.directory.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: file) {
            do { settings = try JSONDecoder().decode(FeatureSettings.self, from: data); dnsApplied = settings.appliedDNS ?? .system }
            catch { message = "Impostazioni salvate illeggibili: \(error.localizedDescription)"; failed = true }
        }
    }
    func save() throws { try AppPaths.save(settings, to: "settings.json") }
    func report(_ error: Error) { failed = true; message = error.localizedDescription }
    func applyDNS() async throws {
        guard !busy else { throw FeatureError("Una modifica di rete è già in corso.") }
        busy = true; defer { busy = false }
        let servers = try settings.dns.resolvedServers(settings.customDNS)
        let result = try await privileged(NetworkRequest(operation: settings.dns == .system ? .restoreDNS : .dns, servers: servers))
        dnsApplied = settings.dns; settings.appliedDNS = settings.dns; try save(); failed = false; message = result
    }
    func applyDomains(_ domains: [LocalDomain]) async throws {
        guard !busy else { throw FeatureError("Una modifica di rete è già in corso.") }
        busy = true; defer { busy = false }
        let result = try await privileged(NetworkRequest(operation: .domains, domains: domains))
        settings.domains = domains; try save(); failed = false; message = result
    }
    func addDomain() {
        Task {
            do {
                let domain = try LocalDomain(name: domainName, address: domainAddress)
                guard !settings.domains.contains(where: { $0.name == domain.name }) else { throw FeatureError("Questo dominio è già presente. Rimuovilo per cambiarne l’indirizzo.") }
                try await applyDomains(settings.domains + [domain]); domainName = ""
            } catch { report(error) }
        }
    }
    func removeDomain(_ domain: LocalDomain) {
        Task { do { try await applyDomains(settings.domains.filter { $0.id != domain.id }) } catch { report(error) } }
    }
    private func privileged(_ request: NetworkRequest) async throws -> String {
        try request.validate()
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VPNBarNetwork")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw FeatureError("Helper di rete mancante. Ricompila VPNBar con scripts/build.sh.") }
        let payload = try JSONEncoder().encode(request).base64EncodedString()
        func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = shellQuote(helper.path) + " " + shellQuote(payload)
        let script = "do shell script " + Engine.quote(command) + " with administrator privileges"
        return try await Engine.run(script, timeout: 120)
    }
    func chooseCredentials() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.message = "Scegli il file credenziali del tunnel Cloudflare (.json)"
        if panel.runModal() == .OK, let url = panel.url {
            settings.credentialsPath = url.path
            do { try save() } catch { report(error) }
        }
    }
    func installCLI() {
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("vpnbar")
            let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vpnbar")
            if FileManager.default.fileExists(atPath: destination.path) || (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                let target = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
                guard target?.hasSuffix("/VPNBar.app/Contents/Helpers/vpnbar") == true else { throw FeatureError("~/.local/bin/vpnbar esiste già e non appartiene a VPNBar.") }
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
            failed = false; message = "CLI installata in ~/.local/bin/vpnbar. Aggiungi ~/.local/bin al PATH se necessario."
        } catch { report(error) }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    @Published var starting = false
    @Published var running = false
    @Published var publicURL: URL?
    @Published var error: String?
    @Published var origin: String?
    private var process: Process?
    private var buffer = ""
    private var generation = UUID()
    private var configURL: URL?
    var active: Bool { starting || running }
    func start(_ settings: FeatureSettings) async throws -> URL {
        guard !active else { throw FeatureError("Una condivisione è già attiva. Interrompila prima di avviarne un’altra.") }
        let local = try Validation.origin(settings.origin, domains: settings.domains)
        let resource = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/cloudflared")
        guard FileManager.default.isExecutableFile(atPath: resource.path) else { throw FeatureError("cloudflared mancante: usa scripts/fetch-cloudflared.sh e ricompila.") }
        let guardAgent = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VPNBarShareAgent")
        guard FileManager.default.isExecutableFile(atPath: guardAgent.path) else { throw FeatureError("Helper di condivisione mancante.") }
        let id = UUID(); generation = id; buffer = ""; error = nil; publicURL = nil
        var arguments = ["tunnel", "--no-autoupdate", "--output", "json", "--loglevel", "info", "--grace-period", "1s"]
        try AppPaths.prepare()
        if settings.usePersonalDomain {
            let hostname = settings.publicHostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Validation.hostname(hostname), !hostname.hasSuffix(".test"), let tunnel = UUID(uuidString: settings.tunnelID),
                  !settings.credentialsPath.isEmpty else { throw FeatureError("Inserisci dominio pubblico, UUID del tunnel e file credenziali Cloudflare.") }
            struct Credentials: Decodable { let TunnelID: UUID; let TunnelSecret: String }
            let credentials = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: settings.credentialsPath)))
            guard credentials.TunnelID == tunnel, !credentials.TunnelSecret.isEmpty else { throw FeatureError("Il file credenziali non corrisponde al tunnel indicato.") }
            // JSON strings are valid YAML scalars: paths and user input cannot introduce extra ingress rules.
            func yaml(_ value: String) throws -> String { String(data: try JSONEncoder().encode(value), encoding: .utf8)! }
            let config = """
            tunnel: \(tunnel.uuidString.lowercased())
            credentials-file: \(try yaml(settings.credentialsPath))
            ingress:
              - hostname: \(try yaml(hostname))
                service: \(try yaml(local.absoluteString))
              - service: http_status:404
            """
            let path = AppPaths.directory.appendingPathComponent("share-\(id.uuidString).yml")
            try config.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            configURL = path
            arguments += ["--config", path.path, "run", tunnel.uuidString.lowercased()]
            publicURL = URL(string: "https://" + hostname)
        } else {
            // Explicit empty config prevents an unrelated ~/.cloudflared config from changing the target.
            let path = AppPaths.directory.appendingPathComponent("share-\(id.uuidString).yml")
            try "{}\n".write(to: path, atomically: true, encoding: .utf8); configURL = path
            arguments += ["--config", path.path, "--url", local.absoluteString]
        }
        let child = Process(), output = Pipe()
        child.executableURL = guardAgent
        child.arguments = [String(getpid()), resource.path] + arguments
        child.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("TUNNEL_") && !$0.key.hasPrefix("CLOUDFLARED_") }
        child.standardOutput = output; child.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.consume(text, generation: id) }
        }
        child.terminationHandler = { [weak self] child in
            let code = child.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.starting = false; self.running = false; self.publicURL = nil; self.process = nil
                self.error = self.error ?? "Condivisione terminata (codice \(code))."
                self.removeConfig()
            }
        }
        do { try child.run() } catch { output.fileHandleForReading.readabilityHandler = nil; removeConfig(); throw error }
        process = child; origin = local.absoluteString; starting = true
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            guard generation == id else { throw FeatureError("Condivisione annullata.") }
            if running, let url = publicURL { return url }
            if !starting { throw FeatureError(error ?? "Impossibile avviare la condivisione.") }
            try await Task.sleep(for: .milliseconds(150))
        }
        stop(); error = "Cloudflare non ha completato la connessione entro 60 secondi. Riprova."
        throw FeatureError(error!)
    }
    private func consume(_ text: String, generation id: UUID) {
        guard generation == id else { return }
        buffer += text
        while let end = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<end]); buffer.removeSubrange(...end)
            if let range = line.range(of: "https://[a-z0-9-]+\\.trycloudflare\\.com", options: .regularExpression) { publicURL = URL(string: String(line[range])) }
            if line.contains("Registered tunnel connection") { running = true; starting = false; error = nil }
            if line.contains("failed to request quick Tunnel") || line.contains("Failed to create quick Tunnel") {
                error = "Cloudflare non riesce a creare il link temporaneo. Controlla la connessione e riprova."
            }
        }
        if buffer.count > 16000 { buffer = String(buffer.suffix(8000)) }
    }
    func stop() {
        generation = UUID()
        if let process, process.isRunning { process.terminate() }
        process = nil; starting = false; running = false; publicURL = nil; error = nil; origin = nil
        removeConfig()
    }
    private func removeConfig() { if let configURL { try? FileManager.default.removeItem(at: configURL) }; configURL = nil }
}
