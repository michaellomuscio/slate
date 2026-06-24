import Foundation
import CoreGraphics

/// `layout.json` — the contract for how the camera ("head") is composited over the screen in a
/// Loom-style walkthrough. The interactive Compose UI writes it; the native exporter
/// (`WalkthroughExporter`) reads it; `render.py` can read the SAME file later — so the in-app
/// one-click path and the Claude-edited pipeline never diverge. The artifact is the contract,
/// exactly like the take bundle itself.
///
/// All geometry is FRACTIONAL relative to the output canvas (0…1), so one layout renders
/// correctly at any resolution and — later — any aspect ratio. Coordinates use the SwiftUI /
/// screen convention: origin top-left, y increases downward. (The exporter is the one place
/// that flips into Core Image's bottom-left space.)
struct WalkthroughLayout: Codable, Equatable {

    enum Shape: String, Codable, CaseIterable, Identifiable {
        case circle, roundedSquare, roundedRect, rectangle
        var id: String { rawValue }
        var label: String {
            switch self {
            case .circle:        return "Circle"
            case .roundedSquare: return "Rounded square"
            case .roundedRect:   return "Rounded rectangle"
            case .rectangle:     return "Rectangle"
            }
        }
        var symbol: String {
            switch self {
            case .circle:        return "circle"
            case .roundedSquare: return "square"
            case .roundedRect:   return "rectangle"
            case .rectangle:     return "rectangle.fill"
            }
        }
        /// Square shapes crop the (usually 16:9) camera to 1:1; rectangular shapes keep its aspect.
        var isSquare: Bool { self == .circle || self == .roundedSquare }
    }

    var schemaVersion: Int = 1
    var cameraVisible: Bool = true
    var shape: Shape = .circle

    /// Bubble CENTER as a fraction of the canvas (top-left origin).
    var centerX: Double = 0.84
    var centerY: Double = 0.82
    /// Bubble WIDTH as a fraction of canvas width. Height is derived from `shape` + camera aspect.
    var widthFrac: Double = 0.22
    /// Corner radius as a fraction of the bubble's shorter side (rounded shapes only).
    var cornerRadiusFrac: Double = 0.20

    var border: Bool = true
    /// Border thickness as a fraction of the bubble width (so it scales with output resolution).
    var borderWidthFrac: Double = 0.018
    var borderColorHex: String = "#FFFFFF"

    var shadow: Bool = true
    /// Horizontally flip the camera (selfie-style). Most people expect their head mirrored.
    var mirror: Bool = true

    /// Output canvas aspect. "screen" = match the screen recording (MVP). Reserved: "16:9","9:16","1:1".
    var outputAspect: String = "screen"
    /// Letterbox fill when the output aspect differs from the screen aspect (future use).
    var backgroundHex: String = "#0B1F33"

    static let `default` = WalkthroughLayout()
}

// MARK: - Geometry (pure, resolution-independent)

extension WalkthroughLayout {
    /// Pixel size of the bubble on a given canvas, honoring shape + the camera's pixel aspect.
    func bubbleSize(canvas: CGSize, cameraAspect: CGFloat) -> CGSize {
        let w = max(8, CGFloat(widthFrac) * canvas.width)
        if shape.isSquare { return CGSize(width: w, height: w) }
        return CGSize(width: w, height: w / max(cameraAspect, 0.01))
    }

    /// Bubble frame (top-left origin) on a canvas, clamped so it stays fully on-canvas.
    func bubbleRect(canvas: CGSize, cameraAspect: CGFloat) -> CGRect {
        let size = bubbleSize(canvas: canvas, cameraAspect: cameraAspect)
        let cx = CGFloat(centerX) * canvas.width
        let cy = CGFloat(centerY) * canvas.height
        var x = cx - size.width / 2
        var y = cy - size.height / 2
        x = min(max(0, x), max(0, canvas.width  - size.width))
        y = min(max(0, y), max(0, canvas.height - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    func cornerRadius(for size: CGSize) -> CGFloat {
        switch shape {
        case .circle:
            return min(size.width, size.height) / 2
        case .roundedSquare, .roundedRect:
            return CGFloat(cornerRadiusFrac) * min(size.width, size.height)
        case .rectangle:
            return 0
        }
    }

    func borderWidthPx(canvas: CGSize) -> CGFloat {
        border ? CGFloat(borderWidthFrac) * canvas.width : 0
    }
}

// MARK: - Persistence (the contract on disk)

extension WalkthroughLayout {
    static func load(from bundle: TakeBundle) -> WalkthroughLayout? {
        guard let data = try? Data(contentsOf: bundle.layoutURL) else { return nil }
        return try? JSONDecoder().decode(WalkthroughLayout.self, from: data)
    }

    func write(to bundle: TakeBundle) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: bundle.layoutURL)
    }
}

extension TakeBundle {
    var layoutURL: URL { path.appendingPathComponent("layout.json") }
    /// The native Loom-style export, distinct from the pipeline's `final.mp4` so neither clobbers
    /// the other — a take can have both a Claude-edited cut and a one-click walkthrough.
    var walkthroughURL: URL { path.appendingPathComponent("walkthrough.mp4") }
    var hasWalkthrough: Bool { FileManager.default.fileExists(atPath: walkthroughURL.path) }
}

// MARK: - Hex color (shared by the SwiftUI preview and the Core Image exporter)

extension CGColor {
    /// Parse "#RGB", "#RRGGBB", or "#RRGGBBAA" into an sRGB color. Returns nil on malformed input.
    static func fromHex(_ hex: String) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }   // RGB → RRGGBB
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >>  8) & 0xFF) / 255
            a = Double( v        & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >>  8) & 0xFF) / 255
            b = Double( v        & 0xFF) / 255
            a = 1
        }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
