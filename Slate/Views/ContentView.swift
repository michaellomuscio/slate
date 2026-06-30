import SwiftUI
import ScreenCaptureKit

/// Top-level shell: four tabs — make a recording, compose a walkthrough, edit a take, or review
/// the ones you already made.
struct ContentView: View {
    var body: some View {
        TabView {
            RecordPanel()
                .tabItem { Label("Record", systemImage: "record.circle") }
            ComposeTab()
                .tabItem { Label("Compose", systemImage: "person.crop.rectangle") }
            EditView()
                .tabItem { Label("Edit", systemImage: "scissors") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "rectangle.stack") }
        }
        .frame(minWidth: 820, minHeight: 480)
    }
}

/// The recording UI — was the whole of ContentView before the Library was added.
struct RecordPanel: View {
    @StateObject private var coordinator = RecordingCoordinator()
    @StateObject private var teleprompter = TeleprompterController()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
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

                    TeleprompterBox(teleprompter: teleprompter, axGranted: coordinator.axPerm)

                    PermissionsView(coordinator: coordinator)
                }
                .padding(20)
            }

            Divider()
            recordBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
        }
        .frame(minWidth: 440, minHeight: 380)
        .task { await coordinator.refreshDevices() }
        .onAppear { teleprompter.targetDisplayID = coordinator.selectedDisplayID }
        .onChange(of: coordinator.selectedDisplayID) { _, id in
            teleprompter.targetDisplayID = id               // keep the strip on the recorded display
        }
        .onChange(of: coordinator.isRecording) { _, recording in
            // Convenience: hitting Record starts the crawl from the top; Stop pauses it.
            guard teleprompter.isVisible, !teleprompter.line.isEmpty else { return }
            if recording { teleprompter.restart(); teleprompter.play() } else { teleprompter.pause() }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
                .font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text("Slate").font(.title2).bold()
                Text("Records screen, camera, mic & clicks as a Claude-editable bundle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("LOMUSCIO LABS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Color.accentColor)
        }
    }

    private var recordBar: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            if !coordinator.status.isEmpty {
                Text(coordinator.status)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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

/// Record-tab controls for the teleprompter. The strip itself is a separate floating panel
/// (owned by `TeleprompterController`) that's excluded from the screen recording.
struct TeleprompterBox: View {
    @ObservedObject var teleprompter: TeleprompterController
    let axGranted: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Teleprompter", systemImage: "text.alignleft").font(.headline)
                    Spacer()
                    Toggle("Show on screen", isOn: Binding(
                        get: { teleprompter.isVisible },
                        set: { $0 ? teleprompter.show() : teleprompter.hide() }))
                        .toggleStyle(.switch)
                }
                Text("Crawls across the top of the recorded display. Only you see it — it's hidden from the recording.")
                    .font(.caption).foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $teleprompter.script)
                        .font(.system(size: 13))
                        .frame(height: 68)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(.textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    if teleprompter.script.isEmpty {
                        Text("Paste your script…")
                            .font(.system(size: 13)).foregroundStyle(.tertiary)
                            .padding(.leading, 9).padding(.top, 9).allowsHitTesting(false)
                    }
                }

                HStack(spacing: 12) {
                    Button { teleprompter.toggle() } label: {
                        Label(teleprompter.isPlaying ? "Pause" : "Play",
                              systemImage: teleprompter.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 86)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(teleprompter.line.isEmpty)
                    Button { teleprompter.restart() } label: {
                        Label("Restart", systemImage: "backward.end.fill")
                    }
                    Toggle("Loop", isOn: $teleprompter.loop).toggleStyle(.checkbox)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                    Slider(value: $teleprompter.speed, in: 30...400)
                    Image(systemName: "hare").foregroundStyle(.secondary)
                    Text("\(Int(teleprompter.speed)) pt/s")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("Size").font(.caption).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                    Slider(value: $teleprompter.fontSize, in: 22...72)
                    Text("\(Int(teleprompter.fontSize)) pt")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }

                Text(axGranted
                     ? "Hotkeys (work while another app is focused): ⌃⌥Space play/pause · ⌃⌥←/→ speed · ⌃⌥R restart"
                     : "Grant Accessibility (below) to control the teleprompter with global hotkeys while recording another app.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(6)
        }
    }
}
