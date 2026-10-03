import Foundation
import VPNBarCore

let usage = """
vpnbar · controlla VPNBar dalla riga di comando

  vpnbar status [--json]
  vpnbar connect NL                 Paese o nome completo del server
  vpnbar disconnect
  vpnbar ip                         IP pubblico della VPN attiva
  vpnbar copy-ip                    Copia l’IP pubblico negli appunti
  vpnbar dns adguard|quad9|cloudflare|system
  vpnbar dns custom 1.1.1.1,1.0.0.1
  vpnbar domains [--json]
  vpnbar domain add api.progetto.test 127.0.0.1
  vpnbar domain remove api.progetto.test
  vpnbar share http://localhost:3000
  vpnbar share status
  vpnbar share stop

DNS e domini richiedono il consenso amministratore nella finestra macOS.
Le condivisioni terminano chiudendo VPNBar. Dominio personale: configurabile nell’app.
"""

func request(_ args: [String]) throws -> ControlRequest {
    let values = args.filter { $0 != "--json" }
    guard let command = values.first else { throw FeatureError(usage) }
    switch command {
    case "status", "disconnect", "ip", "copy-ip", "domains":
        guard values.count == 1 else { throw FeatureError(usage) }
        return ControlRequest(command: command)
    case "connect":
        guard values.count == 2 else { throw FeatureError(usage) }
        return ControlRequest(command: command, argument: values[1])
    case "dns":
        guard (2...3).contains(values.count), let preset = DNSPreset(rawValue: values[1]),
              (preset == .custom ? values.count == 3 : values.count == 2) else { throw FeatureError(usage) }
        _ = try preset.resolvedServers(values.count == 3 ? values[2] : "")
        return ControlRequest(command: "dns", argument: values.dropFirst().joined(separator: " "))
    case "domain":
        if values.count == 4, values[1] == "add" {
            let domain = try LocalDomain(name: values[2], address: values[3])
            return ControlRequest(command: "domain-add", argument: String(data: try JSONEncoder().encode(domain), encoding: .utf8))
        }
        if values.count == 3, values[1] == "remove" { return ControlRequest(command: "domain-remove", argument: values[2]) }
        throw FeatureError(usage)
    case "share":
        guard values.count == 2 else { throw FeatureError(usage) }
        if values[1] == "stop" { return ControlRequest(command: "share-stop") }
        if values[1] == "status" { return ControlRequest(command: "share-status") }
        return ControlRequest(command: "share", argument: values[1])
    default: throw FeatureError(usage)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] { print(usage); exit(0) }
do {
    let response = try await ControlClient.send(request(arguments))
    if arguments.contains("--json") {
        if response.ok, let data = response.value.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil { print(response.value) }
        else { print(String(data: try JSONEncoder().encode(response), encoding: .utf8)!) }
    } else if response.ok { print(response.value) }
    else { FileHandle.standardError.write(Data((response.value + "\n").utf8)) }
    exit(response.ok ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
