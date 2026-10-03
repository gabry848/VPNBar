import AppKit
import Foundation
import VPNBarCore

struct Country: Identifiable, Sendable {
    let id: String
    let name: String
    let flag: String
    let continent: String
    static let catalog: [Country] = [
        .init(id: "NL", name: "Paesi Bassi", flag: "🇳🇱", continent: "Europa"),
        .init(id: "RO", name: "Romania", flag: "🇷🇴", continent: "Europa"),
        .init(id: "PL", name: "Polonia", flag: "🇵🇱", continent: "Europa"),
        .init(id: "NO", name: "Norvegia", flag: "🇳🇴", continent: "Europa"),
        .init(id: "CH", name: "Svizzera", flag: "🇨🇭", continent: "Europa"),
        .init(id: "JP", name: "Giappone", flag: "🇯🇵", continent: "Asia"),
        .init(id: "SG", name: "Singapore", flag: "🇸🇬", continent: "Asia"),
        .init(id: "MX", name: "Messico", flag: "🇲🇽", continent: "Nord America"),
        .init(id: "CA", name: "Canada", flag: "🇨🇦", continent: "Nord America"),
        .init(id: "US", name: "Stati Uniti", flag: "🇺🇸", continent: "Nord America")
    ]
}

struct Tunnel: Sendable {
    let name: String
    let state: String
    let received: Int64
    let sent: Int64
    var countryID: String? {
        let parts = name.split(separator: "-")
        guard parts.count >= 3, parts[0] == "VPNBar", Country.catalog.contains(where: { $0.id == String(parts[1]) }) else { return nil }
        return String(parts[1])
    }
    var owned: Bool { countryID != nil }
    var busy: Bool { !["EXITING", "DISCONNECTED"].contains(state) }
}

enum EngineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum Engine {
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    static func run(_ script: String, timeout: TimeInterval = 12) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); process.arguments = ["-"]
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            try process.run()
            input.fileHandleForWriting.write(Data(script.utf8)); try input.fileHandleForWriting.close()
            async let outData = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
            async let errData = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate(); throw EngineError.message("L’operazione non risponde. Controlla eventuali richieste di macOS.") }
            let out = String(data: await outData, encoding: .utf8) ?? ""
            let err = String(data: await errData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                if err.contains("-1743") { throw EngineError.message("Consenti a VPNBar di controllare Tunnelblick in Impostazioni di Sistema → Privacy e sicurezza → Automazione.") }
                if err.contains("-128") { throw EngineError.message("Operazione annullata.") }
                throw EngineError.message(err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
    static func tunnels() async throws -> [Tunnel] {
        let result = try await run("""
        tell application "Tunnelblick"
            set configNames to get name of configurations
            set configStates to get state of configurations
            set incoming to get bytesIn of configurations
            set outgoing to get bytesOut of configurations
        end tell
        set report to ""
        repeat with i from 1 to count of configNames
            set report to report & (item i of configNames) & tab & (item i of configStates) & tab & (item i of incoming) & tab & (item i of outgoing) & linefeed
        end repeat
        return report
        """)
        return try result.split(separator: "\n").map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, !fields[0].isEmpty, !fields[1].isEmpty,
                  let received = Int64(fields[2]), let sent = Int64(fields[3]), received >= 0, sent >= 0 else { throw EngineError.message("Risposta incompleta di Tunnelblick: lo stato delle VPN non è verificabile.") }
            return Tunnel(name: fields[0], state: fields[1], received: received, sent: sent)
        }
    }
    static func command(_ verb: String, name: String) async throws {
        guard ["connect", "disconnect"].contains(verb) else { throw EngineError.message("Comando non valido") }
        _ = try await run("tell application \"Tunnelblick\" to \(verb) \(quote(name))")
    }
}

struct TrafficSample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let download: Double
    let upload: Double
}
struct SpeedResult: Sendable {
    let download: Double
    let upload: Double
    let latency: Double
    let date: Date
}
enum ProbeProcess {
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = errors
        try process.run()
        async let data = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        async let errorData = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(100)) }
        guard !process.isRunning else { throw FeatureError("Misurazione scaduta.") }
        let result = await data, failure = await errorData
        guard process.terminationStatus == 0 else { throw FeatureError(String(data: failure, encoding: .utf8) ?? "Misurazione non riuscita.") }
        return result
    }
}
enum SpeedTest {
    static func run() async throws -> SpeedResult {
        let data = try await ProbeProcess.run("/usr/bin/networkQuality", arguments: ["-c", "-M", "20"], timeout: 45)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dl = object["dl_throughput"] as? NSNumber, let ul = object["ul_throughput"] as? NSNumber,
              let rtt = object["base_rtt"] as? NSNumber, [dl.doubleValue, ul.doubleValue, rtt.doubleValue].allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw FeatureError("Risultato dello speed test incompleto.") }
        return SpeedResult(download: dl.doubleValue / 1_000_000, upload: ul.doubleValue / 1_000_000, latency: rtt.doubleValue, date: Date())
    }
}
enum PingProbe {
    static func run() async throws -> Double? {
        do {
            let data = try await ProbeProcess.run("/sbin/ping", arguments: ["-n", "-c", "1", "-W", "2000", "1.1.1.1"], timeout: 4)
            let text = String(decoding: data, as: UTF8.self)
            guard let match = text.range(of: "time[=<][0-9.]+", options: .regularExpression) else { return nil }
            return Double(text[match].dropFirst(5))
        } catch is CancellationError { throw CancellationError() } catch { return nil }
    }
}

enum Drawer: Equatable {
    case metrics, details, dns, domains, share, automation, servers(String)
    var isLeft: Bool { if case .servers = self { return false }; return true }
}
func mbps(_ value: Double) -> String { String(format: "%.1f Mbps", value) }
