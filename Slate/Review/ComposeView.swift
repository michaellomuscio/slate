import SwiftUI
import AVFoundation

/// Loom-style compose pane: position your "head" (the camera) over the screen recording — drag to
/// move, drag the corner handle to resize, pick a shape, toggle border / shadow / mirror — with a
/// live WYSIWYG preview, then export a single shareable `walkthrough.mp4`.
///
/// It reuses `ReviewPlayer` (the two players locked to one shared timeline, NOT
/// `AVMutableVideoComposition`) so playback is rock-solid on macOS 26. The on-screen bubble is
/// rendered with the SAME geometry the native exporter uses (`WalkthroughLayout.bubbleRect` / `cornerRadius`
/// / `borderWidthPx`), so what you place is what you get.
struct ComposeView: View {
    let bundle: TakeBundle

    @StateObject private var rp = ReviewPlayer()
    @State private var layout = WalkthroughLayout.default
    @State private var loaded = false

    // transient gesture anchors (fractional)
    @State private var dragStartCenter: CGPoint? = nil
    @State private var resizeStartWidth: Double? = nil

    // export
    @State private var exporting = false
    @State private var progress: Double = 0
    @State private var exportError: String? = nil

    // debounced persistence of layout.json
    @State private var saveTask: Task<Void, Never>? = nil

    private var cameraAspect: CGFloat {
        rp.cameraSize.height > 0 ? rp.cameraSize.width / rp.cameraSize.height : 16.0 / 9.0
    }
    private var screenAspect: CGFloat {
        rp.screenSize.height > 0 ? rp.screenSize.width / rp.screenSize.height : 16.0 / 9.0
    }
    private var canExport: Bool { rp.ready && rp.hasScreenVideo && rp.hasCamera && !exporting }

    var body: some View {
        VStack(spacing: 12) {
            header
            canvas
            transport
            controls
            exportBar
        }
        .padding(16)
        .task(id: bundle.id) { await load() }
        .onDisappear { rp.teardown(); saveTask?.cancel() }
        .onChange(of: layout) { _, _ in scheduleSave() }
    }

    // MARK: canvas (live preview + interactive bubble)

