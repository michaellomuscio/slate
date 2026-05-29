import Foundation

/// Mirror of `transcript.json` written by `pipeline/ingest.py`. All times live on the
/// global timeline (the same one the streams + events use).
///
/// Only `words` is required — captions depend solely on it. Everything else is optional so
/// an older, partial, or half-written transcript (e.g. missing `segments`/`silences`, or a
/// newer key like `disfluencies`/`audioEvents`) still decodes and still shows captions,
/// rather than silently vanishing on a single missing key.
struct TranscriptDoc: Codable {
    var audioStartOffset: Double?
    var duration: Double?
    var language: String?
    var text: String?
    var words: [Word]
    var segments: [Seg]?
    var silences: [Silence]?
    var disfluencies: [Disfl]?
    var stt: String?

    struct Word: Codable { var w: String; var start: Double; var end: Double; var p: Double? }
    struct Seg: Codable { var text: String; var start: Double; var end: Double }
    struct Silence: Codable { var start: Double; var end: Double; var dur: Double }
    struct Disfl: Codable { var start: Double; var end: Double; var dur: Double }
}

/// Pre-grouped captions for live playback — words bundled into cues of up to 7 words
/// or a gap > 0.6s, matching the SRT generator in `render.py`. `caption(at:)` returns
/// whichever cue spans the given global-timeline time.
struct CaptionsTrack {
    struct Cue: Identifiable, Hashable {
        let id = UUID()
        let start: Double
        let end: Double
        let text: String
        static func == (l: Cue, r: Cue) -> Bool { l.id == r.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    let cues: [Cue]

    static func load(from bundle: TakeBundle) -> CaptionsTrack? {
        guard let data = try? Data(contentsOf: bundle.transcriptURL) else { return nil }
        let doc: TranscriptDoc
        do {
            doc = try JSONDecoder().decode(TranscriptDoc.self, from: data)
        } catch {
            // Don't fail silently — a schema drift that drops captions should be visible.
            NSLog("Slate: transcript.json decode failed (captions unavailable): \(error)")
            return nil
        }
        var cues: [Cue] = []
        var current: [TranscriptDoc.Word] = []
        for w in doc.words {
            if let last = current.last, current.count >= 7 || w.start - last.end > 0.6 {
                cues.append(makeCue(current)); current = []
            }
            current.append(w)
        }
        if !current.isEmpty { cues.append(makeCue(current)) }
        return CaptionsTrack(cues: cues)
    }

    private static func makeCue(_ words: [TranscriptDoc.Word]) -> Cue {
        let start = words.first?.start ?? 0
        let end = words.last?.end ?? start
        let text = words.map(\.w).joined(separator: " ")
        return Cue(start: start, end: end, text: text)
    }

    func caption(at t: Double) -> String? {
        // Return the LATEST-starting cue that contains t. Cues are back-to-back on continuous
        // speech (the 7-word cap), so a first-match scan with a 0.4s tail would keep showing
        // the previous line ~0.4s into the next one; picking the latest start avoids that.
        var best: Cue?
        for c in cues where c.start - 0.05 <= t && t <= c.end + 0.4 {
            if best == nil || c.start > best!.start { best = c }
        }
        return best?.text
    }
}
