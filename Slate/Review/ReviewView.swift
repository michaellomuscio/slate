import SwiftUI
import AVKit
import AVFoundation
import CoreMedia

/// In-app review of a take: screen + camera (PIP) + audio + live captions, with a toggle for
/// each so you can see exactly what's in the recording. Playback uses two `AVPlayerLayer`s
/// (screen and camera) locked to one shared timeline — NOT `AVMutableVideoComposition`, which
/// renders black on macOS 26. Each element can be turned on/off independently.
struct ReviewView: View {
    let bundle: TakeBundle

    @StateObject private var rp = ReviewPlayer()
    @State private var captions: CaptionsTrack? = nil
    @State private var loadError: String? = nil
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 12) {
            header
            videoArea
            controls
            toggles
            footer
        }
        .padding(16)
        .task(id: bundle.id) { await load() }
        .onDisappear { rp.teardown() }
    }

    // MARK: video

    private var screenAspect: CGFloat {
        let s = rp.screenSize
        return s.height > 0 ? s.width / s.height : 16.0 / 9.0
    }
    private var cameraAspect: CGFloat {
        let s = rp.cameraSize
        return s.height > 0 ? s.width / s.height : 16.0 / 9.0
    }

    private var videoArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if rp.ready, rp.showScreen, rp.hasScreenVideo {
                    PlayerLayerView(player: rp.screenPlayer)
                }

                if rp.ready, !rp.hasScreenVideo, !(rp.showCamera && rp.hasCamera) {
                    Text(rp.hasAudio ? "Audio only — no screen in this take"
                                     : "Nothing to show")
                        .foregroundStyle(.secondary)
                }

                if rp.ready, rp.showCaptions, let captions,
                   let line = captions.caption(at: rp.currentTime) {
                    VStack {
                        Spacer()
                        Text(line)
                            .font(.system(size: max(13, geo.size.width * 0.028), weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
                            .padding(.bottom, 14).padding(.horizontal, 18)
                    }
                }

                if isLoading {
                    ProgressView("Loading take…")
                        .controlSize(.large).padding(20)
                        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                } else if let err = loadError {
                    Text(err).foregroundStyle(.white).padding(12)
                        .background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                        .padding(20)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if rp.ready, rp.showCamera, rp.hasCamera {
                    let w = geo.size.width * 0.30
                    PlayerLayerView(player: rp.cameraPlayer)
                        .frame(width: w, height: w / cameraAspect)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.6), lineWidth: 2))
                        .shadow(radius: 6)
                        .padding(12)
                }
            }
        }
        .aspectRatio(screenAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: transport

    private var controls: some View {
        HStack(spacing: 12) {
            Button { rp.togglePlay() } label: {
                Image(systemName: rp.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 30, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!rp.ready)
            .keyboardShortcut(.space, modifiers: [])

            Text(timecode(rp.currentTime)).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)

            Slider(value: Binding(get: { rp.currentTime },
                                  set: { rp.scrub(to: $0) }),
                   in: 0...max(rp.duration, 0.1))
                .disabled(!rp.ready)

            Text(timecode(rp.duration)).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
        }
    }

    private var toggles: some View {
        HStack(spacing: 18) {
            Toggle("Screen",   isOn: $rp.showScreen).disabled(!rp.hasScreenVideo)
            Toggle("Camera",   isOn: $rp.showCamera).disabled(!rp.hasCamera)
            Toggle("Captions", isOn: $rp.showCaptions).disabled(captions == nil)
            Toggle("Audio",    isOn: $rp.audioOn).disabled(!rp.hasAudio)
            Spacer()
        }
        .toggleStyle(.switch)
        .font(.callout)
    }

    // MARK: header / footer

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.id).font(.title3).bold()
                if let d = bundle.createdAtDate {
                    Text(d.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([bundle.path])
            } label: { Label("Reveal in Finder", systemImage: "folder") }
                .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            badge("transcript", on: bundle.hasTranscript)
            badge("rendered", on: bundle.hasFinalRender)
            Spacer()
            Text(bundle.meta.display.name)
            Text("\(bundle.meta.display.pixelWidth)×\(bundle.meta.display.pixelHeight)")
            Text("\(bundle.meta.fps)fps")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func badge(_ label: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? .green : .secondary)
            Text(label)
        }
    }

    // MARK: load

    private func load() async {
        isLoading = true
        loadError = nil
        captions = CaptionsTrack.load(from: bundle)
        do {
            try await rp.load(bundle)
            try Task.checkCancellation()
            isLoading = false
        } catch is CancellationError {
            // superseded by another selection
        } catch {
            loadError = "Couldn't load this take: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func timecode(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Owns the two players (screen+audio, and camera) and keeps them locked to one shared
/// timeline. The screen player is the master clock; the camera player is drift-corrected to
/// it. Each visual/audio element is exposed as a toggle the view binds to.
@MainActor
final class ReviewPlayer: ObservableObject {
    let screenPlayer = AVPlayer()
    let cameraPlayer = AVPlayer()

    @Published var ready = false
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    @Published var hasScreenVideo = false
    @Published var hasCamera = false
    @Published var hasAudio = false
    @Published var screenSize: CGSize = .init(width: 16, height: 9)
    @Published var cameraSize: CGSize = .init(width: 16, height: 9)

    @Published var showScreen = true
    @Published var showCamera = true
    @Published var showCaptions = true
    @Published var audioOn = true { didSet { screenPlayer.isMuted = !audioOn } }

    private var timeObserver: Any?

    init() {
        cameraPlayer.isMuted = true       // camera track has no audio; belt + suspenders
    }

    func load(_ bundle: TakeBundle) async throws {
        teardown()
        let r = try await CompositionBuilder.build(bundle)
        try Task.checkCancellation()

        screenPlayer.replaceCurrentItem(with: AVPlayerItem(asset: r.master))
        if let cam = r.camera {
            cameraPlayer.replaceCurrentItem(with: AVPlayerItem(asset: cam))
        }
        hasScreenVideo = r.hasScreenVideo
        hasCamera = r.hasCamera
        hasAudio = r.hasAudio
        screenSize = r.screenSize
        cameraSize = r.cameraSize
        duration = r.duration.seconds.isFinite ? r.duration.seconds : 0
        screenPlayer.isMuted = !audioOn

        let interval = CMTime(value: 1, timescale: 20)   // 20 Hz: smooth scrubber + captions
        timeObserver = screenPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            let now = t.seconds
            self.currentTime = now
            if self.hasCamera, self.isPlaying {
                let cam = self.cameraPlayer.currentTime().seconds
                if abs(cam - now) > 0.12 {
                    self.cameraPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            if self.duration > 0, now >= self.duration - 0.05, self.isPlaying {
                self.pause()
            }
        }

        seekBoth(to: .zero)               // show first frames immediately (paused at 0)
        ready = true
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard ready else { return }
        if duration > 0, currentTime >= duration - 0.1 { scrub(to: 0) }
        screenPlayer.play()
        if hasCamera {
            cameraPlayer.seek(to: screenPlayer.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
            cameraPlayer.play()
        }
        isPlaying = true
    }

    func pause() {
        screenPlayer.pause()
        cameraPlayer.pause()
        isPlaying = false
    }

    func scrub(to s: Double) {
        let clamped = max(0, min(s, max(duration, 0)))
        seekBoth(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
    }

    private func seekBoth(to t: CMTime) {
        screenPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        if hasCamera { cameraPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) }
    }

    func teardown() {
        if let o = timeObserver { screenPlayer.removeTimeObserver(o); timeObserver = nil }
        screenPlayer.pause(); cameraPlayer.pause()
        screenPlayer.replaceCurrentItem(with: nil)
        cameraPlayer.replaceCurrentItem(with: nil)
        ready = false
        isPlaying = false
        currentTime = 0
    }
}

/// A thin `AVPlayerLayer`-backed view — used for both the full-screen video and the camera
/// PIP. We use `AVPlayerLayer` (not SwiftUI `VideoPlayer` or `AVPlayerView`) so we control
/// compositing and avoid the macOS 26 `VideoPlayer` crash / black-render issues entirely.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let v = PlayerLayerHostView()
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ v: PlayerLayerHostView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
