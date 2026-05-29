import SwiftUI
import AVKit
import AVFoundation

/// In-app preview of a take: screen + camera (PIP) + audio, time-locked, with the
/// transcript captions overlaid in real time. This is the "see what you actually
/// captured before you edit" pane.
struct ReviewView: View {
    let bundle: TakeBundle

    @State private var player: AVPlayer? = nil
    @State private var timeObserver: Any? = nil
    @State private var currentTime: Double = 0
    @State private var captions: CaptionsTrack? = nil
    @State private var loadError: String? = nil
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 14) {
            header

            ZStack(alignment: .bottom) {
                Rectangle().fill(.black)
                    .aspectRatio(aspectRatio, contentMode: .fit)

                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(aspectRatio, contentMode: .fit)
                }

                if isLoading {
                    ProgressView("Loading take…")
                        .controlSize(.large)
                        .padding(20)
                        .background(.black.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 8))
                } else if let err = loadError {
                    Text(err)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.red.opacity(0.7),
                                    in: RoundedRectangle(cornerRadius: 8))
                }

                if !isLoading, let captions, let line = captions.caption(at: currentTime) {
                    Text(line)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.72),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, 72)       // clear the AVPlayer chrome
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.08), value: line)
                }
            }
            .frame(maxWidth: .infinity)

            footer
        }
        .padding(16)
        .task(id: bundle.id) {
            await loadTake()
        }
        .onDisappear { teardown() }
    }

    // MARK: subviews

    private var aspectRatio: CGFloat {
        let w = max(1, CGFloat(bundle.meta.display.pixelWidth))
        let h = max(1, CGFloat(bundle.meta.display.pixelHeight))
        return w / h
    }

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
            badge("rendered",   on: bundle.hasFinalRender)
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

    // MARK: lifecycle

    private func loadTake() async {
        teardown()
        isLoading = true
        loadError = nil
        do {
            let (comp, vc, _) = try await CompositionBuilder.build(bundle)
            // The build is fully async; if the user picked another take while we awaited,
            // this task was cancelled — bail BEFORE writing any state, or a stale load would
            // clobber the new take's player and leak a periodic time observer.
            try Task.checkCancellation()

            let item = AVPlayerItem(asset: comp)
            if let vc { item.videoComposition = vc }
            let p = AVPlayer(playerItem: item)
            let caps = CaptionsTrack.load(from: bundle)
            let interval = CMTime(value: 1, timescale: 10)
            let obs = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
                self.currentTime = CMTimeGetSeconds(t)
            }
            guard !Task.isCancelled else {
                p.removeTimeObserver(obs)
                return
            }
            self.player = p
            self.captions = caps
            self.timeObserver = obs
            self.isLoading = false
        } catch is CancellationError {
            // Superseded by a newer selection — leave state to the load that replaced us.
        } catch {
            self.loadError = "Couldn't load this take: \(error.localizedDescription)"
            self.isLoading = false
        }
    }

    private func teardown() {
        if let p = player, let obs = timeObserver {
            p.removeTimeObserver(obs)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }
}
