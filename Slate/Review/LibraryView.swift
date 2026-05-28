import SwiftUI

/// Sidebar of all takes in `~/Movies/Slate/`; selecting one opens the review pane.
struct LibraryView: View {
    @State private var bundles: [TakeBundle] = []
    @State private var selectedID: TakeBundle.ID? = nil

    var body: some View {
        NavigationSplitView {
            List(bundles, selection: $selectedID) { b in
                row(b).tag(b.id)
            }
            .listStyle(.sidebar)
            .navigationTitle("Takes")
            .toolbar {
                ToolbarItem {
                    Button {
                        bundles = TakeBundle.loadAll()
                    } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan ~/Movies/Slate")
                }
            }
            .frame(minWidth: 240)
        } detail: {
            if let id = selectedID, let b = bundles.first(where: { $0.id == id }) {
                ReviewView(bundle: b)
            } else {
                ContentUnavailableView(
                    "Pick a take to review",
                    systemImage: "play.rectangle",
                    description: Text("Recordings appear here as you make them. "
                                      + "Run `/slate-ingest` from Claude Code to get captions.")
                )
            }
        }
        .task { bundles = TakeBundle.loadAll() }
    }

    @ViewBuilder
    private func row(_ b: TakeBundle) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(b.id).font(.headline).lineLimit(1)
            HStack(spacing: 8) {
                if b.hasTranscript { tag("transcript", .green) }
                if b.hasFinalRender { tag("rendered", .accentColor) }
                Spacer(minLength: 0)
                if let d = b.createdAtDate {
                    Text(d.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    private func tag(_ s: String, _ color: Color) -> some View {
        Text(s)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
