import Foundation
import SwiftUI
import AVFoundation
import CoreMedia

/// A removed span on the global timeline (a "cut" / break the user marked).
struct CutRange: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
}

/// One redaction the user draws over the SCREEN preview. `x/y/w/h` are normalized 0…1, top-left
/// origin — the SwiftUI / WalkthroughLayout convention; the compositor is the ONE place this flips
/// into Core Image's bottom-left space. `[start,end]` is on the ORIGINAL take timeline (like
/// `CutRange`) so it survives re-trims/cuts; the renderer remaps it through the kept intervals.
/// `blur == true` → an unreadable pixellate+blur; otherwise a solid `colorHex` fill.
struct RedactionShape: Identifiable, Equatable {
    var id = UUID()
    var x: Double = 0.35          // normalized top-left rect
    var y: Double = 0.40
    var w: Double = 0.30
    var h: Double = 0.20
    var start: Double = 0         // ORIGINAL take-timeline seconds
    var end: Double = 0
    var blur: Bool = false        // false = solid fill, true = unreadable blur
    var colorHex: String = "#000000"

    /// UI accessor — fractional rect, top-left origin. Setting it rewrites x/y/w/h.
    var rect: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = Double(newValue.minX); y = Double(newValue.minY)
              w = Double(newValue.width); h = Double(newValue.height) }
    }

    /// Active at take-time `t`? Half-open [start,end) so adjacent windows don't double-fire.
    func isActive(at t: Double) -> Bool { t >= start && t < end }

    /// edit.json form — flat doubles (JSONSerialization can't encode a CGRect), rounded to 3 places.
    var dict: [String: Any] {
        ["x": r3(x), "y": r3(y), "w": r3(w), "h": r3(h),
         "start": r3(start), "end": r3(end),
         "blur": blur, "color": colorHex]
    }

    init(id: UUID = UUID(), x: Double = 0.35, y: Double = 0.40, w: Double = 0.30, h: Double = 0.20,
         start: Double = 0, end: Double = 0, blur: Bool = false, colorHex: String = "#000000") {
        self.id = id; self.x = x; self.y = y; self.w = w; self.h = h
        self.start = start; self.end = end; self.blur = blur; self.colorHex = colorHex
    }

    /// Restore from edit.json; nil on malformed geometry.
    init?(dict d: [String: Any]) {
        guard let x = d["x"] as? Double, let y = d["y"] as? Double,
              let w = d["w"] as? Double, let h = d["h"] as? Double else { return nil }
        self.x = x; self.y = y; self.w = w; self.h = h
        self.start = (d["start"] as? Double) ?? 0
        self.end   = (d["end"]   as? Double) ?? 0
        self.blur  = (d["blur"]  as? Bool)   ?? false
        self.colorHex = (d["color"] as? String) ?? "#000000"
    }

    private func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}

/// One redaction resolved for rendering. `rect` is normalized 0…1 top-left (same space as
/// `RedactionShape`). `[start,end]` is on the OUTPUT (post-cut) timeline — the cuts are already
/// applied, so one shape may yield several of these. `blur` → unreadable; otherwise `color`
/// (already resolved) fills. The render side never touches `RedactionShape` or `CGColor.fromHex`.
struct RenderRedaction: Sendable {
    var rect: CGRect        // normalized 0…1, top-left origin
    var start: Double       // OUTPUT-timeline seconds
    var end: Double
    var blur: Bool
    var color: CGColor?

    /// Active at output-time `t`? Half-open so back-to-back spans don't double-count.
    func activeAt(_ t: Double) -> Bool { t >= start && t < end }
}

/// The editor's state for one take: a trim window `[inPoint, outPoint]`, zero or more cut ranges,
/// and zero or more redaction rectangles. It turns the trim/cuts into the `edit.json` EDL that
/// `render.py` executes (a `keep`/`cut` partition of `[0, duration]`, see EDIT_SCHEMA.md), and
/// resolves redactions into render-ready output-timeline windows. Sync is guaranteed by the
/// renderer: a `cut` removes the same span from audio and video.
@MainActor
final class EditDecision: ObservableObject {
    @Published var inPoint: Double = 0
    @Published var outPoint: Double = 0
    @Published var cuts: [CutRange] = []
    @Published var redactions: [RedactionShape] = []
    @Published var selectedRedactionID: RedactionShape.ID? = nil
    @Published private(set) var duration: Double = 0

