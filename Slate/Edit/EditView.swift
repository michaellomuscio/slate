import SwiftUI

/// Top-level **Edit** tab: pick a take (defaults to the newest), then trim it, cut out
/// dead air, preview the result live, and render. Reuses `ReviewPlayer` (two AVPlayerLayers
/// on a shared timeline — solid on macOS 26) for playback, and writes the `edit.json` EDL the
/// render pipeline executes.
struct EditView: View {
    @State private var bundles: [TakeBundle] = []
    @State private var selectedID: TakeBundle.ID? = nil

    private var selected: TakeBundle? { bundles.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "scissors").foregroundStyle(Color.accentColor)
                Text("Edit").font(.headline)
                if bundles.isEmpty {
                    Text("— no takes yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $selectedID) {
                        ForEach(bundles) { b in Text(b.id).tag(Optional(b.id)) }
                    }
                    .labelsHidden().frame(maxWidth: 320)
                }
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan ~/Movies/Slate")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Divider()

            if let b = selected {
                EditPane(bundle: b).id(b.id)
            } else {
                ContentUnavailableView("Pick a take to edit", systemImage: "scissors",
                    description: Text("Record something, then trim it, cut out the dead air, and render."))
            }
        }
        .task { reload() }
    }

    private func reload() {
        bundles = TakeBundle.loadAll()
        if selectedID == nil || !bundles.contains(where: { $0.id == selectedID }) {
            selectedID = bundles.first?.id
        }
    }
}

/// The editor for one take.
struct EditPane: View {
    let bundle: TakeBundle

    @StateObject private var rp = ReviewPlayer()
    @StateObject private var decision = EditDecision()

    @State private var isLoading = true
    @State private var loadError: String? = nil
    @State private var pendingCutStart: Double? = nil      // first click of a two-click cut
    @State private var previewSkip = true                  // playback skips cut/trim spans

    @State private var rendering = false
    @State private var renderProgress: Double = 0
    @State private var statusMsg: String? = nil
    @State private var statusIsError = false

    private var screenAspect: CGFloat {
        rp.screenSize.height > 0 ? rp.screenSize.width / rp.screenSize.height : 16.0 / 9.0
    }

    var body: some View {
        VStack(spacing: 12) {
            videoArea
            transport
            TimelineBar(rp: rp, decision: decision, pendingCutStart: pendingCutStart)
                .disabled(!rp.ready)
            editControls
            saveBar
        }
        .padding(16)
        .task(id: bundle.id) { await load() }
        .onDisappear { rp.teardown() }
        .onChange(of: rp.currentTime) { _, t in
            guard previewSkip, rp.isPlaying else { return }
            if let j = decision.skipTarget(at: t) {
                if j >= decision.duration - 0.01 { rp.pause(); rp.scrub(to: decision.outPoint) }
                else { rp.scrub(to: j) }
            }
        }
    }

    // MARK: video

