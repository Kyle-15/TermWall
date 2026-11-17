// TermWall: an animated terminal-text-effects wallpaper that lives on your desktop.
// A menu-bar app puts a borderless window at desktop level on every screen
// (behind your icons) and plays wall.html in it.

import Cocoa
import WebKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Paths

let appName = "TermWall"
let supportDir: URL = {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(appName)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()
let configURL = supportDir.appendingPathComponent("config.json")
let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/local.termwall.plist")

// MARK: - Config

let allEffects = ["decrypt", "rain", "beams", "matrix", "slide", "print", "burn", "expand", "scatter", "sweep", "waves", "spotlights"]

struct Theme { let name: String; let bg: String; let gradient: [String]; let accent: String }
let themes: [Theme] = [
    Theme(name: "Tokyo Night", bg: "#1a1b26", gradient: ["#7aa2f7", "#bb9af7", "#7dcfff"], accent: "#9ece6a"),
    Theme(name: "Catppuccin", bg: "#1e1e2e", gradient: ["#89b4fa", "#cba6f7", "#f5c2e7"], accent: "#a6e3a1"),
    Theme(name: "Gruvbox", bg: "#282828", gradient: ["#fabd2f", "#fe8019", "#fb4934"], accent: "#b8bb26"),
    Theme(name: "Nord", bg: "#2e3440", gradient: ["#88c0d0", "#81a1c1", "#b48ead"], accent: "#a3be8c"),
    Theme(name: "Everforest", bg: "#2d353b", gradient: ["#a7c080", "#83c092", "#7fbbb3"], accent: "#dbbc7f"),
    Theme(name: "Kanagawa", bg: "#1f1f28", gradient: ["#7e9cd8", "#957fb8", "#d27e99"], accent: "#98bb6c"),
    Theme(name: "Rosé Pine", bg: "#191724", gradient: ["#ebbcba", "#c4a7e7", "#9ccfd8"], accent: "#31748f"),
    Theme(name: "Matte Black", bg: "#0d0d0d", gradient: ["#f2f2f2", "#bdbdbd", "#7a7a7a"], accent: "#f59e0b"),
    Theme(name: "Matrix", bg: "#000000", gradient: ["#b7ffcf", "#00ff66", "#00a344"], accent: "#00ff66"),
    Theme(name: "Synthwave", bg: "#1a1028", gradient: ["#ff7edb", "#fe4450", "#fede5d"], accent: "#36f9f6"),
]

struct WallConfig: Codable, Equatable {
    var lines: [String] = ["TERMWALL"]
    var font: String = "Helvetica Neue"
    var fontWeight: String = "900"
    var logoPath: String = ""
    var logoColors: String = "theme"      // "theme" | "original"
    var logoInvert: Bool = false
    var layout: String = "stack"          // "stack" | "side"
    var style: String = "blocks"          // "blocks" | "ascii"
    var shadow: Bool = true
    var theme: String = "Tokyo Night"
    var background: String = "#1a1b26"
    var gradient: [String] = ["#7aa2f7", "#bb9af7", "#7dcfff"]
    var accent: String = "#9ece6a"
    var gradientDirection: String = "diagonal"
    var size: Double = 0.6
    var cellSize: Double = 14
    var effects: [String] = allEffects
    var holdSeconds: Double = 8
    var speed: Double = 1
    var fps: Double = 30
    var asciiArt: String = ""

    /// Loads config.json, filling anything missing with defaults.
    static func load() -> WallConfig {
        let defaults = WallConfig()
        guard let defData = try? JSONEncoder().encode(defaults),
              var dict = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any] else { return defaults }
        guard let data = try? Data(contentsOf: configURL) else { defaults.save(); return defaults }
        if let user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (k, v) in user { dict[k] = v }
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: dict) else { return defaults }
        return (try? JSONDecoder().decode(WallConfig.self, from: merged)) ?? defaults
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? enc.encode(self).write(to: configURL, options: .atomic)
    }
}

