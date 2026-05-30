import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Captures one display to `screen.mov` using ScreenCaptureKit's `SCRecordingOutput`
/// (macOS 15+), which writes the file for us. We also attach a minimal stream output
/// purely to timestamp the first delivered frame — that gives us `startOffset`, the
/// screen's position on the global timeline. No zoom is baked in; the full-resolution
/// screen is recorded raw and zoom becomes an editing decision downstream.
final class ScreenRecorder: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let sampleQueue = DispatchQueue(label: "slate.screen.sample")

    private var t0: Double = 0
    private var firstFrameSeen = false

    private(set) var startOffset: Double?
    private(set) var pixelWidth: Int = 0
    private(set) var pixelHeight: Int = 0

    /// Called if the stream stops on its own mid-recording (e.g. the display slept and
    /// ScreenCaptureKit tore the stream down). Lets the coordinator warn the user instead of
    /// silently ending the screen track while camera + mic keep going.
    var onStreamStopped: ((Error) -> Void)?
    private var stopping = false        // set when WE stop, to distinguish from an unexpected stop

    func start(display: SCDisplay,
               pixelWidth: Int,
               pixelHeight: Int,
               fps: Int,
               excluding app: SCRunningApplication?,
               outputURL: URL,
               t0: Double) async throws {
        self.t0 = t0
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        firstFrameSeen = false
        stopping = false
        startOffset = nil

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 6
        config.showsCursor = true
        config.capturesAudio = false              // mic is captured separately
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let filter: SCContentFilter
        if let app {
            filter = SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = outputURL
        recConfig.outputFileType = .mov
        let recOutput = SCRecordingOutput(configuration: recConfig, delegate: self)
        try stream.addRecordingOutput(recOutput)

        self.stream = stream
        self.recordingOutput = recOutput
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        stopping = true
        do { try await stream.stopCapture() }
        catch { NSLog("Slate: screen stopCapture error: \(error.localizedDescription)") }
        self.stream = nil
        self.recordingOutput = nil
    }

    // MARK: SCStreamOutput — first-frame timing only

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !firstFrameSeen, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        // Only count complete frames.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }
        firstFrameSeen = true
        startOffset = HostClock.now() - t0
    }

    // MARK: Delegates (logging)

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Slate: screen stream stopped with error: \(error.localizedDescription)")
        if !stopping { onStreamStopped?(error) }   // unexpected stop (e.g. display slept)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        NSLog("Slate: recording output failed: \(error.localizedDescription)")
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {}
}
