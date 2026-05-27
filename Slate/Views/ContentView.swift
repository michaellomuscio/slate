import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @StateObject private var coordinator = RecordingCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if !coordinator.screenPerm {
                PermissionBanner(coordinator: coordinator)
            }

            GroupBox("Sources") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Display").gridColumnAlignment(.trailing)
                        Picker("", selection: $coordinator.selectedDisplayID) {
                            ForEach(coordinator.displays, id: \.displayID) { d in
                                Text(displayLabel(d)).tag(Optional(d.displayID))
                            }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Camera").gridColumnAlignment(.trailing)
                        Picker("", selection: $coordinator.selectedCameraID) {
                            Text("None").tag(String?.none)
                            ForEach(coordinator.cameras, id: \.uniqueID) { c in
                                Text(c.localizedName).tag(Optional(c.uniqueID))
                            }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Microphone").gridColumnAlignment(.trailing)
                        Picker("", selection: $coordinator.selectedMicID) {
                            Text("None").tag(String?.none)
                            ForEach(coordinator.mics, id: \.uniqueID) { m in
                                Text(m.localizedName).tag(Optional(m.uniqueID))
                            }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Frame rate").gridColumnAlignment(.trailing)
                        Picker("", selection: $coordinator.fps) {
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }.labelsHidden().frame(width: 120)
                    }
                }
                .padding(6)
            }

            PermissionsView(coordinator: coordinator)

            Spacer(minLength: 0)
            recordBar
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 520)
        .task { await coordinator.refreshDevices() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
                .font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text("Slate").font(.title2).bold()
                Text("Records screen, camera, mic & clicks as a Claude-editable bundle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var recordBar: some View {
        HStack(spacing: 14) {
            Button {
                Task {
                    if coordinator.isRecording { await coordinator.stop() }
                    else { await coordinator.start() }
                }
            } label: {
                Label(coordinator.isRecording ? "Stop" : "Record",
                      systemImage: coordinator.isRecording ? "stop.fill" : "record.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .keyboardShortcut("r", modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .tint(coordinator.isRecording ? .red : .accentColor)
            .disabled(!coordinator.isRecording && !coordinator.canRecord)

            if coordinator.isRecording {
                Text(timeString(coordinator.elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.red)
            } else if let url = coordinator.lastBundleURL {
                Button("Reveal Last Take") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !coordinator.status.isEmpty {
                Text(coordinator.status)
                    .font(.caption).foregroundStyle(.secondary)
                    .offset(y: 22)
            }
        }
    }

    private func displayLabel(_ d: SCDisplay) -> String {
        let main = d.displayID == CGMainDisplayID() ? " (Main)" : ""
        return "\(d.width)×\(d.height)\(main)"
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
