// TermWall: an animated terminal-text-effects wallpaper that lives on your desktop.
// A menu-bar app puts a borderless window at desktop level on every screen
// (behind your icons) and plays wall.html in it.

import Cocoa
import WebKit
import SwiftUI
import UniformTypeIdentifiers
import IOKit.ps

// Settings, themes, logo and page set-up live in Shared.swift (the screen saver uses them too).

let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/local.termwall.plist")

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

// MARK: - Matching macOS wallpaper

/// For the first instant of a Space switch macOS shows nothing but each Space's own wallpaper, so the old
/// wallpaper blinks. Setting the macOS wallpaper to a still of TermWall (its held art, or the plain
/// background until there is one) hides that. The user's wallpaper settings are backed up first and put
/// back on quit.
enum WallpaperMatch {
    static let store = URL(fileURLWithPath: realHome)
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    static let backup = supportDir.appendingPathComponent("wallpaper-backup.plist")
    static let originals = supportDir.appendingPathComponent("wallpaper-backup.json")
    /// Only the one running TermWall app touches the wallpaper (not the debug instances).
    static var enabled = false
    /// Latest still of TermWall per screen (keyed by display ID).
    static var stills: [String: URL] = [:]
    private static var background = "#000000"

    static func key(_ s: NSScreen) -> String { "\((s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0)" }

    private static func solidURL(_ hex: String) -> URL {
        supportDir.appendingPathComponent("desktop-\(hex.replacingOccurrences(of: "#", with: "").lowercased()).png")
    }
    private static func isOurs(_ u: URL?) -> Bool {
        guard let u else { return false }
        return u.deletingLastPathComponent().standardizedFileURL == supportDir.standardizedFileURL && u.lastPathComponent.hasPrefix("desktop-")
    }

    /// Makes the macOS wallpaper on every screen of the current Space match TermWall.
    static func apply(background hex: String) {
        guard enabled else { return }
        let fm = FileManager.default
        if hex != background { stills.removeAll(); background = hex }
        let solid = solidURL(hex), color = NSColor(hex: hex)
        if !fm.fileExists(atPath: solid.path) {
            let img = NSImage(size: NSSize(width: 16, height: 16))
            img.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 16, height: 16).fill(); img.unlockFocus()
            guard let png = pngData(img, maxSide: 16), (try? png.write(to: solid)) != nil else { return }
        }
        let screens = NSScreen.screens
        let want = screens.map { stills[key($0)] ?? solid }
        let current = screens.map { NSWorkspace.shared.desktopImageURL(for: $0) }
        if zip(current, want).allSatisfy({ $0 == $1 }) { return }
        // Back up the user's wallpaper before the first change (or again if they picked a new one meanwhile).
        let saved = (try? Data(contentsOf: originals)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let userChanged = current.contains { u in u != nil && !isOurs(u) && !saved.contains(u!.path) }
        if !fm.fileExists(atPath: backup.path) || userChanged {
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: store, to: backup)
            let paths = current.compactMap { u in isOurs(u) ? nil : u?.path }
            try? JSONEncoder().encode(paths).write(to: originals)
        }
        for (i, screen) in screens.enumerated() where current[i] != want[i] {
            try? NSWorkspace.shared.setDesktopImageURL(want[i], for: screen, options: [
                .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true, .fillColor: color])
        }
    }

    /// Saves a still of TermWall for one screen and makes it that screen's wallpaper.
    static func setStill(_ image: NSImage, for screen: NSScreen, tag: String) {
        guard enabled else { return }
        let px = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        let safeTag = tag.filter { $0.isLetter || $0.isNumber }
        // A new name per picture: macOS caches wallpapers by file name.
        let url = supportDir.appendingPathComponent("desktop-\(key(screen))-\(safeTag)-\(Int(Date().timeIntervalSince1970)).png")
        guard let png = pngData(image, maxSide: px), (try? png.write(to: url)) != nil else { return }
        let old = stills[key(screen)]
        stills[key(screen)] = url
        apply(background: background)
        // Other Spaces may still show the previous picture until they're visited, so keep that one too;
        // anything older for this screen goes.
        prune(screen: key(screen), keep: [url, old].compactMap { $0 })
    }