    private var canvas: some View {
        GeometryReader { geo in
            let cv = geo.size
            ZStack {
                Color.black

                if rp.ready, rp.hasScreenVideo {
                    PlayerLayerView(player: rp.screenPlayer)
                        .frame(width: cv.width, height: cv.height)
                }

                if rp.ready, rp.hasCamera, layout.cameraVisible {
                    bubble(canvas: cv)
                    if !rp.isPlaying { resizeHandle(canvas: cv) }
                }

                if rp.ready, !rp.hasCamera {
                    Text("This take has no camera track — nothing to position.")
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }

                if !loaded {
                    ProgressView("Loading take…")
                        .controlSize(.large).padding(20)
                        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .aspectRatio(screenAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func bubble(canvas cv: CGSize) -> some View {
        let rect = layout.bubbleRect(canvas: cv, cameraAspect: cameraAspect)
        let cr = layout.cornerRadius(for: rect.size)
        let lw = layout.borderWidthPx(canvas: cv)
        let shadowR = layout.shadow ? max(4, rect.width * 0.05) : 0
        return PlayerLayerView(player: rp.cameraPlayer, videoGravity: .resizeAspectFill)
            .frame(width: rect.width, height: rect.height)
            .scaleEffect(x: layout.mirror ? -1 : 1, y: 1)
            .clipShape(clipShape(cr: cr))
            .overlay(borderOverlay(cr: cr, lw: lw))
            .shadow(color: .black.opacity(layout.shadow ? 0.5 : 0),
                    radius: shadowR, x: 0, y: layout.shadow ? max(2, rect.width * 0.02) : 0)
            .position(x: rect.midX, y: rect.midY)
            .gesture(dragGesture(canvas: cv))
    }

    private func resizeHandle(canvas cv: CGSize) -> some View {
        let rect = layout.bubbleRect(canvas: cv, cameraAspect: cameraAspect)
        return Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
            .font(.system(size: 18))
            .foregroundStyle(.white)
            .background(Circle().fill(.black.opacity(0.55)))
            .position(x: rect.maxX, y: rect.maxY)
            .gesture(resizeGesture(canvas: cv))
            .help("Drag to resize")
    }

    // MARK: gestures

    private func dragGesture(canvas cv: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let start = dragStartCenter ?? CGPoint(x: layout.centerX, y: layout.centerY)
                if dragStartCenter == nil { dragStartCenter = start }
                let size = layout.bubbleSize(canvas: cv, cameraAspect: cameraAspect)
                let halfW = (size.width / cv.width) / 2
                let halfH = (size.height / cv.height) / 2
                let nx = start.x + v.translation.width / cv.width
                let ny = start.y + v.translation.height / cv.height
                layout.centerX = min(max(halfW, nx), 1 - halfW)
                layout.centerY = min(max(halfH, ny), 1 - halfH)
            }
            .onEnded { _ in dragStartCenter = nil }
    }

    private func resizeGesture(canvas cv: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let start = resizeStartWidth ?? layout.widthFrac
                if resizeStartWidth == nil { resizeStartWidth = start }
                // handle sits half a width from center, so a delta d at the handle changes width by 2d
                let delta = (v.translation.width / cv.width) * 2
                layout.widthFrac = min(max(0.08, start + delta), 0.6)
            }
            .onEnded { _ in resizeStartWidth = nil }
    }

    // MARK: shape helpers (preview geometry mirrors the exporter)

    private func clipShape(cr: CGFloat) -> AnyShape {
        switch layout.shape {
        case .circle:                     return AnyShape(Circle())
        case .roundedSquare, .roundedRect: return AnyShape(RoundedRectangle(cornerRadius: cr, style: .continuous))
        case .rectangle:                  return AnyShape(Rectangle())
        }
    }

    @ViewBuilder
    private func borderOverlay(cr: CGFloat, lw: CGFloat) -> some View {
        if layout.border, lw > 0 {
            let c = Color(cgColor: CGColor.fromHex(layout.borderColorHex)
                          ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            switch layout.shape {
            case .circle:                      Circle().strokeBorder(c, lineWidth: lw)
            case .roundedSquare, .roundedRect: RoundedRectangle(cornerRadius: cr, style: .continuous).strokeBorder(c, lineWidth: lw)
            case .rectangle:                   Rectangle().strokeBorder(c, lineWidth: lw)
            }
        }
    }

    // MARK: controls

    private var controls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Shape", selection: $layout.shape) {
                    ForEach(WalkthroughLayout.Shape.allCases) { s in
                        Label(s.label, systemImage: s.symbol).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                sliderRow("Size", value: $layout.widthFrac, in: 0.08...0.6)

                if layout.shape == .roundedSquare || layout.shape == .roundedRect {
                    sliderRow("Roundness", value: $layout.cornerRadiusFrac, in: 0.0...0.5)
                }

                HStack(spacing: 10) {
                    Toggle("Border", isOn: $layout.border)
                    if layout.border {
                        Slider(value: $layout.borderWidthFrac, in: 0.0...0.05).frame(width: 120)
                        ForEach(Self.swatches, id: \.1) { name, hex in
                            swatch(name: name, hex: hex)
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 18) {
                    Toggle("Shadow", isOn: $layout.shadow)
                    Toggle("Mirror", isOn: $layout.mirror)
                    Toggle("Show camera", isOn: $layout.cameraVisible)
                    Spacer()
                    Button("Reset position") {
                        layout.centerX = 0.84; layout.centerY = 0.82; layout.widthFrac = 0.22
                    }
                    .controlSize(.small)
                }
                .toggleStyle(.checkbox)
            }
            .padding(6)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 72, alignment: .leading).foregroundStyle(.secondary)
            Slider(value: value, in: range)
        }
    }

    static let swatches: [(String, String)] = [
        ("White", "#FFFFFF"), ("Black", "#000000"), ("Slate", "#0B1F33"), ("Coral", "#FA7699")
    ]

    private func swatch(name: String, hex: String) -> some View {
        let selected = layout.borderColorHex.uppercased() == hex.uppercased()
        return Button {
            layout.borderColorHex = hex
        } label: {
            Circle()
                .fill(Color(cgColor: CGColor.fromHex(hex) ?? CGColor(gray: 0.5, alpha: 1)))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.4),
                                               lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .help(name)
    }

    // MARK: transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button { rp.togglePlay() } label: {
                Image(systemName: rp.isPlaying ? "pause.fill" : "play.fill").frame(width: 30, height: 22)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!rp.ready)
            .keyboardShortcut(.space, modifiers: [])

            Text(timecode(rp.currentTime)).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            Slider(value: Binding(get: { rp.currentTime }, set: { rp.scrub(to: $0) }),
                   in: 0...max(rp.duration, 0.1))
                .disabled(!rp.ready)
            Text(timecode(rp.duration)).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
        }
    }

    // MARK: header / export bar

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compose walkthrough").font(.title3).bold()
                Text(bundle.id).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(rp.screenSize.width == 0 ? "—" : "\(Int(rp.screenSize.width))×\(Int(rp.screenSize.height))")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var exportBar: some View {
        HStack(spacing: 14) {
            if exporting {
                ProgressView(value: progress).frame(width: 220)
                Text("\(Int(progress * 100))%").font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Rendering walkthrough…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button { startExport() } label: {
                    Label("Export walkthrough", systemImage: "square.and.arrow.up")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canExport)

                if bundle.hasWalkthrough {
                    Button("Reveal last export") {
                        NSWorkspace.shared.activateFileViewerSelecting([bundle.walkthroughURL])
                    }
                    .controlSize(.small)
                }
            }
            Spacer()
            if let err = exportError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    // MARK: load / save / export

    private func load() async {
        loaded = false
        if let saved = WalkthroughLayout.load(from: bundle) { layout = saved }
        do {
            try await rp.load(bundle)
            try Task.checkCancellation()
            loaded = true
        } catch is CancellationError {
            // superseded
        } catch {
            exportError = "Couldn't load this take: \(error.localizedDescription)"
            loaded = true
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = layout
        let b = bundle
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            try? snapshot.write(to: b)
        }
    }

    private func startExport() {
        guard canExport else { return }
        try? layout.write(to: bundle)        // the export honors the contract on disk
        exporting = true; progress = 0; exportError = nil
        let b = bundle
        let l = layout
        Task {
            do {
                try await WalkthroughExporter.export(bundle: b, layout: l) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run {
                    exporting = false; progress = 1
                    NSWorkspace.shared.activateFileViewerSelecting([b.walkthroughURL])
                }
            } catch {
                await MainActor.run {
                    exporting = false
                    exportError = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func timecode(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
