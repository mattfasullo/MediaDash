import SwiftUI

// MARK: - Win98 Color Palette

/// All canonical Windows 98 UI colors, matching the HTML mockup exactly.
struct Win98Colors {
    // Base chrome
    static let background     = Color(red: 0.753, green: 0.753, blue: 0.753) // #C0C0C0
    static let white          = Color.white
    static let lightHighlight = Color(red: 0.875, green: 0.875, blue: 0.875) // #DFDFDF
    static let midGray        = Color(red: 0.502, green: 0.502, blue: 0.502) // #808080
    static let darkShadow     = Color(red: 0.251, green: 0.251, blue: 0.251) // #404040
    static let black          = Color.black

    // Title bar gradient (active window)
    static let titleBarFrom   = Color(red: 0.000, green: 0.000, blue: 0.502) // #000080
    static let titleBarTo     = Color(red: 0.063, green: 0.518, blue: 0.816) // #1084D0

    // Selection highlight
    static let selectionBg    = Color(red: 0.000, green: 0.000, blue: 0.502) // #000080
    static let selectionText  = Color.white

    // Desktop teal (used for sidebar in Win98 mode)
    static let desktopTeal    = Color(red: 0.000, green: 0.502, blue: 0.502) // #008080

    // Action button tints — muted, desaturated Win98 palette matching the HTML mockup
    static let buttonFile     = Color(red: 0.376, green: 0.502, blue: 0.627) // #607ca0 (slate blue)
    static let buttonSimian   = Color(red: 0.502, green: 0.439, blue: 0.251) // #807040 (tan)
    static let buttonCalendar = Color(red: 0.251, green: 0.376, blue: 0.251) // #406040 (forest green)
    static let buttonVideo    = Color(red: 0.502, green: 0.251, blue: 0.251) // #804040 (muted red)
    static let buttonBoth     = Color(red: 0.251, green: 0.376, blue: 0.376) // #406060 (teal-gray)
}

// MARK: - Win98 Bevel Overlay

/// Draws the classic Windows 98 4-sided 3D bevel border using SwiftUI Canvas.
/// The bevel has two layers: an outer 2px ring and an inner 1px ring,
/// each with light top+left and dark bottom+right.
///
/// Raised (button/panel):  outer white/dark, inner lightGray/midGray
/// Sunken (input/pressed): outer dark/white, inner midGray/lightGray
struct Win98BevelOverlay: View {
    enum Style { case raised, sunken }
    let style: Style

    private var outerLight: Color { style == .raised ? Win98Colors.white        : Win98Colors.darkShadow }
    private var outerDark:  Color { style == .raised ? Win98Colors.darkShadow   : Win98Colors.white      }
    private var innerLight: Color { style == .raised ? Win98Colors.lightHighlight : Win98Colors.midGray  }
    private var innerDark:  Color { style == .raised ? Win98Colors.midGray      : Win98Colors.lightHighlight }

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            func fill(_ rect: CGRect, _ color: Color) {
                context.fill(Path(rect), with: .color(color))
            }

            // ── Outer ring (2 px) ──────────────────────────────────
            fill(CGRect(x: 0,     y: 0,     width: w,  height: 2),  outerLight) // top
            fill(CGRect(x: 0,     y: 0,     width: 2,  height: h),  outerLight) // left
            fill(CGRect(x: 0,     y: h - 2, width: w,  height: 2),  outerDark)  // bottom
            fill(CGRect(x: w - 2, y: 0,     width: 2,  height: h),  outerDark)  // right

            // ── Inner ring (1 px at offset 2) ─────────────────────
            fill(CGRect(x: 2,     y: 2,     width: w - 4, height: 1), innerLight) // top
            fill(CGRect(x: 2,     y: 2,     width: 1, height: h - 4), innerLight) // left
            fill(CGRect(x: 2,     y: h - 3, width: w - 4, height: 1), innerDark)  // bottom
            fill(CGRect(x: w - 3, y: 2,     width: 1, height: h - 4), innerDark)  // right
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Win98 Title Bar

/// The classic Win98 window title bar: left-to-right dark blue gradient with white bold text.
struct Win98TitleBar: View {
    let title: String
    let icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Text(icon)
                    .font(.system(size: 11))
            }
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            LinearGradient(
                colors: [Win98Colors.titleBarFrom, Win98Colors.titleBarTo],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .frame(height: 20)
    }
}

