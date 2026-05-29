import SwiftUI
import AppKit

@main
struct SlateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}   // no "New Window"
        }
    }
}

/// Finalizes an in-flight recording on quit. Without this, Cmd-Q (or any termination)
/// while recording leaves `camera.mov` with no moov atom — unplayable — and writes no
/// `meta.json`, so the take is destroyed and the bundle is unusable by the pipeline.
/// Returning `.terminateLater` lets the async writer-finish + meta-write complete first.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = RecordingCoordinator.active, coordinator.isRecording else {
            return .terminateNow
        }
        coordinator.status = "Finishing recording before quitting…"
        Task { @MainActor in
            await coordinator.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
