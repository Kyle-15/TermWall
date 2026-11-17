// TermWall screen saver: plays the same wall.html with the same settings as the TermWall app.
// macOS runs it inside its sandboxed screen saver host, which may read (not write) the user's files,
// so it reads ~/Library/Application Support/TermWall/config.json directly.

import ScreenSaver
import WebKit

#if TERMWALL_DIAG
/// Test builds only: report to a listener on this Mac, since the screen saver host's logs and files aren't reachable.
func diag(_ m: String) {
    var c = URLComponents(string: "http://127.0.0.1:8799/log")!
    c.queryItems = [URLQueryItem(name: "m", value: m)]
    URLSession.shared.dataTask(with: c.url!).resume()
}
#else
@inline(__always) func diag(_ m: String) {}
#endif

@objc(TermWallSaverView)
final class TermWallSaverView: ScreenSaverView, WKNavigationDelegate {
    @objc dynamic var webView: WKWebView?
    // macOS 14+ often never calls startAnimation for third-party screen savers, so play right away
    // and only stop when told the screen saver is closing.
    private var running = true
    private var background = NSColor.black
    private var observers: [NSObjectProtocol] = []
    /// True while the real screen saver is on screen (shared by every TermWall view in this process).
    private static var saverActive = false
    /// Views made before the screen saver started belong to System Settings' previews, not the screen saver itself.
    private var settingsPreview = false

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit { observers.forEach { DistributedNotificationCenter.default().removeObserver($0) } }

    private func commonInit() {
        diag("init preview=\(isPreview) frame=\(Int(frame.width))x\(Int(frame.height))")
        settingsPreview = !TermWallSaverView.saverActive
        animationTimeInterval = 1   // wall.html runs its own frame loop; animateOneFrame does nothing
        wantsLayer = true
        // On macOS 14+ the screen saver host often never calls stopAnimation; this notification still arrives.
        let dn = DistributedNotificationCenter.default()
        observers.append(dn.addObserver(forName: .init("com.apple.screensaver.willstop"), object: nil, queue: .main) { [weak self] _ in diag("notification willstop"); self?.halt() })
        observers.append(dn.addObserver(forName: .init("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            diag("notification didstop")
            TermWallSaverView.saverActive = false
            // The previews in System Settings were stopped along with the screen saver; bring them back.
            guard let self, self.settingsPreview else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.resume() }
        })
        observers.append(dn.addObserver(forName: .init("com.apple.screensaver.willstart"), object: nil, queue: .main) { _ in diag("notification willstart") })
        // If this same view is shown again later, bring it back.
        observers.append(dn.addObserver(forName: .init("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            diag("notification didstart")
            TermWallSaverView.saverActive = true
            // System Settings' previews are hidden behind the screen saver now; no need to draw them.
            if let self, self.settingsPreview { self.halt() }
        })
        setUpWebView()
    }

    private func setUpWebView() {
        let cfg = WallConfig.load()
        background = NSColor(hex: cfg.background)
        layer?.backgroundColor = background.cgColor

        var js = "window.onerror = (m, s, l) => { window.__err = String(m) + ' line ' + l; };" + injectionScript(cfg)
        if isPreview {
            // The System Settings thumbnail is tiny: shrink the characters so the art still fits.
            let k = max(0.12, bounds.width / max(1, NSScreen.main?.frame.width ?? 1440))
            js += "TERMWALL_CONFIG.cellSize = Math.max(3, (TERMWALL_CONFIG.cellSize || 14) * \(k)); TERMWALL_CONFIG.detail = 0.5;"
        }
        let conf = WKWebViewConfiguration()
        setWebKitFeature(conf.preferences, key: "PreferPageRenderingUpdatesNear60FPSEnabled", enabled: false)
        conf.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        conf.suppressesIncrementalRendering = true
        let wv = WKWebView(frame: bounds, configuration: conf)
        wv.autoresizingMask = [.width, .height]
        wv.underPageBackgroundColor = background
        wv.setValue(false, forKey: "drawsBackground")   // no white frame before the page paints; the window colour shows instead
        wv.navigationDelegate = self
        // The screen saver host shows this view through a remote layer, so WebKit can wrongly decide the
        // window is hidden and stop handing out animation frames. Turn that check off (WebKit SPI, if present).
        let occ = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if wv.responds(to: occ) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(wv.method(for: occ), to: SetBool.self)(wv, occ, false)
        }
        diag("occlusion check off: \(wv.responds(to: occ))")
        addSubview(wv)
        webView = wv
        if let html = Bundle(for: TermWallSaverView.self).url(forResource: "wall", withExtension: "html") {
            wv.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        diag("setup settings=\(configURL.path) readable=\(FileManager.default.isReadableFile(atPath: configURL.path)) html=\(Bundle(for: TermWallSaverView.self).url(forResource: "wall", withExtension: "html")?.path ?? "MISSING") bg=\(cfg.background)")
        #if TERMWALL_DIAG
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let wv = self.webView else { diag("tick: no webView (running=\(self.running))"); return }
            wv.evaluateJavaScript("JSON.stringify({stats: window.termwall ? termwall.stats() : 'no termwall', err: window.__err || null, hz: window.TERMWALL_HZ || null})") { r, e in
                diag("tick preview=\(self.isPreview) running=\(self.running) winVisible=\(self.window?.isVisible ?? false) occl=\(self.window?.occlusionState.contains(.visible) ?? false) -> \((r as? String) ?? "js error: \(String(describing: e))")")
            }
        }
        #endif
        NSLog("TermWallSaver: started (preview: %@, settings: %@, found: %@, logo: %@)",
              isPreview ? "yes" : "no", configURL.path,
              FileManager.default.isReadableFile(atPath: configURL.path) ? "yes" : "no",
              cfg.logoPath.isEmpty ? "none" : (FileManager.default.isReadableFile(atPath: cfg.logoPath) ? "readable" : "NOT readable"))
    }

    private func send(_ js: String) { webView?.evaluateJavaScript(js, completionHandler: nil) }

    private func playIfRunning() {
        guard running else { return }
        let hz = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        send("window.TERMWALL_HZ = \(hz); window.termwall && termwall.setPaused(false);")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { diag("didFail \(error)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { diag("didFailProvisional \(error)") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { diag("web content process terminated") }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        diag("didFinish running=\(running)")
        playIfRunning()
        if !isPreview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.webView?.evaluateJavaScript("termwall.stats()") { s, _ in NSLog("TermWallSaver: %@", (s as? String) ?? "no stats") }
            }
        }
    }

    override func startAnimation() {
        super.startAnimation()
        diag("startAnimation")
        if settingsPreview && TermWallSaverView.saverActive { return }   // hidden behind the screen saver
        resume()
    }

    private func resume() {
        running = true
        if webView == nil { setUpWebView() }
        playIfRunning()
    }

    override func stopAnimation() {
        super.stopAnimation()
        diag("stopAnimation")
        halt()
    }

    /// Stop drawing. Outside the preview, also drop the page so nothing keeps running in the background.
    private func halt() {
        diag("halt")
        running = false
        send("window.termwall && termwall.setPaused(true)")
        if !isPreview, let wv = webView {
            wv.removeFromSuperview()
            webView = nil
            NSLog("TermWallSaver: stopped")
        }
    }

    override func draw(_ rect: NSRect) {
        background.setFill()
        rect.fill()
    }

    override func animateOneFrame() {}
    override var hasConfigureSheet: Bool { false }
}
