import AppKit
import Foundation

/// Records the interaction track of a take: mouse-downs, a sampled cursor path, and
/// frontmost-app changes — each line a JSON object stamped on the global clock (`t`,
/// seconds since record start). Clicks carry both global AppKit points (`x`,`y`) and
/// display-local top-left pixels (`px`,`py`) mapped onto `screen.mov`.
///
/// Click capture needs Accessibility; if it's not granted the logger still runs and
/// records cursor moves + app switches, it just won't see clicks.
final class EventLogger {

    private var t0: Double = 0
    private var handle: FileHandle?
    private let ioQueue = DispatchQueue(label: "slate.events.io")

    private var globalMonitors: [Any] = []
    private var cursorTimer: Timer?
    private var lastCursor: CGPoint = .zero
    private var appObserver: NSObjectProtocol?

    // Geometry for mapping global points → display-local pixels.
    private var screenFrame: CGRect = .zero       // AppKit frame of the captured display
    private var scale: CGFloat = 2.0

    func start(t0: Double, fileURL: URL, screenFrame: CGRect, scale: CGFloat) {
        self.t0 = t0
        self.screenFrame = screenFrame
        self.scale = scale

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)

        // Initial app context.
        if let app = NSWorkspace.shared.frontmostApplication {
            logApp(app)
        }

        installMouseMonitors()
        installCursorTimer()
        installAppObserver()
    }

    func stop() {
        for m in globalMonitors { NSEvent.removeMonitor(m) }
        globalMonitors.removeAll()
        cursorTimer?.invalidate(); cursorTimer = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        ioQueue.sync {
            try? handle?.synchronize()
            try? handle?.close()
        }
        handle = nil
    }

    // MARK: Monitors

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.logClick(event)
        }) {
            globalMonitors.append(m)
        }
    }

    private func installCursorTimer() {
        // ~20 Hz, only emit when the cursor actually moved.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            if abs(p.x - self.lastCursor.x) + abs(p.y - self.lastCursor.y) >= 2 {
                self.lastCursor = p
                self.write(["t": self.stamp(), "type": "move", "x": p.x, "y": p.y])
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    private func installAppObserver() {
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.logApp(app)
        }
    }

    // MARK: Emit

    private func logClick(_ event: NSEvent) {
        let p = NSEvent.mouseLocation
        let button: String
        switch event.type {
        case .rightMouseDown: button = "right"
        case .otherMouseDown: button = "other"
        default:              button = "left"
        }
        // Map global AppKit point → display-local top-left pixels.
        let localX = p.x - screenFrame.minX
        let localYFromTop = screenFrame.maxY - p.y
        let px = localX * scale
        let py = localYFromTop * scale
        write(["t": stamp(), "type": "click", "button": button,
               "x": p.x, "y": p.y, "px": px, "py": py])
    }

    private func logApp(_ app: NSRunningApplication) {
        write(["t": stamp(), "type": "app",
               "bundleId": app.bundleIdentifier ?? "",
               "name": app.localizedName ?? ""])
    }

    private func stamp() -> Double { HostClock.now() - t0 }

    private func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        ioQueue.async { [weak self] in
            self?.handle?.write(data)
            self?.handle?.write(Data("\n".utf8))
        }
    }
}
