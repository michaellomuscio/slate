import SwiftUI

/// The big call-to-action shown when Screen Recording isn't granted (nothing works without it).
struct PermissionBanner: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading) {
                Text("Screen Recording permission needed").bold()
                Text("Slate can't capture the screen until this is granted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant") { coordinator.requestScreen() }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PermissionsView: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        GroupBox("Permissions") {
            VStack(spacing: 8) {
                row(name: "Screen Recording", granted: coordinator.screenPerm,
                    note: "required", action: { coordinator.requestScreen() },
                    settings: "Privacy_ScreenCapture")

                row(name: "Camera", granted: coordinator.camPerm == .granted,
                    note: coordinator.selectedCameraID == nil ? "off" : "for face cam",
                    action: { Task { await coordinator.requestCamera() } },
                    settings: "Privacy_Camera")

                row(name: "Microphone", granted: coordinator.micPerm == .granted,
                    note: coordinator.selectedMicID == nil ? "off" : "for narration",
                    action: { Task { await coordinator.requestMic() } },
                    settings: "Privacy_Microphone")

                row(name: "Accessibility", granted: coordinator.axPerm,
                    note: "optional — click log for auto-zoom",
                    action: { coordinator.requestAccessibility() },
                    settings: "Privacy_Accessibility")
            }
            .padding(6)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refreshPermissions()
        }
    }

    @ViewBuilder
    private func row(name: String, granted: Bool, note: String,
                     action: @escaping () -> Void, settings: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Granted").font(.caption).foregroundStyle(.green)
            } else {
                Button("Grant", action: action).controlSize(.small)
                Button {
                    Permissions.openSettings(settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .controlSize(.small)
                .help("Open in System Settings")
            }
        }
    }
}
