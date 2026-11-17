// TermWall: an animated terminal-text-effects wallpaper that lives on your desktop.
// A menu-bar app puts a borderless window at desktop level on every screen
// (behind your icons) and plays wall.html in it.

import Cocoa
import WebKit
import SwiftUI
import UniformTypeIdentifiers
import IOKit.ps

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

let classicEffects = ["decrypt", "rain", "beams", "matrix", "slide", "print", "burn", "expand", "scatter", "sweep", "waves", "spotlights"]
let newEffects = ["thunder", "funnel", "blackhole", "vortex", "bounce", "glitch", "unstable", "fireworks", "ripple", "laser", "overflow", "condense"]
let allEffects = classicEffects + newEffects
let weightOptions: [(name: String, value: String)] = [
    ("Ultralight", "100"), ("Thin", "200"), ("Light", "300"), ("Regular", "400"), ("Medium", "500"),
    ("Semibold", "600"), ("Bold", "700"), ("Heavy", "800"), ("Black", "900"),
]

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
    var configVersion: Int = 2
    var lines: [String] = ["TERMWALL"]
    var font: String = "system-ui"
    var fontWeight: String = "900"             // legacy single weight
    var fontWeights: [String] = ["900"]        // each animation picks one of these
    var logoPath: String = ""
    var logoColors: String = "theme"           // "theme" | "original"
    var logoInvert: Bool = false
    var layout: String = "stack"               // "stack" | "side"
    var style: String = "blocks"               // "blocks" | "ascii"
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
    var asciiArt: String = ""
    // Performance & battery
    var fps: Double = 0                        // 0 = match the display
    var renderScale: Double = 1                // 1 = full Retina, 0.5 = half
    var detail: Double = 1                     // particle density
    var pauseWhenCovered: Bool = true
    var pauseOnBattery: Bool = false
    var pauseInLowPower: Bool = true

    /// Loads config.json, filling anything missing with defaults and upgrading older files.
    static func load() -> WallConfig {
        let defaults = WallConfig()
        guard let defData = try? JSONEncoder().encode(defaults),
              var dict = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any] else { return defaults }
        guard let data = try? Data(contentsOf: configURL) else { defaults.save(); return defaults }
        let user = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        for (k, v) in user { dict[k] = v }
        let upgrading = ((user["configVersion"] as? Int) ?? 1) < 2
        if upgrading {
            dict["configVersion"] = 2
            dict["fps"] = 0
            if let eff = user["effects"] as? [String] { dict["effects"] = eff + newEffects.filter { !eff.contains($0) } }
            if (user["font"] as? String) == nil || (user["font"] as? String) == "Helvetica Neue" { dict["font"] = "system-ui" }
            if let w = user["fontWeight"] as? String { dict["fontWeights"] = [w] }
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: dict),
              var cfg = try? JSONDecoder().decode(WallConfig.self, from: merged) else { return defaults }
        if cfg.fontWeights.isEmpty { cfg.fontWeights = [cfg.fontWeight] }
        if upgrading { cfg.save() }
        return cfg
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

/// Style names a font family really has (so the UI can say which weights will look the same).
func fontStyles(_ family: String) -> [String]? {
    guard family != "system-ui", let members = NSFontManager.shared.availableMembers(ofFontFamily: family) else { return nil }
    var seen = [String]()
    for m in members {
        guard m.count > 1, let s = m[1] as? String, !s.localizedCaseInsensitiveContains("italic"),
              !s.localizedCaseInsensitiveContains("oblique"), !seen.contains(s) else { continue }
        seen.append(s)
    }
    return seen
}

// MARK: - Power

func onBatteryPower() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
    return (type as String) == "Battery Power"
}

