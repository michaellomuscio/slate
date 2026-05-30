import AVFoundation
import CoreMedia
import CoreGraphics

/// Builds the compositions the in-app review player plays. Crucially it produces TWO separate
/// compositions and NO `AVMutableVideoComposition`:
///
///   • master  — the screen video track + the audio track, aligned. Because it has a single
///               video track and no video-composition, `AVPlayer` plays it NATIVELY (this is
///               rock-solid; the old `AVMutableVideoComposition` path renders black on
///               macOS 26, which is why review playback showed a dark screen).
///   • camera  — the camera video track alone, in its own composition.
///
/// Both compositions share ONE timeline: t=0 is the earliest stream's start (head shift), so a
/// given composition time means the same global instant in both. The review player keeps the
/// two players locked to that shared time, and composites the camera as a PIP in SwiftUI —
/// which also lets each element (screen / camera / captions / audio) be toggled independently.
enum CompositionBuilder {

    struct Result {
        let master: AVMutableComposition        // screen video (if any) + audio
        let camera: AVMutableComposition?       // camera video only (nil if no camera)
        let duration: CMTime
        let hasScreenVideo: Bool
        let hasCamera: Bool
        let hasAudio: Bool
        let screenSize: CGSize                   // native screen pixels (for aspect ratio)
        let cameraSize: CGSize                   // native camera pixels (for PIP aspect ratio)
    }

    static func build(_ bundle: TakeBundle) async throws -> Result {
        let streams = bundle.meta.streams
        func offset(_ key: String) -> Double { streams[key]?.startOffset ?? 0 }

        // Head shift: earliest present stream becomes t=0 on the shared timeline.
        var offs: [Double] = []
        if bundle.screenURL != nil { offs.append(offset("screen")) }
        if bundle.cameraURL  != nil { offs.append(offset("camera")) }
        if bundle.audioURL   != nil { offs.append(offset("audio")) }
        let head = offs.min() ?? 0

        let master = AVMutableComposition()
        var maxEnd = CMTime.zero
        var hasScreenVideo = false
        var hasAudio = false

        @Sendable func insert(into comp: AVMutableComposition, url: URL,
                              media: AVMediaType, offsetKey: String) async throws -> Bool {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: media).first,
                  let dst = comp.addMutableTrack(withMediaType: media,
                                                 preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return false }
            let dur = try await asset.load(.duration)
            let start = CMTime(seconds: max(0, offset(offsetKey) - head), preferredTimescale: 600)
            try dst.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: track, at: start)
            let end = CMTimeAdd(start, dur)
            if CMTimeCompare(end, maxEnd) > 0 { maxEnd = end }
            return true
        }

        if let url = bundle.screenURL {
            hasScreenVideo = (try? await insert(into: master, url: url, media: .video, offsetKey: "screen")) ?? false
        }
        if let url = bundle.audioURL {
            hasAudio = (try? await insert(into: master, url: url, media: .audio, offsetKey: "audio")) ?? false
        }

        var cameraComp: AVMutableComposition? = nil
        if let url = bundle.cameraURL {
            let cc = AVMutableComposition()
            if (try? await insert(into: cc, url: url, media: .video, offsetKey: "camera")) == true {
                cameraComp = cc
            }
        }

        func size(_ key: String, _ dw: Int, _ dh: Int) -> CGSize {
            CGSize(width: streams[key]?.width ?? dw, height: streams[key]?.height ?? dh)
        }
        let screenSize = CGSize(width: bundle.meta.display.pixelWidth,
                                height: bundle.meta.display.pixelHeight)

        return Result(master: master, camera: cameraComp, duration: maxEnd,
                      hasScreenVideo: hasScreenVideo, hasCamera: cameraComp != nil,
                      hasAudio: hasAudio, screenSize: screenSize,
                      cameraSize: size("camera", 1920, 1080))
    }
}
