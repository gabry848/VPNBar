import Foundation

public struct ControlRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let command: String
    public let argument: String?
    public init(command: String, argument: String? = nil) { id = UUID(); self.command = command; self.argument = argument }
    public var url: URL {
        var components = URLComponents(); components.scheme = "vpnbar"; components.host = "command"
        components.queryItems = [URLQueryItem(name: "payload", value: try! JSONEncoder().encode(self).base64EncodedString())]
        return components.url!
    }
    public static func decode(_ url: URL) throws -> ControlRequest {
        guard url.scheme == "vpnbar", url.host == "command", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let payload = parts.queryItems?.first(where: { $0.name == "payload" })?.value,
              payload.count <= 20000, let data = Data(base64Encoded: payload) else { throw FeatureError("Richiesta VPNBar non valida.") }
        let request = try JSONDecoder().decode(ControlRequest.self, from: data)
        guard ["status", "connect", "disconnect", "ip", "copy-ip", "dns", "domain-add", "domain-remove", "domains", "share", "share-stop", "share-status"].contains(request.command) else {
            throw FeatureError("Comando VPNBar non valido.")
        }
        return request
    }
}

public struct ControlReply: Codable, Sendable {
    public var ok: Bool
    public var value: String
    public init(ok: Bool, value: String) { self.ok = ok; self.value = value }
}

public enum ControlClient {
    public static func send(_ request: ControlRequest) async throws -> ControlReply {
        try AppPaths.prepare()
        let requestPath = AppPaths.directory.appendingPathComponent("request-\(request.id.uuidString).json")
        try AppPaths.save(request, to: requestPath.lastPathComponent)
        let replyPath = AppPaths.directory.appendingPathComponent("reply-\(request.id.uuidString).json")
        defer { try? FileManager.default.removeItem(at: replyPath); try? FileManager.default.removeItem(at: requestPath) }
        try await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            var arguments = ["-g"]
            if let override = ProcessInfo.processInfo.environment["VPNBAR_APP"] { arguments += ["-a", override] }
            else {
                let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                arguments += ["-a", bundle.pathExtension == "app" ? bundle.path : "VPNBar"]
            }
            process.arguments = arguments + [request.url.absoluteString]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw FeatureError("Installa o apri VPNBar.app prima di usare questo comando.") }
        }.value
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let data = try? Data(contentsOf: replyPath), let reply = try? JSONDecoder().decode(ControlReply.self, from: data) { return reply }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw FeatureError("VPNBar non ha risposto. Controlla eventuali richieste di macOS.")
    }
}

public enum HostsDocument {
    public static let begin = "# BEGIN VPNBar local domains"
    public static let end = "# END VPNBar local domains"
    public static func replacing(_ original: String, domains: [LocalDomain]) throws -> String {
        try NetworkRequest(operation: .domains, domains: domains).validate()
        var lines = original.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0] == begin }, ends = lines.indices.filter { lines[$0] == end }
        guard starts.count <= 1, ends.count <= 1, starts.count == ends.count else { throw FeatureError("Il blocco VPNBar in /etc/hosts è incompleto. Correggilo prima di continuare.") }
        if let start = starts.first, let finish = ends.first {
            guard start < finish else { throw FeatureError("Il blocco VPNBar in /etc/hosts non è valido.") }
            lines.removeSubrange(start...finish)
        }
        // A domain already owned elsewhere in hosts must not acquire an ambiguous second address.
        let names = Set(domains.map(\.name))
        for line in lines {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let words = content.split(whereSeparator: \.isWhitespace).dropFirst()
            guard !words.contains(where: { names.contains($0.lowercased()) }) else { throw FeatureError("Un dominio è già configurato fuori dal blocco VPNBar in /etc/hosts.") }
        }
        if !domains.isEmpty {
            if lines.last == "" { lines.removeLast() }
            lines += [begin] + domains.sorted { $0.name < $1.name }.map { "\($0.address)\t\($0.name)" } + [end, ""]
        }
        return lines.joined(separator: "\n")
    }
}
