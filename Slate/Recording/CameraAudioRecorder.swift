import AVFoundation
import CoreMedia

/// Records the camera and microphone as **separate files** from a single capture session:
/// `camera.mov` (H.264, video only) and `audio.wav` (LPCM, uncompressed for clean
/// transcription). One session means the two are mutually synced; each records its own
/// `startOffset` (first-sample time vs the global clock) so they align with the screen too.
///
/// Writers are created lazily on the first sample of each kind, so we capture exact source
/// dimensions / sample rate rather than guessing.
final class CameraAudioRecorder: NSObject,
                                 AVCaptureVideoDataOutputSampleBufferDelegate,
                                 AVCaptureAudioDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "slate.session")
    private let videoQueue = DispatchQueue(label: "slate.cam.video")
    private let audioQueue = DispatchQueue(label: "slate.cam.audio")

    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()

    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?

    private var t0: Double = 0
    private var cameraURL: URL?
    private var audioURL: URL?
    private var stopped = false

    private(set) var recordsVideo = false
    private(set) var recordsAudio = false

    // Filled in as the first samples arrive.
    private(set) var cameraStartOffset: Double?
    private(set) var audioStartOffset: Double?
    private(set) var cameraSize: CMVideoDimensions?
    private(set) var audioSampleRate: Int?
    private(set) var audioChannels: Int?

    // MARK: Setup

    /// Build the capture graph. Pass `nil` for a device to skip that track.
    func configure(camera: AVCaptureDevice?, mic: AVCaptureDevice?) {
        session.beginConfiguration()
        session.sessionPreset = .high

        if let camera, let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
            session.addInput(input)
            videoOut.alwaysDiscardsLateVideoFrames = true
            videoOut.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOut) { session.addOutput(videoOut); recordsVideo = true }
        }

        if let mic, let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
            audioOut.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOut) { session.addOutput(audioOut); recordsAudio = true }
        }

        session.commitConfiguration()
    }

    func start(t0: Double, cameraURL: URL, audioURL: URL) {
        self.t0 = t0
        self.cameraURL = cameraURL
        self.audioURL = audioURL
        stopped = false
        sessionQueue.async { [weak self] in self?.session.startRunning() }
    }

    func stop() async {
        stopped = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                if self?.session.isRunning == true { self?.session.stopRunning() }
                cont.resume()
            }
        }
        await finish(writer: videoWriter, input: videoInput, on: videoQueue)
        await finish(writer: audioWriter, input: audioInput, on: audioQueue)
    }

    // MARK: Sample delivery

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !stopped, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if output === videoOut { handleVideo(sampleBuffer) }
        else if output === audioOut { handleAudio(sampleBuffer) }
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if videoWriter == nil {
            // Measure the offset at the instant the first sample ARRIVES — before the
            // synchronous writer setup (which adds a few ms of disk/encoder latency that
            // would otherwise bias this stream late vs the others). Matches how screen and
            // audio are measured, so all three offsets are read the same way.
            cameraStartOffset = HostClock.now() - t0
            startVideoWriter(with: sb, at: pts)
        }
        if let input = videoInput, videoWriter?.status == .writing, input.isReadyForMoreMediaData {
            input.append(sb)
        }
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if audioWriter == nil {
            audioStartOffset = HostClock.now() - t0
            startAudioWriter(with: sb, at: pts)
        }
        if let input = audioInput, audioWriter?.status == .writing, input.isReadyForMoreMediaData {
            input.append(sb)
        }
    }

    // MARK: Lazy writer creation

    private func startVideoWriter(with sb: CMSampleBuffer, at pts: CMTime) {
        guard let url = cameraURL, let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        cameraSize = dims
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dims.width),
                AVVideoHeightKey: Int(dims.height)
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input) }
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            videoWriter = writer
            videoInput = input
        } catch {
            NSLog("Slate: camera writer error: \(error.localizedDescription)")
        }
    }

    private func startAudioWriter(with sb: CMSampleBuffer, at pts: CMTime) {
        guard let url = audioURL,
              let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        let rate = Int(asbd.mSampleRate)
        let channels = Int(asbd.mChannelsPerFrame)
        audioSampleRate = rate
        audioChannels = channels
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input) }
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            audioWriter = writer
            audioInput = input
        } catch {
            NSLog("Slate: audio writer error: \(error.localizedDescription)")
        }
    }

    private func finish(writer: AVAssetWriter?, input: AVAssetWriterInput?, on queue: DispatchQueue) async {
        guard let writer, writer.status == .writing else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                input?.markAsFinished()
                writer.finishWriting { cont.resume() }
            }
        }
    }
}
