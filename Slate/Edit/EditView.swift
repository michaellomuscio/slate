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
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    videoArea
                    transport
                    TimelineBar(rp: rp, decision: decision, pendingCutStart: pendingCutStart)
                        .disabled(!rp.ready)
                    if !decision.redactions.isEmpty {
                        GroupBox {
                            VStack(spacing: 6) {
                                ForEach(decision.redactions) { shape in
                                    if let b = decision.binding(for: shape.id) {
                                        RedactionRow(rp: rp, decision: decision, shape: b).id(shape.id)
                                    }
                                }
                            }
                            .padding(4)
                        } label: { Label("Redactions", systemImage: "rectangle.dashed") }
                    }
                    editControls
                }
                .padding(16)
            }
            Divider()
            saveBar
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.bar)
        }
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
                    RedactionOverlay(decision: decision, playhead: rp.currentTime,
                                     canvas: geo.size, editable: !rp.isPlaying)
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

            Divider().frame(height: 18)

            Button { decision.addRedaction(atPlayhead: rp.currentTime) } label: {
                Label("Redact", systemImage: "rectangle.dashed")
            }
            .disabled(!rp.ready)

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
                Text(summaryLine)
                    .font(.caption).foregroundStyle(.secondary)
                if let m = statusMsg {
                    Text(m).font(.caption).foregroundStyle(statusIsError ? .red : .secondary).lineLimit(2)
                }
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
    }

    private var summaryLine: String {
        var parts: [String] = []
        if decision.cuts.count > 0 { parts.append("\(decision.cuts.count) cut\(decision.cuts.count == 1 ? "" : "s")") }
        if decision.redactions.count > 0 { parts.append("\(decision.redactions.count) redaction\(decision.redactions.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "no edits yet" : parts.joined(separator: " · ")
    }

    // MARK: actions

    private func load() async {
        isLoading = true; loadError = nil
        do {
            try await rp.load(bundle)
            try Task.checkCancellation()
            decision.load(duration: rp.duration)
            decision.restore(from: bundle)     // rehydrate prior trims/cuts/redactions
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
        let reds = decision.renderRedactions()
        let length = tc(decision.keptDuration)
        Task {
            do {
                let url = try await NativeRenderer.render(bundle: b, kept: kept, redactions: reds,
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

// MARK: - Redaction preview overlay

/// Draws every redaction that is active at the current playhead (or selected) over the screen
/// preview. Each box is interactive (move / resize / select) while not playing — mirroring
/// `ComposeView`'s `.allowsHitTesting(!isPlaying)` approach. Honest editor approximation: real
/// blur is baked in by the renderer; here a blurred box shows frosted material + hatching + a badge.
struct RedactionOverlay: View {
    @ObservedObject var decision: EditDecision
    let playhead: Double
    let canvas: CGSize
    let editable: Bool

    var body: some View {
        ZStack {
            ForEach(decision.redactions) { shape in
                let active = shape.isActive(at: playhead)
                let selected = decision.selectedRedactionID == shape.id
                if active || selected {
                    RedactionBox(binding: decision.binding(for: shape.id) ?? .constant(shape),
                                 canvas: canvas, selected: selected, dimmed: !active,
                                 editable: editable,
                                 onSelect: { decision.selectedRedactionID = shape.id })
                }
            }
        }
        .allowsHitTesting(editable)   // no editing while playing, like ComposeView
    }
}

/// A single draggable / resizable redaction rectangle. Origin clamps to `1 - size`; size clamps to
/// `[0.03, 1 - origin]`. Writes through the `RedactionShape` binding. Solid → color fill; blur →
/// frosted material + hatch + "BLUR" badge. Selected → accent stroke + a bottom-right resize handle.
struct RedactionBox: View {
    @Binding var binding: RedactionShape
    let canvas: CGSize
    let selected: Bool
    let dimmed: Bool
    let editable: Bool
    let onSelect: () -> Void

    // transient gesture anchors (fractional)
    @State private var dragStartOrigin: CGPoint? = nil
    @State private var resizeStartSize: CGSize? = nil

    private var pxRect: CGRect {
        CGRect(x: binding.rect.minX * canvas.width, y: binding.rect.minY * canvas.height,
               width: binding.rect.width * canvas.width, height: binding.rect.height * canvas.height)
    }

    var body: some View {
        let r = pxRect
        ZStack(alignment: .topLeading) {
            fill
                .frame(width: max(1, r.width), height: max(1, r.height))
                .overlay(alignment: .topLeading) {
                    if binding.blur {
                        Text("BLUR")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                            .padding(3)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.6),
                                      lineWidth: selected ? 2.5 : 1)
                )
                .opacity(dimmed ? 0.45 : 1)
                .contentShape(Rectangle())
                .gesture(moveGesture)
                .onTapGesture { onSelect() }

            if selected && editable {
                Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .offset(x: max(1, r.width) - 9, y: max(1, r.height) - 9)
                    .gesture(resizeGesture)
                    .help("Drag to resize")
            }
        }
        .frame(width: max(1, r.width), height: max(1, r.height), alignment: .topLeading)
        .position(x: r.midX, y: r.midY)
    }

    @ViewBuilder
    private var fill: some View {
        if binding.blur {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                HatchPattern()
            }
        } else {
            Rectangle()
                .fill(Color(cgColor: CGColor.fromHex(binding.colorHex)
                            ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)))
        }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                onSelect()
                let start = dragStartOrigin ?? CGPoint(x: binding.x, y: binding.y)
                if dragStartOrigin == nil { dragStartOrigin = start }
                let nx = start.x + Double(v.translation.width) / Double(max(canvas.width, 1))
                let ny = start.y + Double(v.translation.height) / Double(max(canvas.height, 1))
                binding.x = min(max(0, nx), max(0, 1 - binding.w))
                binding.y = min(max(0, ny), max(0, 1 - binding.h))
            }
            .onEnded { _ in dragStartOrigin = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                onSelect()
                let start = resizeStartSize ?? CGSize(width: binding.w, height: binding.h)
                if resizeStartSize == nil { resizeStartSize = start }
                let nw = start.width + Double(v.translation.width) / Double(max(canvas.width, 1))
                let nh = start.height + Double(v.translation.height) / Double(max(canvas.height, 1))
                binding.w = min(max(0.03, nw), max(0.03, 1 - binding.x))
                binding.h = min(max(0.03, nh), max(0.03, 1 - binding.y))
            }
            .onEnded { _ in resizeStartSize = nil }
    }
}

/// Diagonal-stripe fill that marks a blur box in the editor. Non-interactive (pointer falls
/// through to the box's own gestures).
struct HatchPattern: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                let step: CGFloat = 10
                var x = -h
                while x < w {
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x + h, y: h))
                    x += step
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Per-redaction timeline row

/// One row per redaction: a mini scrubber over `[0, duration]` (same `x(t)=t/dur*w` mapping as
/// `TimelineBar`, so its `[start,end]` segment lines up vertically), Set Start / Set End buttons,
/// a Blur|Solid picker, color swatches (solid only), and a trash button. Tapping the row selects it.
struct RedactionRow: View {
    @ObservedObject var rp: ReviewPlayer
    @ObservedObject var decision: EditDecision
    @Binding var shape: RedactionShape

    // transient drag classification for the segment
    private enum Edge { case start, end, move }
    @State private var dragEdge: Edge? = nil
    @State private var dragAnchorStart: Double? = nil
    @State private var dragAnchorEnd: Double? = nil

    private var selected: Bool { decision.selectedRedactionID == shape.id }

    var body: some View {
        VStack(spacing: 6) {
            scrubber
                .frame(height: 26)

            HStack(spacing: 8) {
                Button { decision.setRedactionStart(shape.id, to: rp.currentTime) } label: {
                    Label("Set Start", systemImage: "arrow.right.to.line")
                }
                .controlSize(.small).disabled(!rp.ready)
                Button { decision.setRedactionEnd(shape.id, to: rp.currentTime) } label: {
                    Label("Set End", systemImage: "arrow.left.to.line")
                }
                .controlSize(.small).disabled(!rp.ready)

                Picker("", selection: $shape.blur) {
                    Text("Blur").tag(true)
                    Text("Solid").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)

                if !shape.blur {
                    ForEach(ComposeView.swatches, id: \.1) { name, hex in
                        swatch(name: name, hex: hex)
                    }
                }

                Spacer()

                Text("\(tc(shape.start))–\(tc(shape.end))")
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)

                Button { decision.removeRedaction(shape.id) } label: { Image(systemName: "trash") }
                    .controlSize(.small).buttonStyle(.borderless)
            }
            .font(.callout)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { decision.selectedRedactionID = shape.id }
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let dur = max(decision.duration, 0.001)
            let x: (Double) -> CGFloat = { CGFloat($0 / dur) * w }
            let sx = x(shape.start), ex = x(shape.end)

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let h = size.height
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 4),
                             with: .color(.black.opacity(0.25)))
                    let seg = CGRect(x: sx, y: 0, width: max(2, ex - sx), height: h)
                    ctx.fill(Path(roundedRect: seg, cornerRadius: 4),
                             with: .color(shape.blur ? Color.teal.opacity(0.7)
                                          : Color(cgColor: CGColor.fromHex(shape.colorHex)
                                                  ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)).opacity(0.7)))
                    ctx.fill(Path(CGRect(x: x(rp.currentTime) - 1, y: 0, width: 2, height: h)),
                             with: .color(.white))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        decision.selectedRedactionID = shape.id
                        let loc = Double(v.location.x)
                        if dragEdge == nil {
                            dragAnchorStart = shape.start
                            dragAnchorEnd = shape.end
                            if abs(loc - Double(sx)) <= 8 { dragEdge = .start }
                            else if abs(loc - Double(ex)) <= 8 { dragEdge = .end }
                            else { dragEdge = .move }
                        }
                        let t = max(0, min(dur, (loc / Double(max(w, 1))) * dur))
                        switch dragEdge {
                        case .start:
                            decision.setRedactionStart(shape.id, to: t)
                        case .end:
                            decision.setRedactionEnd(shape.id, to: t)
                        case .move, .none:
                            let span = (dragAnchorEnd ?? shape.end) - (dragAnchorStart ?? shape.start)
                            let dt = Double(v.translation.width) / Double(max(w, 1)) * dur
                            var ns = (dragAnchorStart ?? shape.start) + dt
                            ns = min(max(0, ns), max(0, dur - span))
                            shape.start = ns
                            shape.end = min(dur, ns + span)
                        }
                    }
                    .onEnded { _ in dragEdge = nil; dragAnchorStart = nil; dragAnchorEnd = nil }
            )
        }
    }

    private func swatch(name: String, hex: String) -> some View {
        let isSel = shape.colorHex.uppercased() == hex.uppercased()
        return Button {
            shape.colorHex = hex
        } label: {
            Circle()
                .fill(Color(cgColor: CGColor.fromHex(hex) ?? CGColor(gray: 0.5, alpha: 1)))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(isSel ? Color.accentColor : Color.secondary.opacity(0.4),
                                               lineWidth: isSel ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private func tc(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
