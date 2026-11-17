// Shared by the TermWall app and the TermWall screen saver: settings, themes and page set-up.

import Cocoa
import WebKit

// MARK: - Paths

let appName = "TermWall"
/// The user's real home folder. Inside the screen saver's sandbox NSHomeDirectory() points at a container instead.
let realHome: String = {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
    return NSHomeDirectory()
}()
let supportDir: URL = {
    // TERMWALL_HOME points at another config folder (handy for demos and testing).
    let u = ProcessInfo.processInfo.environment["TERMWALL_HOME"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: realHome).appendingPathComponent("Library/Application Support/\(appName)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()
let configURL = supportDir.appendingPathComponent("config.json")

// MARK: - Config

let classicEffects = ["decrypt", "rain", "beams", "matrix", "slide", "print", "burn", "expand", "scatter", "sweep", "waves", "spotlights"]
let newEffects = ["thunder", "funnel", "blackhole", "vortex", "bounce", "glitch", "unstable", "fireworks", "ripple", "laser", "overflow", "condense"]
let allEffects = classicEffects + newEffects
let weightOptions: [(name: String, value: String)] = [
    ("Ultralight", "100"), ("Thin", "200"), ("Light", "300"), ("Regular", "400"), ("Medium", "500"),
    ("Semibold", "600"), ("Bold", "700"), ("Heavy", "800"), ("Black", "900"),
]

let gradientDirections: [(name: String, value: String)] = [
    ("Diagonal ↘", "diagonal"), ("Diagonal ↗", "diagonal2"), ("Horizontal", "horizontal"), ("Vertical", "vertical"),
    ("Radial", "radial"), ("From a corner", "corner"), ("From the middle out", "mirror"), ("Around the center", "conic"),
    ("Diamond", "diamond"), ("Rings", "rings"), ("Stripes", "stripes"), ("Waves", "waves"), ("Random each animation", "random"),
]
let shineStyles: [(name: String, value: String)] = [
    ("Diagonal sweep ↘", "sweep"), ("Diagonal sweep ↗", "sweep2"), ("Slide left → right", "right"), ("Slide right → left", "left"),
    ("Slide top → bottom", "down"), ("Slide bottom → top", "up"), ("Growing square outline", "box"), ("Growing circle outline", "circle"),
    ("Growing diamond outline", "diamond"), ("Sparkle", "sparkle"), ("Random each time", "random"), ("Off", "off"),
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
    var gradientDirection: String = "diagonal"  // a direction or pattern (see gradientDirections), or "random" each animation
    var colorChange: String = "off"            // "off" | "hue" (shift your colours) | "themes" (random theme), each animation
    var colorFlow: Double = 0                  // gradient moving across the art: 0 = still, 1 = fast
    var colorChangeBackground: Bool = false    // with colorChange: the background changes too (fades)
    var size: Double = 0.6
    var cellSize: Double = 14
    var effects: [String] = allEffects
    var holdSeconds: Double = 8
    var speed: Double = 1
    var shine: String = "sweep"                // light passing over the held art: a style, "random" or "off"
    var flashes: Double = 1                    // flashing lights: 0 = off, 1 = full
    var asciiArt: String = ""
    // Performance & battery
    var fps: Double = 0                        // 0 = match the display
    var renderScale: Double = 1                // 1 = full Retina, 0.5 = half
    var detail: Double = 1                     // particle density
    var pauseWhenCovered: Bool = true
    var pauseOnBattery: Bool = false
    var pauseInLowPower: Bool = true
    var matchWallpaper: Bool = true            // set the macOS wallpaper to the background colour so switching Spaces doesn't flash it

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

// MARK: - Page set-up

/// The script that hands settings (and the logo) to wall.html before it runs.
func injectionScript(_ cfg: WallConfig) -> String {
    // Known settings come from cfg; extra keys in config.json (e.g. "exits") are passed to the page as-is.
    var dict = (try? JSONEncoder().encode(cfg)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    if let data = try? Data(contentsOf: configURL), let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        for (k, v) in raw where dict[k] == nil { dict[k] = v }
    }
    let json = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    var js = "window.TERMWALL_CONFIG = \(json);"
    if let logo = logoDataURL(cfg.logoPath) { js += "window.TERMWALL_LOGO = \"\(logo)\";" }
    return js
}