    func load(duration: Double) {
        self.duration = max(0, duration)
        inPoint = 0
        outPoint = self.duration
        cuts = []
        redactions = []
        selectedRedactionID = nil
    }

    var isEdited: Bool {
        inPoint > 0.001 || outPoint < duration - 0.001 || !cuts.isEmpty || !redactions.isEmpty
    }

    // MARK: trim / cuts

    func setIn(_ t: Double)  { inPoint = min(max(0, t), max(0, outPoint - 0.05)) }
    func setOut(_ t: Double) { outPoint = max(min(duration, t), min(duration, inPoint + 0.05)) }

    func addCut(from a: Double, to b: Double) {
        let s = max(0, min(a, b)), e = min(duration, max(a, b))
        guard e - s > 0.02 else { return }
        cuts.append(CutRange(start: s, end: e))
        normalize()
    }

    /// Remove the cut under time `t`, if any (so tapping a red block deletes it).
    func removeCut(at t: Double) { cuts.removeAll { t >= $0.start && t <= $0.end } }

    func reset() {
        inPoint = 0; outPoint = duration; cuts = []
        redactions = []; selectedRedactionID = nil
    }

    /// Sort + merge overlapping cuts. Internal (not private) so `restore` can call it.
    func normalize() {
        cuts.sort { $0.start < $1.start }
        var merged: [CutRange] = []
        for c in cuts {
            if var last = merged.last, c.start <= last.end {
                last.end = max(last.end, c.end); merged[merged.count - 1] = last
            } else { merged.append(c) }
        }
        cuts = merged
    }

    // MARK: redactions

    @discardableResult
    func addRedaction(atPlayhead t: Double) -> RedactionShape {
        let s = max(0, min(t, duration))
        let e = min(duration, s + 5)
        let r = RedactionShape(start: s, end: max(e, s + 0.1))   // centered ~0.30×0.20, solid black
        redactions.append(r)
        selectedRedactionID = r.id
        return r
    }

    func removeRedaction(_ id: RedactionShape.ID) {
        redactions.removeAll { $0.id == id }
        if selectedRedactionID == id { selectedRedactionID = nil }
    }

