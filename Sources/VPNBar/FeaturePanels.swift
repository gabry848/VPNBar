import AppKit
import SwiftUI
import VPNBarCore

struct DNSPanel: View {
    @ObservedObject var features: FeatureModel
    let apply: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("DNS e filtri", systemImage: "hand.raised.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(.blue)
            Text("Scegli chi risolve i domini del tuo Mac.").font(.caption).foregroundStyle(.secondary)
            Picker("Resolver", selection: $features.settings.dns) {
                ForEach(DNSPreset.allCases, id: \.self) { preset in Text(preset.title).tag(preset) }
            }.labelsHidden().pickerStyle(.menu)
            if features.settings.dns == .custom {
                TextField("1.1.1.1, 1.0.0.1", text: $features.settings.customDNS).textFieldStyle(.roundedBorder)
                Text("IPv4 o IPv6, separati da virgole. Puoi usare gli IP indicati dal tuo provider NextDNS.").font(.caption2).foregroundStyle(.secondary)
            }
            if features.settings.dns == .adguard {
                Label("Blocca pubblicità e tracker via DNS", systemImage: "checkmark.shield.fill").font(.caption).foregroundStyle(.green)
                Text("Il filtro agisce sui domini. Alcune pubblicità, incluse quelle servite dallo stesso dominio del contenuto, possono restare visibili.").font(.caption2).foregroundStyle(.secondary)
            }
            Button(features.busy ? "Applicazione…" : features.settings.dns == .system ? "Ripristina DNS originali" : "Applica DNS", action: apply)
                .buttonStyle(.borderedProminent).disabled(features.busy)
            Divider()
            Text("Ultima scelta applicata: \(features.dnsApplied.title)").font(.caption)
            Text("Si applica ai servizi di rete abilitati del Mac, anche fuori dalla VPN, e resta impostato quando chiudi l’app. Con una VPN attiva, l’app la riconnette per aggiornare i DNS.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("DNS originali ripristina i valori salvati prima della prima modifica. Le modifiche esterne successive vengono conservate.")
                .font(.caption2).foregroundStyle(.secondary)
            FeatureMessage(features: features)
        }
    }
}

struct DomainsPanel: View {
    @ObservedObject var features: FeatureModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dai un nome ai tuoi servizi").font(.system(size: 15, weight: .semibold))
            TextField("api.progetto.test", text: $features.domainName).textFieldStyle(.roundedBorder)
            TextField("127.0.0.1", text: $features.domainAddress).textFieldStyle(.roundedBorder)
            Button("Aggiungi dominio") { features.addDomain() }.buttonStyle(.borderedProminent)
                .disabled(features.busy || features.domainName.isEmpty || features.domainAddress.isEmpty)
            Text("Nomi .test esatti, IPv4 o IPv6. Per esempio api.progetto.test:3000. L’associazione DNS non cambia le porte e non configura HTTPS.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            if features.settings.domains.isEmpty {
                Label("Nessun dominio locale", systemImage: "network").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(features.settings.domains) { domain in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(domain.name).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                        Text(domain.address).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { features.removeDomain(domain) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).disabled(features.busy).help("Rimuovi \(domain.name)")
                }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("Le associazioni restano disponibili anche senza VPN. Le altre righe del file hosts vengono conservate.").font(.caption2).foregroundStyle(.secondary)
            FeatureMessage(features: features)
        }
    }
}

struct SharePanel: View {
    @ObservedObject var features: FeatureModel
    @ObservedObject var share: ShareModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Da localhost a un link", systemImage: "link").font(.system(size: 15, weight: .semibold))
            TextField("http://localhost:3000", text: $features.settings.origin).textFieldStyle(.roundedBorder).disabled(share.active)
            Text("HTTP/HTTPS, con porta opzionale. Puoi condividere anche un servizio sulla rete privata.").font(.caption2).foregroundStyle(.secondary)
            if !share.active {
                Toggle("Usa il mio dominio", isOn: $features.settings.usePersonalDomain).font(.caption)
                if features.settings.usePersonalDomain {
                    TextField("demo.tuodominio.it", text: $features.settings.publicHostname).textFieldStyle(.roundedBorder)
                    TextField("UUID del tunnel Cloudflare", text: $features.settings.tunnelID).textFieldStyle(.roundedBorder)
                    Button("Scegli credenziali del tunnel…") { features.chooseCredentials() }.controlSize(.small)
                    if !features.settings.credentialsPath.isEmpty {
                        Text(URL(fileURLWithPath: features.settings.credentialsPath).lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Serve un tunnel Cloudflare già creato, con questo dominio instradato al tunnel.").font(.caption2).foregroundStyle(.secondary)
                    Link("Configura tunnel e dominio", destination: URL(string: "https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/")!).font(.caption)
                }
                Button("Condividi") {
                    Task { do { try features.save(); _ = try await share.start(features.settings) } catch { share.error = error.localizedDescription } }
                }.buttonStyle(.borderedProminent).disabled(features.settings.origin.isEmpty)
            } else {
                HStack {
                    if share.starting { ProgressView().controlSize(.mini); Text("Creazione link…").font(.caption) }
                    else { Label("Condivisione attiva", systemImage: "circle.fill").font(.caption).foregroundStyle(.green) }
                    Spacer()
                    Button("Interrompi") { share.stop() }.controlSize(.small)
                }
            }
            if share.running, let url = share.publicURL {
                Text(url.absoluteString).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Copia link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                    Button("Apri") { NSWorkspace.shared.open(url) }
                }.controlSize(.small)
            }
            if let error = share.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            Text("Il link temporaneo non richiede un account. È pubblico e cambia a ogni avvio. Si interrompe con Interrompi o chiudendo VPNBar, anche se l’app si arresta.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Condivisione tramite Cloudflare Tunnel. Per progetti Vite, aggiungi il dominio generato agli allowedHosts del server di sviluppo.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct AutomationPanel: View {
    @ObservedObject var features: FeatureModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("VPNBar nel tuo terminale").font(.system(size: 15, weight: .semibold))
            Text("vpnbar status --json\nvpnbar connect NL\nvpnbar disconnect\nvpnbar dns adguard\nvpnbar share localhost:3000\nvpnbar share stop")
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            Button("Installa comando vpnbar") { features.installCLI() }.controlSize(.small)
            Text("Crea un collegamento in ~/.local/bin. Il comando è già disponibile nel bundle dell’app.").font(.caption2).foregroundStyle(.secondary)
            Divider()
            Text("Comandi Rapidi macOS").font(.system(size: 13, weight: .semibold))
            Button("Apri Comandi Rapidi pronti") {
                NSWorkspace.shared.open(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Shortcuts"))
            }.controlSize(.small)
            Text("Importa Connetti VPN, Disconnetti VPN o Copia IP VPN. Usano la CLI tramite Esegui script shell; abilita gli script nelle impostazioni avanzate di Comandi Rapidi se richiesto.")
                .font(.caption2).foregroundStyle(.secondary)
            FeatureMessage(features: features)
        }
    }
}

struct FeatureMessage: View {
    @ObservedObject var features: FeatureModel
    var body: some View {
        if let message = features.message { Text(message).font(.caption).foregroundStyle(features.failed ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true) }
    }
}