// MARK: - Win98 Button Style

/// Standard Win98 dialog/toolbar button: gray background, raised bevel, black text.
/// Pressing flips to sunken bevel for tactile feedback.
struct Win98ButtonStyle: ButtonStyle {
    var minWidth: CGFloat = 75

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundColor(Win98Colors.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minWidth: minWidth)
            .background(Win98Colors.background)
            .overlay(
                Win98BevelOverlay(style: configuration.isPressed ? .sunken : .raised)
            )
            // Subtle offset when pressed to reinforce the "click" feel
            .offset(x: configuration.isPressed ? 1 : 0,
                    y: configuration.isPressed ? 1 : 0)
    }
}

// MARK: - Win98 Action Button Overlay
//
// Applied as an overlay on the existing colored action buttons (File / Simian / etc.)
// to add the 4-sided Win98 bevel border.

struct Win98ActionBevelOverlay: View {
    let isPressed: Bool

    var body: some View {
        Win98BevelOverlay(style: isPressed ? .sunken : .raised)
    }
}

// MARK: - View Modifiers / Extensions

extension View {
    /// Wraps the view in a Win98-style raised bevel border with a gray background.
    func win98Raised() -> some View {
        self
            .background(Win98Colors.background)
            .overlay(Win98BevelOverlay(style: .raised))
    }

    /// Wraps the view in a Win98-style sunken bevel border with a white background.
    /// Suitable for text fields, list boxes, and inset panels.
    func win98Sunken() -> some View {
        self
            .background(Color.white)
            .overlay(Win98BevelOverlay(style: .sunken))
    }

    /// 1 px Win98 separator line (dark on top, light below).
    func win98Separator() -> some View {
        self.overlay(
            VStack(spacing: 0) {
                Spacer()
                Rectangle().fill(Win98Colors.midGray).frame(height: 1)
                Rectangle().fill(Win98Colors.white).frame(height: 1)
            }
        )
    }
}

// MARK: - Win98 Section Group Box

/// A labeled group box with the classic Win98 sunken border and
/// a gray background — for use in panels and settings sections.
struct Win98GroupBox<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Win98Colors.black)
                .padding(.leading, 8)
                .padding(.bottom, 4)

            // Bordered content area
            content
                .padding(8)
                .background(Win98Colors.background)
                .overlay(Win98BevelOverlay(style: .sunken))
        }
    }
}

// MARK: - Win98 List Item Row

/// A single row in a Win98 list box — selected state highlighted in dark blue.
struct Win98ListRow<Content: View>: View {
    let isSelected: Bool
    let content: Content

    init(isSelected: Bool = false, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Win98Colors.selectionBg : Color.clear)
            .foregroundColor(isSelected ? Win98Colors.selectionText : Win98Colors.black)
    }
}

// MARK: - Win98 Progress Bar

/// Windows 98 style progress bar: segmented dark blue blocks on white.
struct Win98ProgressBar: View {
    let progress: Double // 0.0–1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Sunken track
                Win98Colors.white
                    .overlay(Win98BevelOverlay(style: .sunken))

                // Segmented fill
                Canvas { context, size in
                    let fillWidth = size.width * CGFloat(max(0, min(1, progress)))
                    let segWidth: CGFloat = 8
                    let segGap: CGFloat = 2
                    var x: CGFloat = 2

                    while x + segWidth <= fillWidth {
                        context.fill(
                            Path(CGRect(x: x, y: 2,
                                        width: segWidth,
                                        height: size.height - 4)),
                            with: .color(Win98Colors.titleBarFrom)
                        )
                        x += segWidth + segGap
                    }
                }
            }
        }
        .frame(height: 16)
    }
}
