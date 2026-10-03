import AppKit
import SwiftUI
import Charts

struct Panel: View {
    @ObservedObject var model: VPNModel
    var body: some View {
        HStack(spacing: 0) {
            if let drawer = model.drawer, drawer.isLeft { sidePanel(drawer).frame(width: 300); Divider() }
            mainPanel.frame(width: 320)
            if let drawer = model.drawer, !drawer.isLeft { Divider(); sidePanel(drawer).frame(width: 300) }
        }.frame(width: model.panelWidth, height: 540)
    }
    var mainPanel: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("VPNBar", systemImage: "shield.lefthalf.filled").font(.headline)
                    Spacer()
                    Circle().fill(model.connected != nil && model.error == nil ? Color.green : Color.secondary).frame(width: 7, height: 7).help(model.headline)
                    Text(model.headline.replacingOccurrences(of: "VPN ", with: "")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let tunnel = model.connected, let country = Country.catalog.first(where: { $0.id == tunnel.countryID }) {
                    HStack(spacing: 8) {
                        Text(country.flag).font(.title2); Text(country.name).font(.system(size: 15, weight: .semibold)); Spacer()
                        Button { model.disconnect() } label: { Image(systemName: "power") }.buttonStyle(.plain).disabled(model.switching)
                            .help("Disconnetti").accessibilityLabel("Disconnetti VPN")
                    }
                } else if model.pending != nil {
                    HStack { ProgressView().controlSize(.small); Spacer(); Button("Annulla") { model.disconnect() }.disabled(model.switching) }
                }
                Button { model.toggleDrawer(.metrics) } label: {
                    HStack(spacing: 0) {
                        compactMetric("arrow.down", bytes(model.connected?.received ?? 0), color: .blue); Spacer()
                        compactMetric("speedometer", model.pingText, color: .primary); Spacer()
                        compactMetric("arrow.up", bytes(model.connected?.sent ?? 0), color: .orange)
                    }.padding(.horizontal, 14).padding(.vertical, 12)
                        .background(model.drawer == .metrics ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Traffico e speed test · Ping verso 1.1.1.1 ogni 15 secondi")
                    .accessibilityLabel("Ricevuti \(bytes(model.connected?.received ?? 0)), ping \(model.pingText), inviati \(bytes(model.connected?.sent ?? 0)). Apri traffico e speed test")
                HStack(spacing: 6) {
                    featureButton("DNS", icon: "hand.raised", drawer: .dns)
                    featureButton("Domini", icon: "network", drawer: .domains)
                    featureButton("Condividi", icon: "link", drawer: .share)
                }
                if let message = model.error ?? model.notice {
                    HStack(alignment: .top) {
                        Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        if model.notice != nil { Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Chiudi messaggio") }
                    }
                }
                if !model.enabled { Button("Abilita controllo VPN") { model.enable() }.buttonStyle(.borderedProminent) }
            }.padding(16)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca paese", text: $model.query).textFieldStyle(.plain)
            }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 16).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 2) {
                    let countries = Country.catalog.filter { model.query.isEmpty || $0.name.localizedCaseInsensitiveContains(model.query) || $0.id.localizedCaseInsensitiveContains(model.query) }
                    ForEach(countries) { country in countryRow(country) }
                    if countries.isEmpty { Text("Nessun paese").font(.caption).foregroundStyle(.secondary).padding() }
                }.padding(.horizontal, 8)
            }
            Divider()
            HStack {
                Button { model.toggleDrawer(.details) } label: { Image(systemName: "info.circle") }.help("Dettagli").accessibilityLabel("Dettagli")
                Button { model.toggleDrawer(.automation) } label: { Image(systemName: "terminal") }.help("CLI e Comandi Rapidi").accessibilityLabel("CLI e Comandi Rapidi")
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(!model.enabled || model.refreshing).help("Aggiorna").accessibilityLabel("Aggiorna")
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }.help("Esci da VPNBar").accessibilityLabel("Esci da VPNBar")
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(14)
        }
    }
    func featureButton(_ title: String, icon: String, drawer: Drawer) -> some View {
        Button { model.toggleDrawer(drawer) } label: {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity)
                .padding(.vertical, 9).background(model.drawer == drawer ? Color.blue.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).foregroundStyle(model.drawer == drawer ? Color.blue : Color.primary).help(title)
    }
    func compactMetric(_ icon: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 6) { Image(systemName: icon).font(.system(size: 17)).foregroundStyle(color); Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit() }.frame(minWidth: 64)
    }
    func countryRow(_ country: Country) -> some View {
        let available = model.tunnels.filter { $0.countryID == country.id }; let active = available.contains { $0.state == "CONNECTED" }
        return Button { model.selectCountry(country) } label: {
            HStack(spacing: 10) {
                Text(country.flag).font(.system(size: 21)); Text(country.name).font(.system(size: 12, weight: active ? .semibold : .regular)); Spacer()
                if active { Image(systemName: "checkmark").foregroundStyle(.green) }
                else if available.count > 1 { Text("\(available.count)").font(.system(size: 10)).foregroundStyle(.secondary) }
                else if available.isEmpty { Image(systemName: "minus").foregroundStyle(.tertiary) }
            }.padding(.horizontal, 10).padding(.vertical, 9).background(active ? Color.green.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(available.isEmpty || model.switching || !model.enabled)
            .help(available.isEmpty ? "Profilo da installare" : available.count > 1 ? "Scegli server" : "Connetti")
            .accessibilityLabel("\(country.name), \(available.count) server\(active ? ", connesso" : "")")
    }
    func sidePanel(_ drawer: Drawer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(drawerTitle(drawer)).font(.headline); Spacer()
                Button { model.drawer = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Chiudi pannello").accessibilityLabel("Chiudi pannello")
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch drawer {
                    case .metrics: connectionMetrics
                    case .details: detailsPanel
                    case .servers(let id): serverList(id)
                    case .dns: DNSPanel(features: model.features, apply: model.applyDNS)
                    case .domains: DomainsPanel(features: model.features)
                    case .share: SharePanel(features: model.features, share: model.features.share)
                    case .automation: AutomationPanel(features: model.features)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(Color.primary.opacity(0.025))
    }
    func drawerTitle(_ drawer: Drawer) -> String {
        switch drawer {
        case .metrics: "Connessione"
        case .details: "Dettagli"
        case .dns: "DNS e blocco pubblicità"
        case .domains: "Domini locali"
        case .share: "Condividi un servizio"
        case .automation: "CLI e Comandi Rapidi"
        case .servers(let id): Country.catalog.first { $0.id == id }.map { "\($0.flag) \($0.name)" } ?? "Server"
        }
    }
    func serverList(_ id: String) -> some View {
        VStack(spacing: 6) {
            ForEach(model.tunnels.filter { $0.countryID == id }, id: \.name) { tunnel in
                Button { if tunnel.state != "CONNECTED" { model.connect(tunnel.name) } } label: {
                    HStack {
                        Text(tunnel.name.replacingOccurrences(of: "VPNBar-\(id)-", with: "")).font(.system(size: 12, weight: .medium)); Spacer()
                        if tunnel.state == "CONNECTED" { Image(systemName: "checkmark").foregroundStyle(.green) }
                        else if tunnel.busy { ProgressView().controlSize(.mini) }
                    }.padding(12).frame(maxWidth: .infinity).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.switching || !model.enabled).accessibilityLabel("Connetti a \(tunnel.name)")
            }
        }
    }
    var connectionMetrics: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label(mbps(model.downloadRate), systemImage: "arrow.down").foregroundStyle(.blue); Spacer(); Label(mbps(model.uploadRate), systemImage: "arrow.up").foregroundStyle(.orange) }.font(.system(size: 11, weight: .semibold)).monospacedDigit()
            Chart {
                ForEach(model.traffic) { sample in
                    LineMark(x: .value("Ora", sample.date), y: .value("Mbps", sample.download)).foregroundStyle(by: .value("Direzione", "Download"))
                    LineMark(x: .value("Ora", sample.date), y: .value("Mbps", sample.upload)).foregroundStyle(by: .value("Direzione", "Upload"))
                }
            }.chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.orange]).chartLegend(.hidden).chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .chartYScale(domain: 0...max(1, model.traffic.map { max($0.download, $0.upload) }.max() ?? 1))
                .chartXScale(domain: Date().addingTimeInterval(-180)...Date()).frame(height: 130)
                .overlay { if model.traffic.isEmpty { Text(model.connected == nil ? "VPN disconnessa" : "Raccolta campioni…").font(.caption).foregroundStyle(.secondary) } }
                .accessibilityLabel("Traffico VPN negli ultimi 3 minuti, in Mbps")
            Text("Ultimi 3 minuti").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack { Label(model.pingText, systemImage: "speedometer").font(.system(size: 13, weight: .medium)); Spacer(); Text("Ping · 15 s").font(.system(size: 10)).foregroundStyle(.secondary) }.help("Ping ICMP verso 1.1.1.1, aggiornato ogni 15 secondi. — indica nessuna risposta.")
            Divider()
            HStack {
                Text("Speed test").font(.system(size: 13, weight: .semibold)); Spacer()
                if model.testingSpeed { ProgressView().controlSize(.mini); Button("Annulla") { model.cancelSpeedTest() }.controlSize(.small) }
                else { Button(model.speedResult == nil ? "Avvia" : "Ripeti") { model.testSpeed() }.controlSize(.small).disabled(model.connected == nil || model.switching) }
            }
            if let result = model.speedResult {
                HStack { compactMetric("arrow.down", mbps(result.download), color: .blue); Spacer(); compactMetric("arrow.up", mbps(result.upload), color: .orange) }
                Text("\(result.date.formatted(date: .omitted, time: .shortened)) · Latenza test \(String(format: "%.0f", result.latency)) ms").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let error = model.speedError { Text(error).font(.caption).foregroundStyle(.orange) }
            Text(model.testingSpeed ? "Misurazione…" : "Il test genera traffico Internet.").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.connected?.name ?? "Nessun server").font(.caption).textSelection(.enabled)
            Text("IP: \(model.ip ?? "—")").font(.caption).textSelection(.enabled)
            Button(model.checkingIP ? "Verifica…" : "Verifica IP") { model.checkIP() }.disabled(model.connected == nil || model.checkingIP)
            Text("Ping: 1.1.1.1 · ogni 15 s. Nessuna risposta: —.").font(.caption).foregroundStyle(.secondary)
            Text("Contatori cumulativi di Tunnelblick. Lo speed test misura la connessione Internet con macOS.").font(.caption).foregroundStyle(.secondary)
            Text("La verifica IP contatta api.ipify.org. Durante il cambio server il traffico può usare la rete normale. Lo stato connesso non verifica perdite DNS o IPv6.").font(.caption).foregroundStyle(.secondary)
            Link("Configura profili Proton", destination: URL(string: "https://account.protonvpn.com/downloads")!).font(.caption)
        }
    }
    func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .binary) }
}