/// WebKit caps requestAnimationFrame at 60 Hz on 120 Hz screens by default; this lifts that cap.
/// Uses WebKit's feature-flag API when present and does nothing otherwise.
@discardableResult
func setWebKitFeature(_ prefs: WKPreferences, key: String, enabled: Bool) -> Bool {
    let cls: AnyObject = WKPreferences.self
    let featuresSel = NSSelectorFromString("_features"), setSel = NSSelectorFromString("_setEnabled:forFeature:")
    guard cls.responds(to: featuresSel), prefs.responds(to: setSel),
          let features = cls.perform(featuresSel)?.takeUnretainedValue() as? [NSObject] else { return false }
    let keySel = NSSelectorFromString("key")
    for f in features where f.responds(to: keySel) {
        guard (f.perform(keySel)?.takeUnretainedValue() as? String) == key else { continue }
        typealias SetFn = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(prefs.method(for: setSel), to: SetFn.self)(prefs, setSel, enabled, f)
        return true
    }
    return false
}

// MARK: - Desktop windows

final class WallWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WallpaperController: NSObject, WKNavigationDelegate {
    private(set) var windows: [NSWindow] = []
    private var webViews: [WKWebView] = []
    private var sentPause: [Bool] = []
    private(set) var cfg = WallConfig.load()
    private(set) var highRefresh = false
    var userPaused = false
    var systemPaused = false
    var forceEffect: String?
    var ignoreCover = false
    private let htmlURL: URL

    override init() {
        htmlURL = Bundle.main.url(forResource: "wall", withExtension: "html")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("wall.html")
        super.init()
    }

