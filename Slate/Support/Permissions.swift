import AVFoundation
import CoreGraphics
import ApplicationServices
import AppKit

enum PermissionState {
    case granted, denied, notDetermined
}

/// Thin wrappers over the four TCC permissions Slate touches. Nothing here records — it
/// only checks and prompts. Screen Recording and Accessibility have no Info.plist usage
/// strings; they're granted in System Settings, so we also expose deep-links to the panes.
enum Permissions {

    // MARK: Camera / Microphone (AVFoundation)

    static func camera() -> PermissionState { map(AVCaptureDevice.authorizationStatus(for: .video)) }
    static func microphone() -> PermissionState { map(AVCaptureDevice.authorizationStatus(for: .audio)) }

    @discardableResult
    static func requestCamera() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }

    @discardableResult
    static func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    // MARK: Screen Recording (CoreGraphics)

    static func screenRecording() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt the first time; returns current grant state.
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: Accessibility (for the global mouse-click monitor)

    static func accessibility() -> Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: Settings deep-links

    /// `pane` is a Privacy anchor, e.g. "Privacy_ScreenCapture", "Privacy_Camera",
    /// "Privacy_Microphone", "Privacy_Accessibility".
    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func map(_ s: AVAuthorizationStatus) -> PermissionState {
        switch s {
        case .authorized:            return .granted
        case .denied, .restricted:   return .denied
        case .notDetermined:         return .notDetermined
        @unknown default:            return .denied
        }
    }
}