    /// Deletes this screen's old stills except the ones to keep.
    static func prune(screen k: String, keep: [URL]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) else { return }
        let names = Set(keep.map(\.lastPathComponent))
        for f in files where f.lastPathComponent.hasPrefix("desktop-\(k)-") && !names.contains(f.lastPathComponent) { try? fm.removeItem(at: f) }
    }

    /// Puts the user's own wallpaper back (if TermWall changed it).
    static func restore() {
        guard enabled else { return }
        let fm = FileManager.default
        defer {
            stills.removeAll()
            if let files = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
                for f in files where f.lastPathComponent.hasPrefix("desktop-") && f.pathExtension == "png" { try? fm.removeItem(at: f) }
            }
        }
        guard fm.fileExists(atPath: backup.path) else { return }
        if let data = try? Data(contentsOf: backup), (try? data.write(to: store, options: .atomic)) != nil {
            // The wallpaper agent re-reads its settings when it restarts (macOS relaunches it right away).
            // It may save its own copy as it quits, so check the settings stuck and try again if not.
            for _ in 0..<3 {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                p.arguments = ["WallpaperAgent"]
                try? p.run(); p.waitUntilExit()
                Thread.sleep(forTimeInterval: 0.8)
                let now = NSScreen.screens.map { NSWorkspace.shared.desktopImageURL(for: $0) }
                if !now.contains(where: { isOurs($0) }) { break }
                try? data.write(to: store, options: .atomic)
            }
        } else if let data = try? Data(contentsOf: originals), let paths = try? JSONDecoder().decode([String].self, from: data), let first = paths.first {
            for screen in NSScreen.screens { try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: first), for: screen, options: [:]) }
        }
        try? fm.removeItem(at: backup)
        try? fm.removeItem(at: originals)
    }

    static func sync(_ cfg: WallConfig) {
        if cfg.matchWallpaper { apply(background: cfg.background) } else { restore() }
    }
}

// MARK: - Desktop windows

final class WallWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Forwards page messages without the content controller keeping the controller alive.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