    func rebuild() {
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll(); webViews.removeAll(); sentPause.removeAll()

        cfg = WallConfig.load()
        let json = (try? JSONEncoder().encode(cfg)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var js = "window.TERMWALL_CONFIG = \(json);"
        if let logo = logoDataURL(cfg.logoPath) { js += "window.TERMWALL_LOGO = \"\(logo)\";" }
        if let fe = forceEffect { js += "window.TERMWALL_FORCE_EFFECT = \"\(fe)\";" }
        let bg = NSColor(hex: cfg.background)
        let startPaused = basePaused()

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
            highRefresh = setWebKitFeature(conf.preferences, key: "PreferPageRenderingUpdatesNear60FPSEnabled", enabled: false)
            let script = js + "window.TERMWALL_HZ = \(screen.maximumFramesPerSecond); window.TERMWALL_PAUSED = \(startPaused);"
            conf.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            conf.suppressesIncrementalRendering = true
            let wv = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: conf)
            wv.autoresizingMask = [.width, .height]
            wv.underPageBackgroundColor = bg
            wv.navigationDelegate = self
            w.contentView = wv
            wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
            w.orderFront(nil)
            windows.append(w); webViews.append(wv); sentPause.append(startPaused)
        }
        refreshPause()
    }

    // Re-send the pause state once a page has loaded (anything sent earlier was dropped).
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let i = webViews.firstIndex(of: webView) else { return }
        webView.evaluateJavaScript("window.termwall && termwall.setPaused(\(sentPause[i]))", completionHandler: nil)
    }

    func basePaused() -> Bool {
        userPaused || systemPaused
            || (cfg.pauseOnBattery && onBatteryPower())
            || (cfg.pauseInLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Per screen: is the desktop hidden behind a window (a game, a full-screen app, a maximized window)?
    func coveredFlags() -> [Bool] {
        guard cfg.pauseWhenCovered, !ignoreCover else { return windows.map { _ in false } }
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        let rects: [CGRect] = infos.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int) != me,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.5,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return r
        }
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        return windows.map { win in
            let f = win.frame
            let s = CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height)
            let area = s.width * s.height
            return rects.contains { r in let i = r.intersection(s); return !i.isNull && i.width * i.height >= area * 0.85 }
        }
    }

    func refreshPause() {
        let base = basePaused(), cov = coveredFlags()
        for i in webViews.indices {
            let p = base || (i < cov.count && cov[i])
            if sentPause[i] != p {
                sentPause[i] = p
                webViews[i].evaluateJavaScript("window.termwall && termwall.setPaused(\(p))", completionHandler: nil)
            }
        }
    }

    var statusText: String {
        if userPaused { return "Paused" }
        if systemPaused { return "Paused (screen locked)" }
        if cfg.pauseInLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled { return "Paused (Low Power Mode)" }
        if cfg.pauseOnBattery && onBatteryPower() { return "Paused (on battery)" }
        let n = sentPause.filter { $0 }.count
        if n == sentPause.count && n > 0 { return "Paused (desktop covered)" }
        if n > 0 { return "Running on \(sentPause.count - n) of \(sentPause.count) screens" }
        return "Running"
    }

    func eval(_ js: String) { for wv in webViews { wv.evaluateJavaScript(js, completionHandler: nil) } }
    func next() { eval("window.termwall && termwall.next()") }

    /// Debug: saves each screen as PNG and prints stats, then calls done.
    func snapshot(prefix: String, done: @escaping () -> Void) {
        var left = webViews.count
        for (i, wv) in webViews.enumerated() {
            wv.evaluateJavaScript("termwall.stats()") { stats, _ in
                print("screen \(i) [\(self.windows[i].screen?.maximumFramesPerSecond ?? 0) Hz]: \(stats ?? "?")")
                wv.evaluateJavaScript("termwall.capture()") { url, _ in
                    if let s = url as? String, let comma = s.firstIndex(of: ","),
                       let data = Data(base64Encoded: String(s[s.index(after: comma)...])) {
                        try? data.write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
                    }
                    left -= 1; if left == 0 { done() }
                }
            }
        }
    }
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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    private let maxHz = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60

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
    private func weight(_ w: String) -> Binding<Bool> {
        Binding(get: { model.cfg.fontWeights.contains(w) },
                set: { on in
                    if on { if !model.cfg.fontWeights.contains(w) { model.cfg.fontWeights.append(w) } }
                    else if model.cfg.fontWeights.count > 1 { model.cfg.fontWeights.removeAll { $0 == w } }
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
    private func preset(_ fps: Double, _ scale: Double, _ detail: Double) {
        model.cfg.fps = fps; model.cfg.renderScale = scale; model.cfg.detail = detail
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Weights")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 4) {
                            ForEach(weightOptions, id: \.value) { w in
                                Toggle(isOn: weight(w.value)) { Text(w.name).fontWeight(Font.Weight(css: w.value)) }.toggleStyle(.checkbox)
                            }
                        }
                        Text(model.cfg.fontWeights.count > 1
                             ? "Each animation uses one of the \(model.cfg.fontWeights.count) weights you picked."
                             : "Turn on several and each animation uses a different one.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let styles = fontStyles(model.cfg.font) {
                            Text("\(model.cfg.font) only has: \(styles.joined(separator: ", ")). Missing weights look like the nearest one — SF Pro has all nine.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
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
                    LabeledContent("Art size") { Slider(value: $model.cfg.size, in: 0.2...0.95) }
                    LabeledContent("Character size") {
                        HStack { Slider(value: $model.cfg.cellSize, in: 8...28, step: 1); Text("\(Int(model.cfg.cellSize)) pt").monospacedDigit().frame(width: 44) }
                    }
                }

                Section("Animation") {
                    HStack {
                        Text("\(model.cfg.effects.filter { allEffects.contains($0) }.count) of \(allEffects.count) effects on")
                        Spacer()
                        Button("All") { model.cfg.effects = allEffects }
                        Button("None") { model.cfg.effects = [] }
                    }
                    effectGrid("Classic", classicEffects)
                    effectGrid("New", newEffects)
                    LabeledContent("Hold each for") {
                        HStack { Slider(value: $model.cfg.holdSeconds, in: 2...60, step: 1); Text("\(Int(model.cfg.holdSeconds)) s").monospacedDigit().frame(width: 44) }
                    }
                    LabeledContent("Speed") {
                        HStack { Slider(value: $model.cfg.speed, in: 0.3...2.5); Text(String(format: "%.1f×", model.cfg.speed)).monospacedDigit().frame(width: 44) }
                    }
                }

                Section("Performance & battery") {
                    HStack {
                        Text("Preset")
                        Spacer()
                        Button("Max") { preset(0, 1, 1) }
                        Button("Balanced") { preset(60, 1, 1) }
                        Button("Battery saver") { preset(30, 0.5, 0.5) }
                    }
                    Picker("Frame rate", selection: $model.cfg.fps) {
                        Text("Match display (up to \(maxHz) Hz)").tag(0.0)
                        Text("60 fps").tag(60.0); Text("30 fps").tag(30.0); Text("15 fps").tag(15.0)
                    }
                    Picker("Resolution", selection: $model.cfg.renderScale) {
                        Text("Full (Retina)").tag(1.0); Text("Half (less GPU work)").tag(0.5)
                    }
                    Picker("Particles", selection: $model.cfg.detail) {
                        Text("Full").tag(1.0); Text("Reduced").tag(0.5)
                    }
                    Toggle("Pause when a game or window covers the desktop", isOn: $model.cfg.pauseWhenCovered)
                    Toggle("Pause on battery power", isOn: $model.cfg.pauseOnBattery)
                    Toggle("Pause in Low Power Mode", isOn: $model.cfg.pauseInLowPower)
                    Text("Between animations nothing is drawn, so it only uses power while an effect is playing. Paused screens use none.")
                        .font(.caption).foregroundStyle(.secondary)
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
        .frame(minWidth: 540, minHeight: 600)
    }

    @ViewBuilder private func effectGrid(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(names, id: \.self) { Toggle($0.capitalized, isOn: effect($0)).toggleStyle(.checkbox) }
            }
        }
    }

    private func chooseLogo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image, .svg]
        p.allowsMultipleSelection = false
        p.message = "Pick a logo. Transparent PNG or SVG works best."
        if p.runModal() == .OK, let url = p.url, let path = importLogo(url) { model.cfg.logoPath = path }
    }
}

