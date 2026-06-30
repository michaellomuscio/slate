import SwiftUI

/// Top-level **Compose** tab: pick a take, position your camera "head" over the screen, export a
/// Loom-style walkthrough. Same picker shell as EditView; hosts the unchanged ComposeView.
struct ComposeTab: View {
    @State private var bundles: [TakeBundle] = []
    @State private var selectedID: TakeBundle.ID? = nil
    private var selected: TakeBundle? { bundles.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.rectangle").foregroundStyle(Color.accentColor)
                Text("Compose").font(.headline)
                if bundles.isEmpty {
                    Text("— no takes yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $selectedID) {
                        ForEach(bundles) { b in Text(b.id).tag(Optional(b.id)) }
                    }.labelsHidden().frame(maxWidth: 320)
                }
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan ~/Movies/Slate")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if let b = selected {
                ComposeView(bundle: b).id(b.id)   // .id ⇒ fresh players per take, teardown on disappear
            } else {
                ContentUnavailableView("Pick a take to compose", systemImage: "person.crop.rectangle",
                    description: Text("Drop your camera bubble over the screen and export a walkthrough."))
            }
        }
        .task { reload() }
    }

    private func reload() {
        bundles = TakeBundle.loadAll()
        if selectedID == nil || !bundles.contains(where: { $0.id == selectedID }) {
            selectedID = bundles.first?.id
        }
    }
}
