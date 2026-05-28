import Foundation

/// One take folder under `~/Movies/Slate/`. Lightweight metadata only — the actual
/// playback composition is built lazily by `CompositionBuilder`.
struct TakeBundle: Identifiable, Hashable {
    let id: String                  // folder name, e.g. "take-2026-05-28-094500"
    let path: URL
    let meta: TakeMeta
    let hasTranscript: Bool
    let hasFinalRender: Bool
    let createdAtDate: Date?        // best-effort from meta.createdAt

    var screenURL: URL?  { streamURL("screen") }
    var cameraURL: URL?  { streamURL("camera") }
    var audioURL: URL?   { streamURL("audio") }
    var transcriptURL: URL { path.appendingPathComponent("transcript.json") }
    var finalRenderURL: URL { path.appendingPathComponent("final.mp4") }

    static let movieFolder: URL = {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Slate", isDirectory: true)
    }()

    static func loadAll() -> [TakeBundle] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: movieFolder.path),
              let items = try? fm.contentsOfDirectory(at: movieFolder,
                  includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return items
            .filter { $0.lastPathComponent.hasPrefix("take-") }
            .compactMap { TakeBundle(path: $0) }
            .sorted { $0.id > $1.id }       // newest first (lexicographic on take-<ts>)
    }

    init?(path: URL) {
        let metaURL = path.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let m = try? JSONDecoder().decode(TakeMeta.self, from: data) else { return nil }
        self.path = path
        self.id = path.lastPathComponent
        self.meta = m
        let fm = FileManager.default
        self.hasTranscript = fm.fileExists(atPath: path.appendingPathComponent("transcript.json").path)
        self.hasFinalRender = fm.fileExists(atPath: path.appendingPathComponent("final.mp4").path)
        self.createdAtDate = ISO8601DateFormatter.utc.date(from: m.createdAt)
    }

    private func streamURL(_ key: String) -> URL? {
        guard let s = meta.streams[key] else { return nil }
        let url = path.appendingPathComponent(s.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func == (lhs: TakeBundle, rhs: TakeBundle) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
