import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo

/// Renders a take + `Layout` into a single `walkthrough.mp4` — the native, one-click Loom-style
/// export. It reuses `CompositionBuilder` for timeline alignment, then transcodes with
/// `AVAssetReader` → Core Image → `AVAssetWriter`, compositing the camera "head" per-frame.
///
/// Why frame-by-frame and not `AVMutableVideoComposition`: that API renders BLACK on macOS 26
/// (the same reason review playback uses two layers). Reading frames and compositing them in
/// Core Image ourselves sidesteps it entirely and works across OS versions.
enum WalkthroughExporter {

    enum ExportError: LocalizedError {
        case noScreen, config, read, write
        var errorDescription: String? {
            switch self {
            case .noScreen: return "This take has no screen video to export."
            case .config:   return "Couldn't configure the export pipeline."
            case .read:     return "Failed while reading the take."
            case .write:    return "Failed while writing the video."
            }
        }
    }

    /// Cap the long edge so a Retina screen doesn't produce a huge file; keep dimensions even (H.264).
    static func outputSize(screen: CGSize) -> CGSize {
        var w = screen.width, h = screen.height
        if w <= 0 || h <= 0 { w = 1920; h = 1080 }
        let maxW: CGFloat = 1920
        let scale = min(1, maxW / w)
        w *= scale; h *= scale
        func even(_ x: CGFloat) -> CGFloat { CGFloat(max(1, Int((x / 2).rounded())) * 2) }
        return CGSize(width: even(w), height: even(h))
    }

    static func export(bundle: TakeBundle,
                       layout: WalkthroughLayout,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let r = try await CompositionBuilder.build(bundle)
        guard r.hasScreenVideo else { throw ExportError.noScreen }
        try await render(screenAudio: r.master, camera: r.camera,
                         screenSize: r.screenSize, cameraSize: r.cameraSize,
                         hasAudio: r.hasAudio, duration: r.duration.seconds,
                         layout: layout, to: bundle.walkthroughURL, progress: progress)
    }

    /// The reusable core: read `screenAudio` (screen video + optional audio) and an optional
    /// `camera` asset, composite the camera "head" per-frame in Core Image (NOT
    /// AVMutableVideoComposition — that renders black on macOS 26), and write `outURL`. Both the
    /// Compose walkthrough and the Edit-tab final render call this; the Edit tab passes
    /// already-cut compositions so trims/cuts are baked in.
    static func render(screenAudio: AVAsset, camera: AVAsset?,
                       screenSize: CGSize, cameraSize: CGSize, hasAudio: Bool, duration: Double,
                       layout: WalkthroughLayout, to outURL: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let screenTrack = try await screenAudio.loadTracks(withMediaType: .video).first
        else { throw ExportError.noScreen }

        let outSize = outputSize(screen: screenSize)
        let pixelAttrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

        // ---- readers --------------------------------------------------------
        let reader = try AVAssetReader(asset: screenAudio)
        let vOut = AVAssetReaderTrackOutput(track: screenTrack, outputSettings: pixelAttrs)
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw ExportError.config }
        reader.add(vOut)

