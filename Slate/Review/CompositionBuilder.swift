import AVFoundation
import CoreMedia
import CoreGraphics

/// Builds an `AVMutableComposition` (+ optional video composition for camera PIP) that
/// plays a Slate take with all three streams aligned by their `startOffset`s on the
/// shared global clock. This is what makes "screen + camera + audio in one synced
/// playback" possible — exactly the alignment guarantee meta.json was designed for.
enum CompositionBuilder {

    static func build(_ bundle: TakeBundle) async throws
        -> (composition: AVMutableComposition,
            videoComposition: AVMutableVideoComposition?,
            duration: CMTime)
    {
        let comp = AVMutableComposition()
        let renderSize = CGSize(width: bundle.meta.display.pixelWidth,
                                height: bundle.meta.display.pixelHeight)
        var maxEnd = CMTime.zero

        // Helper: load asset's primary track of `mediaType`, add a matching comp track,
        // and insert the asset at the requested global-timeline offset.
        @Sendable func insert(url: URL, mediaType: AVMediaType, offset: Double) async throws
            -> AVMutableCompositionTrack?
        {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: mediaType)
            guard let assetTrack = tracks.first else { return nil }
            let dur = try await asset.load(.duration)
            guard let compTrack = comp.addMutableTrack(
                withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { return nil }
            let start = CMTime(seconds: max(0, offset), preferredTimescale: 600)
            try compTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: dur),
                of: assetTrack, at: start)
            let end = CMTimeAdd(start, dur)
            if CMTimeCompare(end, maxEnd) > 0 { maxEnd = end }
            return compTrack
        }

        var screenTrack: AVMutableCompositionTrack? = nil
        var cameraTrack: AVMutableCompositionTrack? = nil

        if let url = bundle.screenURL {
            screenTrack = try await insert(
                url: url, mediaType: .video,
                offset: bundle.meta.streams["screen"]?.startOffset ?? 0)
        }
        if let url = bundle.cameraURL {
            cameraTrack = try await insert(
                url: url, mediaType: .video,
                offset: bundle.meta.streams["camera"]?.startOffset ?? 0)
        }
        if let url = bundle.audioURL {
            _ = try await insert(
                url: url, mediaType: .audio,
                offset: bundle.meta.streams["audio"]?.startOffset ?? 0)
        }

        // Video composition — needed iff we have screen video. Layer-instruction order
        // is back-to-front, so we put camera LAST so it renders on top of screen.
        var videoComp: AVMutableVideoComposition? = nil
        if let st = screenTrack {
            let vc = AVMutableVideoComposition()
            vc.renderSize = renderSize
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(bundle.meta.fps))

            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: .zero, duration: maxEnd)

            var layers: [AVMutableVideoCompositionLayerInstruction] = []

            let screenLI = AVMutableVideoCompositionLayerInstruction(assetTrack: st)
            screenLI.setTransform(.identity, at: .zero)
            layers.append(screenLI)

            if let ct = cameraTrack {
                let camStream = bundle.meta.streams["camera"]
                let camW = Double(camStream?.width ?? 640)
                let camH = Double(camStream?.height ?? 480)
                // Bottom-right PIP at ~18% of height.
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
                layers.append(camLI)
            }

            instr.layerInstructions = layers
            vc.instructions = [instr]
            videoComp = vc
        }

        return (comp, videoComp, maxEnd)
    }
}