extension Font.Weight {
    init(css: String) {
        switch css {
        case "100": self = .ultraLight; case "200": self = .thin; case "300": self = .light
        case "500": self = .medium; case "600": self = .semibold; case "700": self = .bold
        case "800": self = .heavy; case "900": self = .black; default: self = .regular
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let wall = WallpaperController()
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var pauseItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var statusLine: NSMenuItem!
    var rebuildWork: DispatchWorkItem?
    var powerTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        // Debug: TermWall --snapshot /path/prefix [seconds] [effect]
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            wall.ignoreCover = true
            if i + 3 < args.count { wall.forceEffect = args[i + 3] }
            wall.rebuild()
            let wait = i + 2 < args.count ? Double(args[i + 2]) ?? 12 : 12
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.wall.snapshot(prefix: args[i + 1]) { NSApp.terminate(nil) }
            }
            return
        }
        // Debug: TermWall --status   (prints what the auto-pause sees, then quits)
        if args.contains("--status") {
            wall.rebuild()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                print("high refresh flag set: \(self.wall.highRefresh)")
                print("battery: \(onBatteryPower()), low power: \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
                print("covered per screen: \(self.wall.coveredFlags())")
                print("status: \(self.wall.statusText)")
                NSApp.terminate(nil)
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
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.wall.refreshPause()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let w = n.object as? NSWindow, self.wall.windows.contains(w) else { return }
            self.wall.refreshPause()
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.setSystemPaused(true) }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.setSystemPaused(false) }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.wall.refreshPause() }
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.wall.refreshPause() }
        }
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.setSystemPaused(true) }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.setSystemPaused(false) }

        // Cheap check (a window list read) every 1.5 s so resizing a window over the desktop is noticed too.
        powerTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.wall.refreshPause() }
        powerTimer?.tolerance = 0.5
    }

    func setSystemPaused(_ p: Bool) { wall.systemPaused = p; wall.refreshPause() }

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
        m.delegate = self
        statusLine = m.addItem(withTitle: "Running", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        m.addItem(.separator())
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

    func menuWillOpen(_ menu: NSMenu) { statusLine.title = wall.statusText }

    @objc func openSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(onApply: { [weak self] _ in self?.wall.rebuild() },
                                      onPreview: { [weak self] in self?.wall.next() })
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: CommandLine.arguments.contains("--settings-snapshot") ? 2400 : 780),
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
        wall.userPaused.toggle(); wall.refreshPause()
        pauseItem.title = wall.userPaused ? "Resume" : "Pause"
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