        var aOut: AVAssetReaderTrackOutput? = nil
        var aacSettings: [String: Any]? = nil
        if hasAudio, let aTrack = try await screenAudio.loadTracks(withMediaType: .audio).first {
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: pcm)
            o.alwaysCopiesSampleData = false
            if reader.canAdd(o) { reader.add(o); aOut = o }
            let (sr, ch) = await audioFormat(aTrack)
            aacSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: ch,
                AVEncoderBitRateKey: 128_000
            ]
        }

        var camReader: AVAssetReader? = nil
        var camOut: AVAssetReaderTrackOutput? = nil
        if layout.cameraVisible, let cam = camera,
           let camTrack = try await cam.loadTracks(withMediaType: .video).first {
            let cr = try AVAssetReader(asset: cam)
            let co = AVAssetReaderTrackOutput(track: camTrack, outputSettings: pixelAttrs)
            co.alwaysCopiesSampleData = false
            if cr.canAdd(co) { cr.add(co); camReader = cr; camOut = co }
        }

        // ---- writer ---------------------------------------------------------
        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(url: outURL, fileType: .mp4)

        let bitrate = Int(outSize.width * outSize.height) * 4
        let vSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outSize.width),
            AVVideoHeightKey: Int(outSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw ExportError.config }
        writer.add(vIn)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outSize.width),
                kCVPixelBufferHeightKey as String: Int(outSize.height)
            ])

        var aIn: AVAssetWriterInput? = nil
        if let aac = aacSettings, aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            i.expectsMediaDataInRealTime = false
            if writer.canAdd(i) { writer.add(i); aIn = i }
        }

        // ---- start ----------------------------------------------------------
        guard reader.startReading() else { throw reader.error ?? ExportError.read }
        camReader?.startReading()
        guard writer.startWriting() else { throw writer.error ?? ExportError.write }
        writer.startSession(atSourceTime: .zero)

        let cameraAspect: CGFloat = cameraSize.height > 0 ? cameraSize.width / cameraSize.height : 16.0 / 9.0
        let compositor = WalkthroughCompositor(outSize: outSize, layout: layout, cameraAspect: cameraAspect)
        let renderDuration = max(0.1, duration)

        // ---- pump video + audio, finish on completion -----------------------
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let vQueue = DispatchQueue(label: "slate.export.video")
            let aQueue = DispatchQueue(label: "slate.export.audio")

            // camera frame matching — only ever touched on vQueue
            var pendingCam: CMSampleBuffer? = nil
            var lastCamRetain: CMSampleBuffer? = nil
            var lastCamPix: CVPixelBuffer? = nil
            var camDone = false
            func camFrame(atOrBefore pts: CMTime) -> CVPixelBuffer? {
                guard let camOut else { return nil }
                while true {
                    if let p = pendingCam {
                        if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(p), pts) <= 0 {
                            if let img = CMSampleBufferGetImageBuffer(p) { lastCamPix = img; lastCamRetain = p }
                            pendingCam = nil
                        } else { break }
                    } else if camDone {
                        break
                    } else if let nx = camOut.copyNextSampleBuffer() {
                        pendingCam = nx
                    } else { camDone = true; break }
                }
                _ = lastCamRetain   // keep the backing sample buffer alive for the pixel buffer
                return lastCamPix
            }

            group.enter()
            vIn.requestMediaDataWhenReady(on: vQueue) {
                while vIn.isReadyForMoreMediaData {
                    var finished = false
                    autoreleasepool {
                        guard let sb = vOut.copyNextSampleBuffer(),
                              let screenPix = CMSampleBufferGetImageBuffer(sb) else { finished = true; return }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                        let cam = camFrame(atOrBefore: pts)
                        if let pool = adaptor.pixelBufferPool,
                           let outPix = compositor.makeFrame(screen: screenPix, camera: cam, pool: pool) {
                            adaptor.append(outPix, withPresentationTime: pts)
                        }
                        progress(min(0.99, pts.seconds / renderDuration))
                    }
                    if finished { vIn.markAsFinished(); group.leave(); break }
                }
            }

            if let aIn, let aOut {
                group.enter()
                aIn.requestMediaDataWhenReady(on: aQueue) {
                    while aIn.isReadyForMoreMediaData {
                        if let sb = aOut.copyNextSampleBuffer() {
                            aIn.append(sb)
                        } else {
                            aIn.markAsFinished(); group.leave(); break
                        }
                    }
                }
            }

            group.notify(queue: DispatchQueue(label: "slate.export.done")) {
                if reader.status == .failed {
                    cont.resume(throwing: reader.error ?? ExportError.read); return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        progress(1.0); cont.resume()
                    } else {
                        cont.resume(throwing: writer.error ?? ExportError.write)
                    }
                }
            }
        }
    }

    private static func audioFormat(_ track: AVAssetTrack) async -> (Double, Int) {
        if let descs = try? await track.load(.formatDescriptions), let d = descs.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
            let sr = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
            let ch = asbd.mChannelsPerFrame == 0 ? 2 : Int(asbd.mChannelsPerFrame)
            return (sr, ch)
        }
        return (48_000, 2)
    }
}

