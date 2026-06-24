import Foundation
import AVFoundation
import CoreMedia

/// A removed span on the global timeline (a "cut" / break the user marked).
struct CutRange: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
}

/// The editor's state for one take: a trim window `[inPoint, outPoint]` plus zero or more
/// cut ranges inside it. It knows how to turn those decisions into the `edit.json` EDL that
/// `render.py` executes — a `keep`/`cut` partition of `[0, duration]` (see EDIT_SCHEMA.md).
/// Sync is guaranteed by the renderer: a `cut` removes the same span from audio and video.
@MainActor
final class EditDecision: ObservableObject {
    @Published var inPoint: Double = 0
    @Published var outPoint: Double = 0
    @Published var cuts: [CutRange] = []
    @Published private(set) var duration: Double = 0

    func load(duration: Double) {
        self.duration = max(0, duration)
        inPoint = 0
        outPoint = self.duration
        cuts = []
    }

    var isEdited: Bool { inPoint > 0.001 || outPoint < duration - 0.001 || !cuts.isEmpty }

    // MARK: edits

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

    func reset() { inPoint = 0; outPoint = duration; cuts = [] }

    private func normalize() {
        cuts.sort { $0.start < $1.start }
        var merged: [CutRange] = []
        for c in cuts {
            if var last = merged.last, c.start <= last.end {
                last.end = max(last.end, c.end); merged[merged.count - 1] = last
            } else { merged.append(c) }
        }
        cuts = merged
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

    /// Write `edit.json` into the bundle. If one already exists, only its `timeline` is
    /// replaced — existing `zooms`/`camera`/`captions`/`preset` (e.g. from propose_edit.py)
    /// are preserved, since the renderer clips zooms to whatever survives the cut.
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
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}

/// Renders the edited take to `final.mp4` **natively, in-app** — no Python, no external
/// ffmpeg, no repo dependency, so it just works wherever Slate is installed. It rebuilds the
/// exact aligned screen+audio composition the editor played (`CompositionBuilder.master`,
/// which has no `AVMutableVideoComposition`, so it dodges the macOS 26 black-render bug),
/// keeps only the surviving spans, and exports with `AVAssetExportSession`. Sync is preserved
/// by construction: each kept span copies video and audio together. This is a clean cut of
/// the screencast (screen + audio); zoom-on-click, burned captions, camera PIP and loudness
/// normalization remain the job of the full `/slate` pipeline.
enum NativeRenderer {
    static func render(bundle: TakeBundle, kept: [(Double, Double)]) async throws -> URL {
        let r = try await CompositionBuilder.build(bundle)
        guard r.hasScreenVideo || r.hasAudio else {
            throw err("This take has no screen or audio to render.")
        }

        let out = AVMutableComposition()
        let durSec = r.duration.seconds.isFinite ? r.duration.seconds : 0
        var cursor = CMTime.zero
        for (s, e) in kept {
            let startSec = max(0, s), endSec = min(e, durSec)
            guard endSec - startSec > 0.001 else { continue }
            let range = CMTimeRange(start: CMTime(seconds: startSec, preferredTimescale: 600),
                                    end: CMTime(seconds: endSec, preferredTimescale: 600))
            try await out.insertTimeRange(range, of: r.master, at: cursor)
            cursor = CMTimeAdd(cursor, range.duration)
        }
        guard cursor.seconds > 0.05 else {     // cursor == total inserted length (avoids async AVAsset.duration)
            throw err("The edit removes everything — there's nothing left to render.")
        }

        let outURL = bundle.finalRenderURL
        try? FileManager.default.removeItem(at: outURL)
        guard let session = AVAssetExportSession(asset: out, presetName: AVAssetExportPresetHighestQuality) else {
            throw err("Couldn't create the video exporter for this take.")
        }
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: outURL, as: .mp4)
        return outURL
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "Slate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
