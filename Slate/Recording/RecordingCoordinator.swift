import SwiftUI
import ScreenCaptureKit
import AVFoundation

/// Owns the three recorders, the device/permission state the UI binds to, and the
/// assembly of the take bundle (folder + `meta.json`). This is the only object the views
/// talk to.
@MainActor
final class RecordingCoordinator: ObservableObject {

    // Devices / selection
    @Published var displays: [SCDisplay] = []
    @Published var cameras: [AVCaptureDevice] = []
    @Published var mics: [AVCaptureDevice] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedCameraID: String?      // nil = no camera track
    @Published var selectedMicID: String?         // nil = no audio track
    @Published var fps: Int = 60

    // Permissions
    @Published var screenPerm = false
    @Published var camPerm: PermissionState = .notDetermined
    @Published var micPerm: PermissionState = .notDetermined
    @Published var axPerm = false

    // Recording state
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var lastBundleURL: URL?
    @Published var status = ""

    private let screen = ScreenRecorder()
    private var camAudio: CameraAudioRecorder?
    private let events = EventLogger()

    private var t0: Double = 0
    private var bundleURL: URL?
    private var displayInfo: DisplayInfo?
    private var createdAt = ""
    private var elapsedTimer: Timer?

    var canRecord: Bool { !isRecording && selectedDisplayID != nil && screenPerm }

    // MARK: Discovery / permissions

    func refreshPermissions() {
        screenPerm = Permissions.screenRecording()
        camPerm = Permissions.camera()
        micPerm = Permissions.microphone()
        axPerm = Permissions.accessibility()
    }

    func refreshDevices() async {
        refreshPermissions()

        if let content = try? await SCShareableContent.current {
            displays = content.displays
            if selectedDisplayID == nil {
                selectedDisplayID = displays.first(where: { $0.displayID == CGMainDisplayID() })?.displayID
                    ?? displays.first?.displayID
            }
        }

        let camDisc = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        cameras = camDisc.devices
        if selectedCameraID == nil { selectedCameraID = cameras.first?.uniqueID }

        let micDisc = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified)
        mics = micDisc.devices
        if selectedMicID == nil { selectedMicID = mics.first?.uniqueID }
    }

    func requestScreen() { Permissions.requestScreenRecording(); refreshPermissions() }
    func requestCamera() async { _ = await Permissions.requestCamera(); refreshPermissions() }
    func requestMic() async { _ = await Permissions.requestMicrophone(); refreshPermissions() }
    func requestAccessibility() { Permissions.requestAccessibility() }

    // MARK: Record

    func start() async {
        guard canRecord,
              let displayID = selectedDisplayID,
              let display = displays.first(where: { $0.displayID == displayID }) else { return }

        // Bundle folder
        let stamp = Self.folderFormatter.string(from: Date())
        guard let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            status = "Could not locate Movies folder."; return
        }
        let bundle = base.appendingPathComponent("Slate/take-\(stamp)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true) }
        catch { status = "Could not create take folder: \(error.localizedDescription)"; return }
        bundleURL = bundle

        // Geometry
        let info = displayInfo(for: display)
        displayInfo = info
        let screenFrame = nsScreen(for: displayID)?.frame
            ?? CGRect(x: info.globalFrame.x, y: info.globalFrame.y, width: info.globalFrame.w, height: info.globalFrame.h)
        let scale = CGFloat(info.backingScaleFactor)

        // Own app, to exclude its window from the capture
        let ownApp = try? await SCShareableContent.current.applications
            .first(where: { $0.bundleIdentifier == Bundle.main.bundleIdentifier })

        let camera = cameras.first(where: { $0.uniqueID == selectedCameraID })
        let mic = mics.first(where: { $0.uniqueID == selectedMicID })

        createdAt = ISO8601DateFormatter.utc.string(from: Date())
        t0 = HostClock.now()

        // Start producers — events + camera/mic immediately, screen awaited.
        events.start(t0: t0, fileURL: bundle.appendingPathComponent("events.jsonl"),
                     screenFrame: screenFrame, scale: scale)

        if camera != nil || mic != nil {
            let ca = CameraAudioRecorder()
            ca.configure(camera: camera, mic: mic)
            ca.start(t0: t0,
                     cameraURL: bundle.appendingPathComponent("camera.mov"),
                     audioURL: bundle.appendingPathComponent("audio.wav"))
            camAudio = ca
        }

        do {
            try await screen.start(display: display,
                                   pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight,
                                   fps: fps, excluding: ownApp,
                                   outputURL: bundle.appendingPathComponent("screen.mov"),
                                   t0: t0)
        } catch {
            status = "Screen capture failed: \(error.localizedDescription)"
            events.stop()
            await camAudio?.stop(); camAudio = nil
            return
        }

        isRecording = true
        status = "Recording…"
        startElapsedTimer()
    }

    func stop() async {
        guard isRecording else { return }
        stopElapsedTimer()
        await screen.stop()
        await camAudio?.stop()
        events.stop()
        writeMeta()
        isRecording = false
        lastBundleURL = bundleURL
        status = "Saved take to \(bundleURL?.lastPathComponent ?? "?")"
        camAudio = nil
    }

    // MARK: meta.json

    private func writeMeta() {
        guard let bundle = bundleURL, let info = displayInfo else { return }
        var streams: [String: StreamInfo] = [
            "screen": StreamInfo(file: "screen.mov", startOffset: screen.startOffset ?? 0,
                                 width: screen.pixelWidth, height: screen.pixelHeight)
        ]
        if let ca = camAudio {
            if ca.recordsVideo, let off = ca.cameraStartOffset {
                streams["camera"] = StreamInfo(file: "camera.mov", startOffset: off,
                                               width: ca.cameraSize.map { Int($0.width) },
                                               height: ca.cameraSize.map { Int($0.height) })
            }
            if ca.recordsAudio, let off = ca.audioStartOffset {
                streams["audio"] = StreamInfo(file: "audio.wav", startOffset: off,
                                              sampleRate: ca.audioSampleRate, channels: ca.audioChannels)
            }
        }
        let meta = TakeMeta(appVersion: appVersion, createdAt: createdAt, fps: fps,
                            display: info, streams: streams)
        do { try meta.write(to: bundle.appendingPathComponent("meta.json")) }
        catch { NSLog("Slate: meta write failed: \(error.localizedDescription)") }
    }

    // MARK: Helpers

    private func startElapsedTimer() {
        elapsed = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.elapsed = HostClock.now() - self.t0 }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() { elapsedTimer?.invalidate(); elapsedTimer = nil }

    private func nsScreen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    private func displayInfo(for d: SCDisplay) -> DisplayInfo {
        let screen = nsScreen(for: d.displayID)
        let scale = screen?.backingScaleFactor ?? 2.0
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: CGFloat(d.width), height: CGFloat(d.height))
        return DisplayInfo(
            id: d.displayID,
            name: screen?.localizedName ?? "Display \(d.displayID)",
            pixelWidth: Int(Double(d.width) * Double(scale)),
            pixelHeight: Int(Double(d.height) * Double(scale)),
            pointWidth: d.width,
            pointHeight: d.height,
            backingScaleFactor: Double(scale),
            globalFrame: Rect(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height))
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
}