    private var videoArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if rp.ready, rp.hasScreenVideo {
                    PlayerLayerView(player: rp.screenPlayer)
                } else if rp.ready {
                    Text("This take has no screen video to edit.").foregroundStyle(.secondary)
                }
                if isLoading {
                    ProgressView("Loading take…").controlSize(.large).padding(20)
                        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                } else if let err = loadError {
                    Text(err).foregroundStyle(.white).padding(12)
                        .background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 8)).padding(20)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if rp.ready, rp.hasCamera {
                    let w = geo.size.width * 0.24
                    PlayerLayerView(player: rp.cameraPlayer)
                        .frame(width: w, height: w * (rp.cameraSize.height / max(rp.cameraSize.width, 1)))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
                        .padding(10)
                }
            }
        }
        .aspectRatio(screenAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button { rp.togglePlay() } label: {
                Image(systemName: rp.isPlaying ? "pause.fill" : "play.fill").frame(width: 30, height: 22)
            }
            .buttonStyle(.borderedProminent).disabled(!rp.ready)
            .keyboardShortcut(.space, modifiers: [])

            Text(tc(rp.currentTime)).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            Slider(value: Binding(get: { rp.currentTime }, set: { rp.scrub(to: $0) }),
                   in: 0...max(rp.duration, 0.1)).disabled(!rp.ready)
            Text(tc(rp.duration)).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 48, alignment: .leading)

            Toggle("Preview cuts", isOn: $previewSkip).toggleStyle(.switch)
                .help("When on, playback skips trimmed/cut spans so you see the final edit.")
        }
    }

    // MARK: edit controls

    private var editControls: some View {
        HStack(spacing: 10) {
            Button { decision.setIn(rp.currentTime) } label: { Label("Set In", systemImage: "arrow.right.to.line") }
                .disabled(!rp.ready)
            Button { decision.setOut(rp.currentTime) } label: { Label("Set Out", systemImage: "arrow.left.to.line") }
                .disabled(!rp.ready)

            Divider().frame(height: 18)

            if pendingCutStart == nil {
                Button { pendingCutStart = rp.currentTime } label: { Label("Start cut", systemImage: "scissors") }
                    .disabled(!rp.ready)
            } else {
                Button {
                    decision.addCut(from: pendingCutStart!, to: rp.currentTime)
                    pendingCutStart = nil
                } label: { Label("End cut here", systemImage: "scissors.badge.ellipsis") }
                    .buttonStyle(.borderedProminent).tint(.red)
                Button("Cancel") { pendingCutStart = nil }.controlSize(.small)
            }

            Button { decision.removeCut(at: rp.currentTime) } label: { Label("Delete cut", systemImage: "trash") }
                .disabled(!isInsideCut)

            Spacer()

            Button("Reset") { decision.reset(); pendingCutStart = nil }
                .controlSize(.small).disabled(!decision.isEdited && pendingCutStart == nil)
        }
        .font(.callout)
    }

    private var isInsideCut: Bool {
        let t = rp.currentTime
        return decision.cuts.contains { t >= $0.start && t <= $0.end }
    }

    // MARK: save / render

    private var saveBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Final length: \(tc(decision.keptDuration)) of \(tc(decision.duration))")
                    .font(.callout).monospacedDigit()
                Text("\(decision.cuts.count) cut\(decision.cuts.count == 1 ? "" : "s")"
                     + (decision.isEdited ? "" : " · no edits yet"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button { save() } label: { Label("Save edit", systemImage: "square.and.arrow.down") }
                .disabled(!rp.ready || rendering)

            if rendering {
                ProgressView(value: renderProgress).frame(width: 90)
            }
            Button { renderNow() } label: {
                if rendering { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                else { Label("Render", systemImage: "film") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!rp.ready || rendering)
            .help("Render the trimmed take to final.mp4 (screen + your camera) — runs entirely in Slate, no setup.")
        }
        .overlay(alignment: .bottomLeading) {
            if let m = statusMsg {
                Text(m).font(.caption).foregroundStyle(statusIsError ? .red : .secondary)
                    .lineLimit(2).offset(y: 26)
            }
        }
    }

    // MARK: actions

    private func load() async {
        isLoading = true; loadError = nil
        do {
            try await rp.load(bundle)
            try Task.checkCancellation()
            decision.load(duration: rp.duration)
            isLoading = false
        } catch is CancellationError {
        } catch {
            loadError = "Couldn't load this take: \(error.localizedDescription)"; isLoading = false
        }
    }

    private func save() {
        do {
            try decision.writeEditJSON(to: bundle, hasCamera: rp.hasCamera)
            statusIsError = false
            statusMsg = "Saved edit.json — \(decision.timelineOps().count) segments."
        } catch {
            statusIsError = true; statusMsg = "Save failed: \(error.localizedDescription)"
        }
    }

    private func renderNow() {
        do {
            try decision.writeEditJSON(to: bundle, hasCamera: rp.hasCamera)
        } catch {
            statusIsError = true; statusMsg = "Save failed: \(error.localizedDescription)"; return
        }
        rendering = true; renderProgress = 0; statusIsError = false; statusMsg = "Rendering final.mp4…"
        let b = bundle
        let kept = decision.keptIntervals()
        let length = tc(decision.keptDuration)
        Task {
            do {
                let url = try await NativeRenderer.render(bundle: b, kept: kept,
                                                          progress: { p in Task { @MainActor in renderProgress = p } })
                await MainActor.run {
                    rendering = false; statusIsError = false
                    statusMsg = "Rendered final.mp4 (\(length))."
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run {
                    rendering = false; statusIsError = true
                    statusMsg = "Render failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func tc(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The scrubbable timeline: kept content in brand purple, removed spans (trim + cuts) in red,
/// the pending cut-start in yellow, and the white playhead. Drag anywhere to seek.
struct TimelineBar: View {
    @ObservedObject var rp: ReviewPlayer
    @ObservedObject var decision: EditDecision
    var pendingCutStart: Double?

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let dur = max(decision.duration, 0.001)
            func x(_ t: Double) -> CGFloat { CGFloat(t / dur) * w }

            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 5),
                     with: .color(Color.accentColor.opacity(0.40)))
            for (s, e) in decision.removedIntervals() {
                ctx.fill(Path(CGRect(x: x(s), y: 0, width: max(1, x(e) - x(s)), height: h)),
                         with: .color(.red.opacity(0.55)))
            }
            if let cs = pendingCutStart {
                ctx.fill(Path(CGRect(x: x(cs) - 1, y: 0, width: 2, height: h)), with: .color(.yellow))
            }
            ctx.fill(Path(CGRect(x: x(rp.currentTime) - 1, y: 0, width: 2, height: h)), with: .color(.white))
        }
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.25)))
        .overlay(
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let dur = max(decision.duration, 0.001)
                        let t = max(0, min(dur, Double(v.location.x / geo.size.width) * dur))
                        rp.scrub(to: t)
                    })
            }
        )
    }
}