final class WallpaperController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private(set) var windows: [NSWindow] = []
    private var webViews: [WKWebView] = []
    private var sentPause: [Bool] = []
    private(set) var cfg = WallConfig.load()
    private(set) var highRefresh = false
    var userPaused = false
    var systemPaused = false
    var saverRunning = false         // the TermWall (or any) screen saver is showing
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
        lastStill.removeAll()

        cfg = WallConfig.load()
        WallpaperMatch.sync(cfg)
        var js = injectionScript(cfg)
        if let fe = forceEffect { js += "window.TERMWALL_FORCE_EFFECT = \"\(fe)\";" }
        let bg = NSColor(hex: cfg.background)
        let startPaused = basePaused()

        for screen in NSScreen.screens {
            let w = WallWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.setFrame(screen.frame, display: false)
            // Just below the desktop icons rather than at the wallpaper's own level: macOS leaves windows at the
            // wallpaper level out of the Space-switch animation (measured: 0.45 s gap), but keeps this one in.
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
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
            conf.userContentController.add(WeakMessageHandler(self), name: "termwall")
            conf.suppressesIncrementalRendering = true
            let wv = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: conf)
            wv.autoresizingMask = [.width, .height]
            wv.underPageBackgroundColor = bg
            wv.setValue(false, forKey: "drawsBackground")   // no white frame before the page paints; the window colour shows instead
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

    /// The page holds its art still: take a picture of it for the macOS wallpaper, once per screen after
    /// each start or Apply (it only covers a ~0.05 s blink, so it needn't follow every weight or colour).
    private var lastStill: Set<String> = []
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard cfg.matchWallpaper, WallpaperMatch.enabled, let wv = m.webView, let i = webViews.firstIndex(of: wv),
              let screen = windows[i].screen, let body = m.body as? [String: Any], (body["phase"] as? String) == "hold" else { return }
        let k = WallpaperMatch.key(screen), tag = (body["weight"] as? String) ?? ""
        if lastStill.contains(k) { return }
        lastStill.insert(k)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak wv] in
            guard let self, let wv, self.webViews.contains(wv) else { return }
            let conf = WKSnapshotConfiguration(); conf.afterScreenUpdates = true
            wv.takeSnapshot(with: conf) { img, _ in
                guard let img, let s = wv.window?.screen else { return }
                WallpaperMatch.setStill(img, for: s, tag: tag)
            }
        }
    }

    func basePaused() -> Bool {
        userPaused || systemPaused || saverRunning
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
        if saverRunning { return "Paused (screen saver showing)" }
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
                        ForEach(gradientDirections, id: \.value) { Text($0.name).tag($0.value) }
                    }
                    Picker("New colors each animation", selection: $model.cfg.colorChange) {
                        Text("Off").tag("off"); Text("Shift your colors").tag("hue"); Text("Random theme").tag("themes")
                    }
                    Toggle("Change the background too (fades)", isOn: $model.cfg.colorChangeBackground)
                        .disabled(model.cfg.colorChange == "off")
                    LabeledContent("Flowing gradient") {
                        HStack {
                            Slider(value: $model.cfg.colorFlow, in: 0...1, step: 0.05)
                            Text(model.cfg.colorFlow < 0.01 ? "Off" : model.cfg.colorFlow < 0.35 ? "Slow" : model.cfg.colorFlow < 0.7 ? "Medium" : "Fast").frame(width: 56)
                        }
                    }
                    Text("A flowing gradient keeps moving while your art holds still, so it uses a little more power than Off.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("Character style", selection: $model.cfg.style) {
                        Text("Blocks ▟█▙").tag("blocks"); Text("ASCII @#*:.").tag("ascii")
                    }.pickerStyle(.segmented)
                    Toggle("Drop shadow", isOn: $model.cfg.shadow)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Smooth Space switching", isOn: $model.cfg.matchWallpaper)
                        Text("Sets your macOS wallpaper to the background color while TermWall runs, so switching Spaces doesn't flash your old wallpaper. Quitting TermWall puts yours back.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
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
                    Picker("Shine while holding", selection: $model.cfg.shine) {
                        ForEach(shineStyles, id: \.value) { Text($0.name).tag($0.value) }
                    }
                    LabeledContent("Flashing lights") {
                        HStack {
                            Slider(value: $model.cfg.flashes, in: 0...1, step: 0.05)
                            Text(model.cfg.flashes < 0.01 ? "Off" : "\(Int((model.cfg.flashes * 100).rounded()))%").monospacedDigit().frame(width: 44)
                        }
                    }
                    HStack {
                        Text("Screen flashes, lightning, bursts and glitch flicker.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Off") { model.cfg.flashes = 0 }
                        Button("Soft") { model.cfg.flashes = 0.35 }
                        Button("Full") { model.cfg.flashes = 1 }
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
                    Text("Frame rate matters most: anything below your screen's refresh rate saves a lot, because macOS then redraws the desktop less often. Between animations and while paused nothing is drawn at all.")
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
        WallpaperMatch.enabled = ProcessInfo.processInfo.environment["TERMWALL_NOWALL"] == nil
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
            if let cfg = self?.wall.cfg, cfg.matchWallpaper { WallpaperMatch.apply(background: cfg.background) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.wall.refreshPause() }
        }
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.setSystemPaused(true) }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.setSystemPaused(false) }
        // No point animating the desktop underneath a screen saver.
        dn.addObserver(forName: .init("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            self?.wall.saverRunning = true; self?.wall.refreshPause()
        }
        dn.addObserver(forName: .init("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            self?.wall.saverRunning = false; self?.wall.refreshPause()
        }

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
        // Easter eggs: hold Option while the menu is open and "Next Effect" becomes "Send In the Troops";
        // hold Option+Shift for "Call In the Airstrike". These items have no letter shortcut on purpose:
        // with one, macOS ignores Shift when picking which alternate to show.
        let next = m.addItem(withTitle: "Next Effect", action: #selector(nextEffect), keyEquivalent: "")
        next.keyEquivalentModifierMask = []; next.target = self
        let troops = m.addItem(withTitle: "Send In the Troops", action: #selector(sendTroops), keyEquivalent: "")
        troops.keyEquivalentModifierMask = [.option]; troops.isAlternate = true; troops.target = self
        let strike = m.addItem(withTitle: "Call In the Airstrike", action: #selector(callAirstrike), keyEquivalent: "")
        strike.keyEquivalentModifierMask = [.option, .shift]; strike.isAlternate = true; strike.target = self
        pauseItem = m.addItem(withTitle: "Pause", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r").target = self
        m.addItem(withTitle: "Open Config Folder", action: #selector(openFolder), keyEquivalent: "").target = self
        m.addItem(withTitle: "Install Screen Saver…", action: #selector(installSaver), keyEquivalent: "").target = self
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
    @objc func sendTroops() {
        // Backup: if Shift is held too, they asked for the airstrike even if the menu showed the troops.
        if NSEvent.modifierFlags.contains(.shift) || NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return callAirstrike() }
        wall.eval("window.termwall && termwall.troops()")
    }
    @objc func callAirstrike() { wall.eval("window.termwall && termwall.airstrike()") }
    @objc func togglePause() {
        wall.userPaused.toggle(); wall.refreshPause()
        pauseItem.title = wall.userPaused ? "Resume" : "Pause"
    }
    @objc func reload() { wall.rebuild() }
    @objc func openFolder() { NSWorkspace.shared.open(supportDir) }

    /// Copies the TermWall screen saver that ships inside the app to ~/Library/Screen Savers,
    /// then opens Screen Saver settings so it can be picked.
    @objc func installSaver() {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: realHome).appendingPathComponent("Library/Screen Savers/TermWall.saver")
        guard let src = Bundle.main.url(forResource: "TermWall", withExtension: "saver") else { return }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't install the screen saver"; a.informativeText = error.localizedDescription; a.runModal()
            return
        }
        // Make the screen saver host load the new copy next time.
        let k = Process(); k.launchPath = "/usr/bin/killall"; k.arguments = ["legacyScreenSaver"]
        k.standardError = FileHandle.nullDevice; try? k.run()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")!)
        let a = NSAlert()
        a.messageText = "TermWall screen saver installed"
        a.informativeText = "Pick “TermWall” in Screen Saver settings (under Other). It uses the same words, logo, theme and effects you set in Customize."
        NSApp.activate(); a.runModal()
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ note: Notification) { WallpaperMatch.restore() }

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