/// The per-frame Core Image compositor: screen background + shaped, bordered, optionally
/// shadowed/mirrored camera bubble, placed per `Layout`. Core Image is bottom-left origin, so
/// the bubble rect (stored top-left) is flipped here — the single place that conversion happens.
final class WalkthroughCompositor {
    private let ctx: CIContext
    private let outSize: CGSize
    private let layout: WalkthroughLayout
    private let cameraAspect: CGFloat
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(outSize: CGSize, layout: WalkthroughLayout, cameraAspect: CGFloat) {
        self.outSize = outSize
        self.layout = layout
        self.cameraAspect = cameraAspect
        self.ctx = CIContext(options: [.useSoftwareRenderer: false])
    }

    func makeFrame(screen: CVPixelBuffer, camera: CVPixelBuffer?, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        let outRect = CGRect(origin: .zero, size: outSize)

        var screenCI = CIImage(cvPixelBuffer: screen)
        let sScale = screenCI.extent.width > 0 ? outSize.width / screenCI.extent.width : 1
        screenCI = screenCI.transformed(by: CGAffineTransform(scaleX: sScale, y: sScale))
        var comp = screenCI.cropped(to: outRect)

        if let camera, layout.cameraVisible {
            // top-left bubble rect → Core Image bottom-left rect
            let tl = layout.bubbleRect(canvas: outSize, cameraAspect: cameraAspect)
            let rect = CGRect(x: tl.minX, y: outSize.height - tl.maxY, width: tl.width, height: tl.height)
            let cr = layout.cornerRadius(for: tl.size)
            let bw = layout.borderWidthPx(canvas: outSize)

            if layout.shadow {
                let sr = max(4, tl.width * 0.05)
                if let shape = roundedRect(extent: rect, radius: cr, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)) {
                    let blur = CIFilter.gaussianBlur()
                    blur.inputImage = shape
                    blur.radius = Float(sr)
                    if let blurred = blur.outputImage?.transformed(by: CGAffineTransform(translationX: 0, y: -sr * 0.4)) {
                        comp = blurred.composited(over: comp)
                    }
                }
            }

            var camRect = rect
            var camRadius = cr
            if layout.border, bw > 0, let bc = CGColor.fromHex(layout.borderColorHex),
               let borderImg = roundedRect(extent: rect, radius: cr, color: CIColor(cgColor: bc)) {
                comp = borderImg.composited(over: comp)
                camRect = rect.insetBy(dx: bw, dy: bw)
                camRadius = max(0, cr - bw)
            }

            if let shaped = shapedCamera(camera, rect: camRect, radius: camRadius) {
                comp = shaped.composited(over: comp)
            }
        }

        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let outPix = out else { return nil }
        ctx.render(comp, to: outPix, bounds: outRect, colorSpace: colorSpace)
        return outPix
    }

    private func shapedCamera(_ camera: CVPixelBuffer, rect: CGRect, radius: CGFloat) -> CIImage? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        var cam = CIImage(cvPixelBuffer: camera)
        let ext = cam.extent
        if layout.mirror {
            cam = cam.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                     .transformed(by: CGAffineTransform(translationX: ext.width, y: 0))
        }
        // aspect-fill into rect, centered, then crop
        let scale = max(rect.width / ext.width, rect.height / ext.height)
        cam = cam.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = rect.midX - cam.extent.midX
        let dy = rect.midY - cam.extent.midY
        cam = cam.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: rect)

        guard let mask = roundedRect(extent: rect, radius: radius,
                                     color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)) else { return cam }
        let f = CIFilter.sourceInCompositing()
        f.inputImage = cam
        f.backgroundImage = mask   // keep camera only where the mask is opaque
        return f.outputImage
    }

    private func roundedRect(extent: CGRect, radius: CGFloat, color: CIColor) -> CIImage? {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = extent
        f.radius = Float(max(0, min(radius, min(extent.width, extent.height) / 2)))
        f.color = color
        return f.outputImage
    }
}
