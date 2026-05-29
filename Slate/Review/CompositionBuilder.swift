import AVFoundation
import CoreMedia
import CoreGraphics

/// Builds an `AVMutableComposition` (+ optional video composition for camera PIP) that
/// plays a Slate take with all streams aligned by their `startOffset`s on the shared global
/// clock. This is what makes "screen + camera + audio in one synced playback" possible.
///
/// Two alignment rules keep the PREVIEW honest against the final render:
///  - HEAD SHIFT: everything is shifted so the earliest stream sits at composition t=0, so
///    there's no black/silent lead-in before the first captured frame (which the renderer
///    also omits — it pulls each file from its own local 0).
///  - MIN END: playback ends at the EARLIEST stream end (same authoritative end the renderer
///    uses), so preview length matches final length instead of running on a frozen frame.
enum CompositionBuilder {

    struct NoMediaError: LocalizedError {
        var errorDescription: String? {
            "This take has no readable video (screen.mov / camera.mov missing or unreadable)."
        }
    }

    static func build(_ bundle: TakeBundle) async throws
        -> (composition: AVMutableComposition,
            videoComposition: AVMutableVideoComposition?,
            duration: CMTime)
    {
        let comp = AVMutableComposition()
        let renderSize = CGSize(width: bundle.meta.display.pixelWidth,
                                height: bundle.meta.display.pixelHeight)

        // Gather present streams with their global offsets, so we can compute the head shift.
        struct Plan { let url: URL; let media: AVMediaType; let offset: Double; let key: String }
        var plans: [Plan] = []
        if let u = bundle.screenURL { plans.append(.init(url: u, media: .video,
            offset: bundle.meta.streams["screen"]?.startOffset ?? 0, key: "screen")) }
        if let u = bundle.cameraURL { plans.append(.init(url: u, media: .video,
            offset: bundle.meta.streams["camera"]?.startOffset ?? 0, key: "camera")) }
        if let u = bundle.audioURL { plans.append(.init(url: u, media: .audio,
            offset: bundle.meta.streams["audio"]?.startOffset ?? 0, key: "audio")) }

        let headOffset = plans.map(\.offset).min() ?? 0

        var screenTrack: AVMutableCompositionTrack?
        var cameraTrack: AVMutableCompositionTrack?
        var insertedVideo = false
        var minEnd = CMTime.positiveInfinity
        var maxEnd = CMTime.zero

        for plan in plans {
            let asset = AVURLAsset(url: plan.url)
            let tracks = try await asset.loadTracks(withMediaType: plan.media)
            guard let assetTrack = tracks.first else { continue }
            let dur = try await asset.load(.duration)
            guard let compTrack = comp.addMutableTrack(
                withMediaType: plan.media, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            // Shift onto the composition timeline so the earliest stream is at t=0.
            let start = CMTime(seconds: max(0, plan.offset - headOffset), preferredTimescale: 600)
            try compTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: dur), of: assetTrack, at: start)
            let end = CMTimeAdd(start, dur)
            if CMTimeCompare(end, maxEnd) > 0 { maxEnd = end }
            if CMTimeCompare(end, minEnd) < 0 { minEnd = end }
            if plan.media == .video {
                insertedVideo = true
                if plan.key == "screen" { screenTrack = compTrack } else { cameraTrack = compTrack }
            }
        }

        // A bundle whose media is missing/unreadable would otherwise build a silent black
        // composition indistinguishable from a real black video — surface it as an error.
        guard insertedVideo else { throw NoMediaError() }

        // Play to the earliest stream end (matches the renderer's authoritative timeline_end);
        // fall back to maxEnd if min wasn't set.
        let playEnd = (CMTimeCompare(minEnd, .positiveInfinity) < 0 && CMTimeCompare(minEnd, .zero) > 0)
            ? minEnd : maxEnd

        var videoComp: AVMutableVideoComposition?
        if let st = screenTrack {
            let vc = AVMutableVideoComposition()
            vc.renderSize = renderSize
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, bundle.meta.fps)))

            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: .zero, duration: playEnd)

            var layers: [AVMutableVideoCompositionLayerInstruction] = []
            let screenLI = AVMutableVideoCompositionLayerInstruction(assetTrack: st)
            screenLI.setTransform(.identity, at: .zero)
            layers.append(screenLI)

            // Camera PIP, bottom-right at ~18% of height (transform verified correct).
            if let ct = cameraTrack {
                let camStream = bundle.meta.streams["camera"]
                let camW = Double(camStream?.width ?? 640)
                let camH = Double(camStream?.height ?? 480)
                let pipH = Double(renderSize.height) * 0.18
                let scale = pipH / max(1.0, camH)
                let scaledW = camW * scale
                let scaledH = camH * scale
                let margin = Double(renderSize.height) * 0.03
                let tx = Double(renderSize.width)  - margin - scaledW
                let ty = Double(renderSize.height) - margin - scaledH
                let t = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                          tx: CGFloat(tx), ty: CGFloat(ty))
                let camLI = AVMutableVideoCompositionLayerInstruction(assetTrack: ct)
                camLI.setTransform(t, at: .zero)
                layers.append(camLI)        // last = drawn on top of screen
            }

            instr.layerInstructions = layers
            vc.instructions = [instr]
            videoComp = vc
        }

        return (comp, videoComp, playEnd)
    }
}
