import AppKit
import SwiftUI
import VPNBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = VPNModel()
    var item: NSStatusItem!
    let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-previews" {
            renderPreviews(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self; item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Panel(model: model))
        model.statusChanged = { [weak self] in self?.updateIcon() }
        model.layoutChanged = { [weak self] in
            guard let self else { return }
            self.popover.contentSize = NSSize(width: self.model.panelWidth, height: 540)
        }
        popover.contentSize = NSSize(width: model.panelWidth, height: 540)
        updateIcon()
        if UserDefaults.standard.bool(forKey: "engineEnabled") { model.enable() }
    }
    private func renderPreviews(directory: URL) {
        NSApp.appearance = NSAppearance(named: .aqua)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { NSApp.terminate(nil); return }
        let drawers: [(String, Drawer)] = [("dns", .dns), ("domains", .domains), ("share", .share), ("automation", .automation)]
        model.features.settings.dns = .adguard
        model.features.settings.domains = [(try? LocalDomain(name: "api.progetto.test", address: "127.0.0.1"))].compactMap { $0 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 621, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .white
        window.appearance = NSAppearance(named: .aqua)
        func render(_ index: Int) {
            guard index < drawers.count else { NSApp.terminate(nil); return }
            model.drawer = drawers[index].1
            let host = NSHostingView(rootView: Panel(model: model).environment(\.colorScheme, .light).background(Color.white)); host.frame = NSRect(x: 0, y: 0, width: 621, height: 540)
            host.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: directory.appendingPathComponent(drawers[index].0 + ".png")) }
                }
                render(index + 1)
            }
        }
        render(0)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { toggle() }; return false
    }
    func applicationWillTerminate(_ notification: Notification) { model.features.share.stop() }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                let request = try ControlRequest.decode(url)
                let path = AppPaths.directory.appendingPathComponent("request-\(request.id.uuidString).json")
                let stored = try JSONDecoder().decode(ControlRequest.self, from: Data(contentsOf: path))
                guard stored == request else { throw FeatureError("Richiesta CLI non riconosciuta.") }
                // A webpage cannot trigger local sharing or DNS changes by inventing a custom-scheme URL.
                try FileManager.default.removeItem(at: path)
                Task {
                    let reply: ControlReply
                    do { reply = ControlReply(ok: true, value: try await model.command(request)) }
                    catch { reply = ControlReply(ok: false, value: error.localizedDescription) }
                    do { try AppPaths.save(reply, to: "reply-\(request.id.uuidString).json") } catch { model.notice = error.localizedDescription }
                }
            } catch { model.notice = "Richiesta esterna ignorata: usa il comando vpnbar o i pulsanti dell’app." }
        }
    }
    func updateIcon() {
        let connected = model.connected != nil && model.error == nil
        item.button?.image = NSImage(systemSymbolName: connected ? "shield.checkered" : "shield", accessibilityDescription: model.headline)
        item.button?.image?.isTemplate = true
        var tooltip = "VPNBar · \(model.headline)"
        if connected { tooltip += "\n↓ \(mbps(model.downloadRate)) · ↑ \(mbps(model.uploadRate)) · Ping \(model.pingText)" }
        item.button?.toolTip = tooltip
    }
    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