// MARK: - Colour helpers

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt32(s.prefix(6), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let f = { (x: CGFloat) in Int((max(0, min(1, x)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", f(c.redComponent), f(c.greenComponent), f(c.blueComponent))
    }
}

// MARK: - Logo → PNG data URL

func pngData(_ img: NSImage, maxSide: CGFloat) -> Data? {
    var size = img.size
    if let rep = img.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
        size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
    guard size.width > 0, size.height > 0 else { return nil }
    let scale = maxSide / max(size.width, size.height)
    let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func logoDataURL(_ path: String) -> String? {
    guard !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    if let img = NSImage(data: data), let png = pngData(img, maxSide: 1200) {
        return "data:image/png;base64," + png.base64EncodedString()
    }
    if path.lowercased().hasSuffix(".svg") { return "data:image/svg+xml;base64," + data.base64EncodedString() }
    return nil
}

/// Copies a chosen logo into Application Support so it keeps working if the original moves.
func importLogo(_ src: URL) -> String? {
    let fm = FileManager.default
    if let old = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
        for f in old where f.lastPathComponent.hasPrefix("logo.") && f.standardizedFileURL != src.standardizedFileURL { try? fm.removeItem(at: f) }
    }
    let dest = supportDir.appendingPathComponent("logo." + (src.pathExtension.isEmpty ? "png" : src.pathExtension.lowercased()))
    if dest.standardizedFileURL == src.standardizedFileURL { return dest.path }
    try? fm.removeItem(at: dest)
    do { try fm.copyItem(at: src, to: dest); return dest.path } catch { return nil }
}

// MARK: - Desktop windows

final class WallWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WallpaperController {
    private var windows: [NSWindow] = []
    private var webViews: [WKWebView] = []
    var paused = false
    var systemPaused = false
    private let htmlURL: URL

    init() {
        htmlURL = Bundle.main.url(forResource: "wall", withExtension: "html")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("wall.html")
    }

    func rebuild() {
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll(); webViews.removeAll()

        let cfg = WallConfig.load()
        let json = (try? JSONEncoder().encode(cfg)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var js = "window.TERMWALL_CONFIG = \(json);"
        if let logo = logoDataURL(cfg.logoPath) { js += "window.TERMWALL_LOGO = \"\(logo)\";" }
        if paused || systemPaused { js += "window.TERMWALL_PAUSED = true;" }
        let bg = NSColor(hex: cfg.background)

        for screen in NSScreen.screens {
            let w = WallWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.setFrame(screen.frame, display: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            w.ignoresMouseEvents = true
            w.isOpaque = true
            w.hasShadow = false
            w.backgroundColor = bg
            w.animationBehavior = .none

            let conf = WKWebViewConfiguration()
            conf.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            conf.suppressesIncrementalRendering = true
            let wv = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: conf)
            wv.autoresizingMask = [.width, .height]
            wv.underPageBackgroundColor = bg
            w.contentView = wv
            wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
            w.orderFront(nil)
            windows.append(w); webViews.append(wv)
        }
    }

    /// Debug: `TermWall --snapshot /path/prefix [seconds]` saves each screen's wallpaper as PNG, then quits.
    func snapshot(prefix: String, done: @escaping () -> Void) {
        var left = webViews.count
        for (i, wv) in webViews.enumerated() {
            wv.takeSnapshot(with: nil) { img, _ in
                if let img, let png = pngData(img, maxSide: max(img.size.width, img.size.height)) {
                    try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
                }
                left -= 1; if left == 0 { done() }
            }
        }
    }

    func eval(_ js: String) { for wv in webViews { wv.evaluateJavaScript(js, completionHandler: nil) } }
    func next() { eval("window.termwall && termwall.next()") }
    func applyPause() { eval("window.termwall && termwall.setPaused(\(paused || systemPaused))") }
}

// MARK: - Settings UI

final class SettingsModel: ObservableObject {
    @Published var cfg: WallConfig
    let onApply: (WallConfig) -> Void
    let onPreview: () -> Void
    init(onApply: @escaping (WallConfig) -> Void, onPreview: @escaping () -> Void) {
        cfg = WallConfig.load(); self.onApply = onApply; self.onPreview = onPreview
    }
}

let fontChoices = ["system-ui", "Helvetica Neue", "Avenir Next", "Futura", "Impact", "Arial Black", "Gill Sans",
                   "Menlo", "Courier New", "American Typewriter", "Georgia", "Didot", "Copperplate",
                   "Chalkboard SE", "Marker Felt", "Rockwell", "Phosphate", "Bradley Hand"]
let weightChoices: [(String, String)] = [("Regular", "400"), ("Bold", "700"), ("Black", "900")]

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private var linesText: Binding<String> {
        Binding(get: { model.cfg.lines.joined(separator: "\n") },
                set: { model.cfg.lines = $0.components(separatedBy: "\n") })
    }
    private func color(_ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: get())) },
                set: { set(NSColor($0).hexString); model.cfg.theme = "Custom" })
    }
    private func gradColor(_ i: Int) -> Binding<Color> {
        color({ model.cfg.gradient.indices.contains(i) ? model.cfg.gradient[i] : "#ffffff" }, { hex in
            while model.cfg.gradient.count <= i { model.cfg.gradient.append(model.cfg.gradient.last ?? "#ffffff") }
            model.cfg.gradient[i] = hex
        })
    }
    private func effect(_ name: String) -> Binding<Bool> {
        Binding(get: { model.cfg.effects.contains(name) },
                set: { on in
                    if on { if !model.cfg.effects.contains(name) { model.cfg.effects.append(name) } }
                    else { model.cfg.effects.removeAll { $0 == name } }
                })
    }
    private var themeBinding: Binding<String> {
        Binding(get: { model.cfg.theme }, set: { name in
            model.cfg.theme = name
            if let t = themes.first(where: { $0.name == name }) {
                model.cfg.background = t.bg; model.cfg.gradient = t.gradient; model.cfg.accent = t.accent
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Words") {
                    TextEditor(text: linesText)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .frame(height: 64)
                    Text("Each line becomes a line on your desktop. Leave empty for logo only.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Font", selection: $model.cfg.font) {
                        ForEach(fontChoices + (fontChoices.contains(model.cfg.font) ? [] : [model.cfg.font]), id: \.self) { f in
                            Text(f == "system-ui" ? "SF Pro (system)" : f).tag(f)
                        }
                    }
                    Picker("Weight", selection: $model.cfg.fontWeight) {
                        ForEach(weightChoices, id: \.1) { Text($0.0).tag($0.1) }
                    }.pickerStyle(.segmented)
                }

                Section("Logo") {
                    HStack {
                        Text(model.cfg.logoPath.isEmpty ? "No logo" : URL(fileURLWithPath: model.cfg.logoPath).lastPathComponent)
                            .foregroundStyle(model.cfg.logoPath.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Choose Image…") { chooseLogo() }
                        if !model.cfg.logoPath.isEmpty { Button("Remove") { model.cfg.logoPath = "" } }
                    }
                    Picker("Logo colors", selection: $model.cfg.logoColors) {
                        Text("Theme gradient").tag("theme"); Text("Keep original").tag("original")
                    }.pickerStyle(.segmented)
                    Toggle("Invert (use if the logo comes out as a box)", isOn: $model.cfg.logoInvert)
                    Picker("Layout", selection: $model.cfg.layout) {
                        Text("Logo above words").tag("stack"); Text("Logo beside words").tag("side")
                    }.pickerStyle(.segmented)
                }

                Section("Look") {
                    Picker("Theme", selection: themeBinding) {
                        ForEach(themes.map(\.name), id: \.self) { Text($0).tag($0) }
                        if model.cfg.theme == "Custom" { Text("Custom").tag("Custom") }
                    }
                    ColorPicker("Background", selection: color({ model.cfg.background }, { model.cfg.background = $0 }), supportsOpacity: false)
                    ColorPicker("Accent (used by effects)", selection: color({ model.cfg.accent }, { model.cfg.accent = $0 }), supportsOpacity: false)
                    HStack {
                        Text("Gradient")
                        Spacer()
                        ColorPicker("", selection: gradColor(0), supportsOpacity: false).labelsHidden()
                        ColorPicker("", selection: gradColor(1), supportsOpacity: false).labelsHidden()
                        ColorPicker("", selection: gradColor(2), supportsOpacity: false).labelsHidden()
                    }
                    Picker("Gradient direction", selection: $model.cfg.gradientDirection) {
                        Text("Diagonal").tag("diagonal"); Text("Horizontal").tag("horizontal")
                        Text("Vertical").tag("vertical"); Text("Radial").tag("radial")
                    }
                    Picker("Character style", selection: $model.cfg.style) {
                        Text("Blocks ▟█▙").tag("blocks"); Text("ASCII @#*:.").tag("ascii")
                    }.pickerStyle(.segmented)
                    Toggle("Drop shadow", isOn: $model.cfg.shadow)
                    LabeledContent("Art size") {
                        Slider(value: $model.cfg.size, in: 0.2...0.95)
                    }
                    LabeledContent("Character size") {
                        HStack { Slider(value: $model.cfg.cellSize, in: 8...28, step: 1); Text("\(Int(model.cfg.cellSize)) pt").monospacedDigit().frame(width: 44) }
                    }
                }

                Section("Animation") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(allEffects, id: \.self) { Toggle($0.capitalized, isOn: effect($0)) }
                    }
                    LabeledContent("Hold each for") {
                        HStack { Slider(value: $model.cfg.holdSeconds, in: 2...60, step: 1); Text("\(Int(model.cfg.holdSeconds)) s").monospacedDigit().frame(width: 44) }
                    }
                    LabeledContent("Speed") {
                        HStack { Slider(value: $model.cfg.speed, in: 0.3...2.5); Text(String(format: "%.1f×", model.cfg.speed)).monospacedDigit().frame(width: 44) }
                    }
                }

                Section("Custom ASCII art (optional — replaces words and logo)") {
                    TextEditor(text: $model.cfg.asciiArt)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 90)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Next Effect") { model.onPreview() }
                Spacer()
                Button("Apply") { model.cfg.save(); model.onApply(model.cfg) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 520, minHeight: 600)
    }

    private func chooseLogo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image, .svg]
        p.allowsMultipleSelection = false
        p.message = "Pick a logo. Transparent PNG or SVG works best."
        if p.runModal() == .OK, let url = p.url, let path = importLogo(url) { model.cfg.logoPath = path }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let wall = WallpaperController()
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var pauseItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var rebuildWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            wall.rebuild()
            let wait = i + 2 < args.count ? Double(args[i + 2]) ?? 12 : 12
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.wall.snapshot(prefix: args[i + 1]) { NSApp.terminate(nil) }
            }
            return
        }
        if let i = args.firstIndex(of: "--settings-snapshot"), i + 1 < args.count {
            openSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if let v = self?.settingsWindow?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil); return
        }
        setupMenu()
        wall.rebuild()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRebuild()
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.setSystemPaused(true) }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.setSystemPaused(false) }
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.setSystemPaused(true) }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.setSystemPaused(false) }
    }

    func setSystemPaused(_ p: Bool) { wall.systemPaused = p; wall.applyPause() }

    func scheduleRebuild() {
        rebuildWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.wall.rebuild() }
        rebuildWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: appName) {
            img.isTemplate = true; statusItem.button?.image = img
        } else { statusItem.button?.title = "▚" }

        let m = NSMenu()
        m.addItem(withTitle: "Customize…", action: #selector(openSettings), keyEquivalent: ",").target = self
        m.addItem(withTitle: "Next Effect", action: #selector(nextEffect), keyEquivalent: "n").target = self
        pauseItem = m.addItem(withTitle: "Pause", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r").target = self
        m.addItem(withTitle: "Open Config Folder", action: #selector(openFolder), keyEquivalent: "").target = self
        loginItem = m.addItem(withTitle: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = FileManager.default.fileExists(atPath: launchAgentURL.path) ? .on : .off
        m.addItem(.separator())
        m.addItem(withTitle: "Quit TermWall", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = m
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(onApply: { [weak self] _ in self?.wall.rebuild() },
                                      onPreview: { [weak self] in self?.wall.next() })
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 760),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "TermWall"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func nextEffect() { wall.next() }
    @objc func togglePause() {
        wall.paused.toggle(); wall.applyPause()
        pauseItem.title = wall.paused ? "Resume" : "Pause"
    }
    @objc func reload() { wall.rebuild() }
    @objc func openFolder() { NSWorkspace.shared.open(supportDir) }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentURL.path) {
            try? fm.removeItem(at: launchAgentURL)
        } else {
            try? fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: NSDictionary = [
                "Label": "local.termwall",
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            plist.write(to: launchAgentURL, atomically: true)
        }
        loginItem.state = fm.fileExists(atPath: launchAgentURL.path) ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