    /// A by-id binding so the UI can mutate a shape; robust to reorders/removals (no captured index).
    func binding(for id: RedactionShape.ID) -> Binding<RedactionShape>? {
        guard redactions.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.redactions.first(where: { $0.id == id }) ?? RedactionShape(id: id) },
            set: { nv in if let i = self.redactions.firstIndex(where: { $0.id == id }) { self.redactions[i] = nv } })
    }

    func setRedactionStart(_ id: RedactionShape.ID, to t: Double) {
        guard let i = redactions.firstIndex(where: { $0.id == id }) else { return }
        redactions[i].start = min(max(0, t), redactions[i].end - 0.05)
    }

    func setRedactionEnd(_ id: RedactionShape.ID, to t: Double) {
        guard let i = redactions.firstIndex(where: { $0.id == id }) else { return }
        redactions[i].end = max(min(duration, t), redactions[i].start + 0.05)
    }

    // MARK: derived

    /// Every removed span (trim head/tail + cuts), clamped, sorted, merged.
    func removedIntervals() -> [(Double, Double)] {
        var rem: [(Double, Double)] = []
        if inPoint > 0 { rem.append((0, inPoint)) }
        if outPoint < duration { rem.append((outPoint, duration)) }
        for c in cuts {
            let s = max(0, c.start), e = min(duration, c.end)
            if e > s { rem.append((s, e)) }
        }
        rem.sort { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for r in rem {
            if var last = merged.last, r.0 <= last.1 {
                last.1 = max(last.1, r.1); merged[merged.count - 1] = last
            } else { merged.append(r) }
        }
        return merged
    }

    var keptDuration: Double {
        max(0, duration - removedIntervals().reduce(0) { $0 + ($1.1 - $1.0) })
    }

    /// The surviving spans (complement of `removedIntervals` over `[0, duration]`), in order.
    /// Empty only if the edit removes everything.
    func keptIntervals() -> [(Double, Double)] {
        var kept: [(Double, Double)] = []
        var cursor = 0.0
        for (s, e) in removedIntervals() {
            if s > cursor { kept.append((cursor, s)) }
            cursor = max(cursor, e)
        }
        if cursor < duration { kept.append((cursor, duration)) }
        return kept
    }

    /// For live preview: if `t` falls inside a removed span, the time playback should jump to.
    func skipTarget(at t: Double) -> Double? {
        for (s, e) in removedIntervals() where t >= s && t < e { return e }
        return nil
    }

    /// Map an ORIGINAL-timeline range `[a,b]` through `keptIntervals()` onto the OUTPUT (post-cut)
    /// timeline. Returns 0…N windows: cuts inside `[a,b]` split it, trims clip it. Same kept-interval
    /// math the renderer bakes, so a redaction's timing matches the rendered cut exactly.
    func mapToOutput(_ a: Double, _ b: Double) -> [(Double, Double)] {
        let lo = min(a, b), hi = max(a, b)
        guard hi > lo else { return [] }
        var out: [(Double, Double)] = []
        var base = 0.0
        for (ks, ke) in keptIntervals() {
            let span = ke - ks
            let os = max(lo, ks), oe = min(hi, ke)
            if oe > os { out.append((base + (os - ks), base + (oe - ks))) }
            base += span
        }
        return out
    }

    /// Resolve every redaction into render-ready OUTPUT-timeline windows. Skips degenerate rects and
    /// zero-length windows; a solid with an unparseable color is dropped, a blur is kept regardless.
    func renderRedactions() -> [RenderRedaction] {
        var result: [RenderRedaction] = []
        for r in redactions {
            guard r.w > 0.001, r.h > 0.001 else { continue }
            let color = CGColor.fromHex(r.colorHex)
            if !r.blur && color == nil { continue }
            for (s, e) in mapToOutput(r.start, r.end) where e - s > 0.001 {
                result.append(RenderRedaction(rect: r.rect, start: s, end: e, blur: r.blur, color: color))
            }
        }
        return result
    }

    // MARK: edit.json

    /// Ordered `keep`/`cut` ops covering `[0, duration]` — the EDL timeline.
    func timelineOps() -> [[String: Any]] {
        var ops: [[String: Any]] = []
        var cursor = 0.0
        func keep(_ a: Double, _ b: Double) { if b - a > 0.001 { ops.append(["op": "keep", "start": r3(a), "end": r3(b)]) } }
        func cut(_ a: Double, _ b: Double)  { if b - a > 0.001 { ops.append(["op": "cut", "start": r3(a), "end": r3(b), "reason": "manual edit"]) } }
        for (s, e) in removedIntervals() {
            let cs = max(s, cursor)
            if cs > cursor { keep(cursor, cs) }
            if e > cs { cut(cs, e) }
            cursor = max(cursor, e)
        }
        if cursor < duration { keep(cursor, duration) }
        if ops.isEmpty { keep(0, max(duration, 0.001)) }
        return ops
    }

    /// Write `edit.json` into the bundle. An existing file's `zooms`/`camera`/`captions`/`preset`
    /// (e.g. from propose_edit.py) are preserved; only `timeline` and `redactions` are replaced.
    func writeEditJSON(to bundle: TakeBundle, hasCamera: Bool) throws {
        let url = bundle.path.appendingPathComponent("edit.json")
        var obj: [String: Any]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        } else {
            obj = [
                "version": 1, "source": "screen", "preset": "course",
                "zooms": [],
                "camera": ["enabled": hasCamera, "shape": "circle", "corner": "br", "size": 0.18],
                "captions": ["enabled": true, "burn": false],
            ]
        }
        obj["timeline"] = timelineOps()
        obj["redactions"] = redactions.map { $0.dict }   // [] clears the block when none
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    /// Rehydrate trims/cuts/redactions from an existing `edit.json` — the inverse of `timelineOps()`
    /// plus the redaction block. Call AFTER `load(duration:)` so un-edited takes keep a clean slate.
    func restore(from bundle: TakeBundle) {
        let url = bundle.path.appendingPathComponent("edit.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let ops = obj["timeline"] as? [[String: Any]], !ops.isEmpty {
            var removed: [(Double, Double)] = []
            for op in ops {
                guard (op["op"] as? String) == "cut",
                      let s = op["start"] as? Double, let e = op["end"] as? Double, e > s else { continue }
                removed.append((s, e))
            }
            removed.sort { $0.0 < $1.0 }
            var newCuts: [CutRange] = []
            var inP = 0.0, outP = duration
            for (s, e) in removed {
                if s <= 0.001 { inP = max(inP, e) }
                else if e >= duration - 0.001 { outP = min(outP, s) }
                else { newCuts.append(CutRange(start: s, end: e)) }
            }
            inPoint  = min(max(0, inP), max(0, duration))
            outPoint = max(min(duration, outP), inPoint + 0.05)
            cuts = newCuts
            normalize()
        }

        if let arr = obj["redactions"] as? [[String: Any]] {
            redactions = arr.compactMap { RedactionShape(dict: $0) }
        }
    }

    private func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}

