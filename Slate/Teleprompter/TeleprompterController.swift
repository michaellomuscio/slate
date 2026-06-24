import SwiftUI
import AppKit

/// Drives the teleprompter: a borderless, click-through panel docked across the top of the
/// recorded display, showing the script as a single line crawling right-to-left.
///
/// **Why it doesn't appear in the recording.** The panel belongs to the Slate app, and the
/// screen capture is built with `SCContentFilter(display:excludingApplications:[Slate]…)`
/// (see `ScreenRecorder.swift`). ScreenCaptureKit excludes by *application*, so every window
/// Slate owns — this panel included — is composited out of `screen.mov` while staying fully
/// visible on the physical display. You read it; the recording never sees it. As a second,
/// capture-method-independent guarantee we also set `sharingType = .none`, which excludes the
/// window from *any* macOS screen capture even on the filter's no-app fallback path.
@MainActor
final class TeleprompterController: ObservableObject {

    // MARK: Persisted settings (survive relaunch via UserDefaults)

    @Published var script: String { didSet { rebuildLine(); persist(script, "tp.script") } }
    @Published var speed: Double  { didSet { persist(speed, "tp.speed") } }      // points / second
    @Published var fontSize: Double { didSet { persist(fontSize, "tp.fontSize"); relayoutIfVisible() } }
    @Published var loop: Bool     { didSet { persist(loop, "tp.loop") } }

    // MARK: Live state the panel view observes

    @Published private(set) var isVisible = false
    @Published private(set) var isPlaying = false
    /// Points scrolled so far. The view positions the text's left edge at `panelWidth - offset`.
    @Published var offset: CGFloat = 0
    /// Flattened, single-line render of `script` (cached so we don't re-join every frame).
    @Published private(set) var line: String = ""
    /// Measured pixel width of the rendered line; the view reports it via a preference.
    @Published var contentWidth: CGFloat = 0

    /// The display the strip docks to (the one being recorded). Set by the Record panel.
    @Published var targetDisplayID: CGDirectDisplayID? { didSet { relayoutIfVisible() } }

    // MARK: Private

    private let defaults = UserDefaults.standard
    private var panel: NSPanel?
    private var panelWidth: CGFloat = 0
    private var timer: Timer?
    private var lastTick: Double = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {
        let d = UserDefaults.standard
        script   = d.string(forKey: "tp.script") ?? ""
        speed    = d.object(forKey: "tp.speed") as? Double ?? 120
        fontSize = d.object(forKey: "tp.fontSize") as? Double ?? 40
        loop     = d.object(forKey: "tp.loop") as? Bool ?? true
        rebuildLine()
    }

    // MARK: Show / hide

    func show() {
        ensurePanel()
        relayout()
        panel?.orderFrontRegardless()
        isVisible = true
        installHotkeys()
        startTimer()
    }

    func hide() {
        isPlaying = false
        stopTimer()
        removeHotkeys()
        panel?.orderOut(nil)
        isVisible = false
    }

    func toggleVisible() { isVisible ? hide() : show() }

    // MARK: Transport

    func play()   { guard !line.isEmpty else { return }; isPlaying = true }
    func pause()  { isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }
    func restart() { offset = 0 }

    // MARK: Window

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 96),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver                          // above normal + full-screen app content
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true                     // click-through to the app you're demoing
        p.sharingType = .none                           // never captured (belt-and-suspenders)
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: TickerView(controller: self))
        panel = p
    }

    /// Dock the strip to the top of the recorded display, full width, height scaled to the font.
    private func relayout() {
        guard let screen = screenForTarget() else { return }
        let vf = screen.visibleFrame                    // excludes the menu bar / Dock
        let height = max(60, fontSize * 1.7)
        panelWidth = vf.width
        panel?.setFrame(NSRect(x: vf.minX, y: vf.maxY - height, width: vf.width, height: height),
                        display: true)
    }

    private func relayoutIfVisible() { if isVisible { relayout() } }

    private func screenForTarget() -> NSScreen? {
        if let id = targetDisplayID,
           let s = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
           }) {
            return s
        }
        return NSScreen.main
    }

    // MARK: Animation loop (60 Hz; advances only while playing)

    private func startTimer() {
        stopTimer()
        lastTick = HostClock.now()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        let now = HostClock.now()
        let dt = now - lastTick
        lastTick = now
        guard isVisible, isPlaying, !line.isEmpty else { return }

        var next = offset + CGFloat(speed * dt)
        if contentWidth > 0 {
            let maxOffset = panelWidth + contentWidth          // fully crawled off the left edge
            if next > maxOffset {
                if loop { next = 0 }                           // wrap: re-enter from the right
                else { next = maxOffset; isPlaying = false }   // park at the end
            }
        }
        offset = next
    }

    // MARK: Script flattening

    /// Collapse the script (paragraphs, newlines, runs of whitespace) into one continuous
    /// line, with a middot between non-empty source lines so paragraph breaks read as a beat.
    private func rebuildLine() {
        let paras = script
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        line = paras.joined(separator: "   •   ")
        if line.isEmpty { isPlaying = false }
    }

    // MARK: Global / local hotkeys (global needs Accessibility — same grant as click tracking)

    private enum TPAction { case toggle, slower, faster, restart }

    private func installHotkeys() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isVisible, let a = self.match(e) else { return }
            self.run(a)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isVisible, let a = self.match(e) else { return e }
            self.run(a)
            return nil                                          // swallow so Slate doesn't beep
        }
    }

    private func removeHotkeys() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor  { NSEvent.removeMonitor(l); localMonitor = nil }
    }

    private func match(_ e: NSEvent) -> TPAction? {
        guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] else { return nil }
        switch e.keyCode {
        case 49:  return .toggle    // space
        case 123: return .slower    // ←
        case 124: return .faster    // →
        case 15:  return .restart   // r
        default:  return nil
        }
    }

    private func run(_ a: TPAction) {
        switch a {
        case .toggle:  toggle()
        case .slower:  speed = max(30, speed - 20)
        case .faster:  speed = min(400, speed + 20)
        case .restart: restart()
        }
    }

    // MARK: Persistence helper

    private func persist(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}
