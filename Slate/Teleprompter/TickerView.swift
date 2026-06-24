import SwiftUI

/// The single-line crawl rendered inside the teleprompter panel. Reads transport state from
/// the controller and positions the text at `panelWidth - offset` so it slides right-to-left.
/// The controller's 60 Hz timer advances `offset`; this view just draws the current frame.
struct TickerView: View {
    @ObservedObject var controller: TeleprompterController

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Readable dark strip so white text holds up over any app underneath.
                Rectangle().fill(Color.black.opacity(0.62))

                if controller.line.isEmpty {
                    Text("Paste a script in Slate, then press Play — it crawls here, hidden from the recording.")
                        .font(.system(size: min(controller.fontSize, 22), weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 24)
                } else {
                    Text(controller.line)
                        .font(.system(size: controller.fontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .shadow(color: .black.opacity(0.75), radius: 3, x: 0, y: 1)
                        .background(
                            GeometryReader { tg in
                                Color.clear.preference(key: TickerWidthKey.self, value: tg.size.width)
                            }
                        )
                        // `.position` sets the center; left edge sits at (panelWidth - offset).
                        .position(x: geo.size.width - controller.offset + controller.contentWidth / 2,
                                  y: geo.size.height / 2)
                        .opacity(controller.contentWidth > 0 ? 1 : 0)   // hide the pre-measurement frame
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.accentColor).frame(height: 2)   // Lomuscio Labs accent
            }
            .onPreferenceChange(TickerWidthKey.self) { w in
                if w != controller.contentWidth { controller.contentWidth = w }
            }
        }
        .ignoresSafeArea()
    }
}

private struct TickerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