/// Renders the edited take to `final.mp4` **natively, in-app** — no Python, no external ffmpeg,
/// no repo dependency. It bakes the kept spans into trimmed compositions for the screen+audio AND
/// the camera (cut with the SAME spans so they stay in sync), then hands them — plus any
/// `redactions` (already remapped to the output timeline) — to `WalkthroughExporter.render`, which
/// composites the camera "head" and paints the redactions per-frame in Core Image (NOT
/// `AVMutableVideoComposition` → no macOS 26 black-render). Output long edge capped at 1920.
enum NativeRenderer {
    static func render(bundle: TakeBundle, kept: [(Double, Double)],
                       redactions: [RenderRedaction] = [],
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let r = try await CompositionBuilder.build(bundle)
        guard r.hasScreenVideo else { throw err("This take has no screen video to render.") }
        let durSec = r.duration.seconds.isFinite ? r.duration.seconds : 0

        // Bake the cuts into a trimmed screen+audio composition.
        let cutSA = AVMutableComposition()
        var cursor = CMTime.zero
        for (s, e) in kept {
            let range = clamp(s, e, durSec)
            guard range.duration.seconds > 0.001 else { continue }
            try await cutSA.insertTimeRange(range, of: r.master, at: cursor)
            cursor = CMTimeAdd(cursor, range.duration)
        }
        guard cursor.seconds > 0.05 else {
            throw err("The edit removes everything — there's nothing left to render.")
        }

        // Cut the camera with the SAME spans so the face stays synced. It may end early (camera
        // warm-up / early stop) — skip those gaps; the compositor simply shows no bubble there.
        var cutCam: AVMutableComposition? = nil
        if r.hasCamera, let cam = r.camera {
            let cc = AVMutableComposition()
            var ccur = CMTime.zero
            for (s, e) in kept {
                let range = clamp(s, e, durSec)
                guard range.duration.seconds > 0.001 else { continue }
                try? await cc.insertTimeRange(range, of: cam, at: ccur)
                ccur = CMTimeAdd(ccur, range.duration)
            }
            cutCam = cc
        }

        var layout = WalkthroughLayout.load(from: bundle) ?? .default
        layout.cameraVisible = (cutCam != nil)       // always include the face when the take has one

        let outURL = bundle.finalRenderURL
        try await WalkthroughExporter.render(
            screenAudio: cutSA, camera: cutCam,
            screenSize: r.screenSize, cameraSize: r.cameraSize,
            hasAudio: r.hasAudio, duration: cursor.seconds,
            layout: layout, redactions: redactions, to: outURL, progress: progress)
        return outURL
    }

    private static func clamp(_ s: Double, _ e: Double, _ dur: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: max(0, s), preferredTimescale: 600),
                    end: CMTime(seconds: min(e, dur), preferredTimescale: 600))
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "Slate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
