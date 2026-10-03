import AppKit
import SwiftUI
import VPNBarCore

@MainActor
final class VPNModel: ObservableObject {
    let features = FeatureModel()
    @Published var tunnels: [Tunnel] = []
    @Published var enabled = false
    @Published var refreshing = false
    @Published var switching = false
    @Published var error: String?
    @Published var notice: String?
    @Published var query = ""
    @Published var ip: String?
    @Published var checkingIP = false
    @Published var lastUpdate: Date?
    @Published var startedAt: Date?
    @Published var drawer: Drawer? { didSet { layoutChanged?() } }
    @Published var ping: Double?
    @Published var pingDate: Date?
    @Published var traffic: [TrafficSample] = []
    @Published var speedResult: SpeedResult?
    @Published var testingSpeed = false
    @Published var speedError: String?
    private var pingTask: Task<Void, Never>?
    private var lastPingAttempt: Double?
    private var trafficBaseline: (name: String, received: Int64, sent: Int64, uptime: Double)?
    private var connectionGeneration = UUID()
    private var speedTask: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var automationBusy = false
    var layoutChanged: (() -> Void)?
    var statusChanged: (() -> Void)?
    var panelWidth: Double { drawer == nil ? 320 : 621 }
    var pingText: String { ping.map { String(format: "%.0f ms", $0) } ?? "— ms" }
    var downloadRate: Double { traffic.last?.download ?? 0 }
    var uploadRate: Double { traffic.last?.upload ?? 0 }
    var connected: Tunnel? { tunnels.first { $0.owned && $0.state == "CONNECTED" } }
    var pending: Tunnel? { tunnels.first { $0.owned && $0.busy && $0.state != "CONNECTED" } }
    var readyCount: Int { Set(tunnels.compactMap(\.countryID)).count }
    var headline: String {
        if !enabled { return "Completa il setup" }
        if error != nil { return "Stato da verificare" }
        if switching { return "Cambio server…" }
        if connected != nil { return "VPN connessa" }
        if pending != nil { return "Connessione in corso…" }
        return "VPN disconnessa"
    }
    func enable() {
        guard !enabled else { return }
        enabled = true; UserDefaults.standard.set(true, forKey: "engineEnabled")
        poll = Task { [weak self] in
            while !Task.isCancelled { await self?.refresh(); try? await Task.sleep(for: .seconds(3)) }
        }
    }
    func refresh() async {
        guard enabled, !refreshing else { return }
        refreshing = true; defer { refreshing = false; statusChanged?() }
        do {
            let previous = connected?.name
            tunnels = try await Engine.tunnels(); lastUpdate = Date(); recordTraffic(); error = nil
            if previous != connected?.name { ip = nil; startedAt = connected == nil ? nil : Date() }
        } catch {
            self.error = error.localizedDescription; tunnels = []; ip = nil; startedAt = nil; resetMeasurements()
        }
    }
    func resetMeasurements() {
        pingTask?.cancel(); pingTask = nil; ping = nil; pingDate = nil; lastPingAttempt = nil
        trafficBaseline = nil; traffic = []; connectionGeneration = UUID()
        speedTask?.cancel(); speedTask = nil; testingSpeed = false; speedResult = nil; speedError = nil
    }
    func recordTraffic() {
        guard let tunnel = connected else { resetMeasurements(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = trafficBaseline, previous.name == tunnel.name {
            let elapsed = now - previous.uptime
            if elapsed > 0, elapsed <= 15, tunnel.received >= previous.received, tunnel.sent >= previous.sent {
                traffic.append(TrafficSample(date: Date(), download: Double(tunnel.received - previous.received) * 8 / elapsed / 1_000_000, upload: Double(tunnel.sent - previous.sent) * 8 / elapsed / 1_000_000))
                traffic.removeAll { $0.date < Date().addingTimeInterval(-180) }
                if traffic.count > 60 { traffic.removeFirst(traffic.count - 60) }
            } else { resetMeasurements() }
        } else { resetMeasurements() }
        trafficBaseline = (tunnel.name, tunnel.received, tunnel.sent, now); updatePingIfNeeded()
    }
    func updatePingIfNeeded() {
        guard connected != nil, !switching, pingTask == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard lastPingAttempt == nil || now - lastPingAttempt! >= 15 else { return }
        lastPingAttempt = now; let generation = connectionGeneration
        pingTask = Task {
            defer { if generation == connectionGeneration { pingTask = nil; statusChanged?() } }
            do {
                let value = try await PingProbe.run()
                guard !Task.isCancelled, generation == connectionGeneration else { return }
                ping = value; pingDate = value == nil ? nil : Date()
            } catch { if generation == connectionGeneration { ping = nil; pingDate = nil } }
        }
    }
    func selectCountry(_ country: Country) {
        guard enabled, !switching else { return }
        let available = tunnels.filter { $0.countryID == country.id }
        if available.count > 1 { drawer = .servers(country.id) }
        else if let tunnel = available.first, tunnel.state != "CONNECTED" { connect(tunnel.name) }
    }
    func toggleDrawer(_ value: Drawer) { drawer = drawer == value ? nil : value }
    func testSpeed() {
        guard connected != nil, !switching, !testingSpeed else { return }
        let generation = connectionGeneration; testingSpeed = true; speedResult = nil; speedError = nil
        speedTask = Task {
            defer { if generation == connectionGeneration { testingSpeed = false; speedTask = nil; statusChanged?() } }
            do {
                let result = try await SpeedTest.run(); await refresh()
                guard !Task.isCancelled, generation == connectionGeneration, connected != nil else { return }
                speedResult = result
            } catch is CancellationError {} catch { if generation == connectionGeneration { speedError = error.localizedDescription } }
        }
    }
    func cancelSpeedTest() { speedTask?.cancel() }
    func connect(_ name: String) { Task { do { try await performConnect(name) } catch { notice = error.localizedDescription } } }
    func performConnect(_ name: String, reconnect: Bool = false) async throws {
        guard enabled else { throw FeatureError("Abilita il controllo VPN dall’app prima di connettere.") }
        guard !switching, !features.busy, tunnels.contains(where: { $0.name == name && $0.owned }) else { throw FeatureError("Server non disponibile o modifica di rete già in corso.") }
        drawer = nil; resetMeasurements(); switching = true; notice = nil
        defer { switching = false; statusChanged?() }
        let current = try await Engine.tunnels()
        guard !current.contains(where: { !$0.owned && $0.busy }) else { throw FeatureError("Un’altra VPN è attiva in Tunnelblick. Disconnettila prima di cambiare server.") }
        for tunnel in current where tunnel.owned && tunnel.busy {
            if !reconnect && tunnel.name == name && tunnel.state == "CONNECTED" { await refresh(); return }
            try await Engine.command("disconnect", name: tunnel.name)
        }
        try await waitForDisconnect(); try await Engine.command("connect", name: name); await refresh()
    }
    func waitForDisconnect() async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if try await !Engine.tunnels().contains(where: { $0.owned && $0.busy }) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw FeatureError("Il server precedente non si è disconnesso. Riprova.")
    }
    func disconnect() { Task { do { try await performDisconnect() } catch { notice = error.localizedDescription } } }
    func performDisconnect() async throws {
        guard enabled else { throw FeatureError("Abilita il controllo VPN dall’app.") }
        guard !switching else { throw FeatureError("Cambio server già in corso.") }
        drawer = nil; resetMeasurements(); switching = true; notice = nil
        defer { switching = false; statusChanged?() }
        for tunnel in try await Engine.tunnels() where tunnel.owned && tunnel.busy { try await Engine.command("disconnect", name: tunnel.name) }
        try await waitForDisconnect(); await refresh()
    }
    func applyDNS() { Task { do { try await performDNS() } catch { features.report(error) } } }
    func performDNS() async throws {
        guard !switching else { throw FeatureError("Attendi il completamento del cambio server.") }
        let active = connected?.name
        try await features.applyDNS()
        if let active, connected?.name == active { try await performConnect(active, reconnect: true) }
    }
    func fetchIP() async throws -> String {
        guard let name = connected?.name, error == nil else { throw FeatureError("Connetti la VPN prima di verificare l’IP.") }
        let generation = connectionGeneration
        let request = URLRequest(url: URL(string: "https://api.ipify.org?format=json")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let value = object["ip"], Validation.ip(value) else { throw FeatureError("Impossibile leggere l’IP pubblico.") }
        await refresh()
        guard generation == connectionGeneration, connected?.name == name, error == nil else { throw FeatureError("La connessione è cambiata durante la verifica IP.") }
        ip = value; return value
    }
    func checkIP() {
        guard connected != nil, !checkingIP else { return }
        checkingIP = true; notice = nil
        Task { defer { checkingIP = false }; do { _ = try await fetchIP() } catch { notice = error.localizedDescription } }
    }
    func command(_ request: ControlRequest) async throws -> String {
        if request.command == "share-stop" { features.share.stop(); return "Condivisione interrotta." }
        if request.command == "share-status" { return features.share.running ? features.share.publicURL?.absoluteString ?? "Condivisione attiva" : features.share.starting ? "Creazione link…" : "Nessuna condivisione attiva." }
        guard !automationBusy else { throw FeatureError("Un altro comando è in corso. Riprova.") }
        automationBusy = true; defer { automationBusy = false }
        switch request.command {
        case "status":
            if enabled { await refresh() }
            let object: [String: Any] = ["enabled": enabled, "state": headline, "server": connected?.name as Any? ?? NSNull(),
                "error": error as Any? ?? NSNull(), "updatedAt": lastUpdate.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                "dns": features.dnsApplied.rawValue, "sharing": features.share.running, "shareURL": features.share.publicURL?.absoluteString as Any? ?? NSNull()]
            return String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
        case "connect":
            guard enabled else { throw FeatureError("Abilita il controllo VPN dall’app.") }
            await refresh(); guard error == nil else { throw FeatureError(error!) }
            let value = request.argument ?? ""
            let candidate = tunnels.first { $0.owned && $0.name == value } ?? tunnels.first { $0.countryID == value.uppercased() }
            guard let candidate else { throw FeatureError("Nessun profilo installato per \(value).") }
            try await performConnect(candidate.name)
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline {
                await refresh()
                if error != nil { throw FeatureError(error!) }
                if connected?.name == candidate.name { return "VPN connessa: \(candidate.name)" }
                if pending == nil { throw FeatureError("La connessione VPN non è riuscita.") }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw FeatureError("Connessione ancora in corso. Controlla VPNBar.")
        case "disconnect": try await performDisconnect(); return "VPN disconnessa."
        case "ip", "copy-ip":
            let value = try await fetchIP()
            if request.command == "copy-ip" { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
            return value
        case "dns":
            let values = (request.argument ?? "").split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = values.first, let preset = DNSPreset(rawValue: key) else { throw FeatureError("Resolver DNS non valido.") }
            features.settings.dns = preset; features.settings.customDNS = values.count > 1 ? values[1] : ""
            try await performDNS(); return features.message ?? "DNS applicati."
        case "domains": return String(data: try JSONEncoder().encode(features.settings.domains), encoding: .utf8)!
        case "domain-add":
            guard let data = request.argument?.data(using: .utf8) else { throw FeatureError("Dominio mancante.") }
            let domain = try JSONDecoder().decode(LocalDomain.self, from: data)
            try await features.applyDomains(features.settings.domains.filter { $0.name != domain.name } + [domain])
            return features.message ?? "Dominio applicato."
        case "domain-remove":
            guard let name = request.argument, features.settings.domains.contains(where: { $0.name == name }) else { throw FeatureError("Dominio locale non trovato.") }
            try await features.applyDomains(features.settings.domains.filter { $0.name != name }); return features.message ?? "Dominio rimosso."
        case "share":
            features.settings.origin = request.argument ?? ""; try features.save()
            return try await features.share.start(features.settings).absoluteString
        case "share-stop": features.share.stop(); return "Condivisione interrotta."
        case "share-status": return features.share.running ? features.share.publicURL?.absoluteString ?? "Condivisione attiva" : features.share.starting ? "Creazione link…" : "Nessuna condivisione attiva."
        default: throw FeatureError("Comando non supportato.")
        }
    }
}
