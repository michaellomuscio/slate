import Foundation

/// Codable mirror of `meta.json` — the alignment key written at the top of every take
/// bundle. See README "The take bundle (the contract)".

struct Rect: Codable {
    var x: Double, y: Double, w: Double, h: Double
}

struct DisplayInfo: Codable {
    var id: UInt32
    var name: String
    var pixelWidth: Int
    var pixelHeight: Int
    var pointWidth: Int
    var pointHeight: Int
    var backingScaleFactor: Double
    var globalFrame: Rect          // AppKit coords (origin bottom-left, primary screen at 0,0)
}

struct StreamInfo: Codable {
    var file: String
    var startOffset: Double         // seconds from global t=0 to this stream's first sample
    var width: Int? = nil
    var height: Int? = nil
    var sampleRate: Int? = nil
    var channels: Int? = nil
}

struct TakeMeta: Codable {
    var schemaVersion: Int = 1
    var app: String = "Slate"
    var appVersion: String
    var createdAt: String           // ISO-8601 UTC wall clock
    var fps: Int
    var display: DisplayInfo
    var streams: [String: StreamInfo]
    var events: String = "events.jsonl"

    func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url)
    }
}

extension ISO8601DateFormatter {
    static let utc: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
