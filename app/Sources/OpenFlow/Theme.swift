import AppKit
import SwiftUI

/// OpenFlow's look in one place: ink and paper surfaces, one ember accent, New York for headlines.
/// The mark is three voice bars that end in a line of text: speech becomes writing.
enum Brand {
    static let ember = Color(red: 1.0, green: 0.36, blue: 0.22)        // #FF5C38: accent, You, recording
    static let tide = Color(red: 0.17, green: 0.66, blue: 0.61)        // #2BA89C: Them
    static let ok = Color(red: 0.2, green: 0.64, blue: 0.42)
    static let warn = Color(red: 0.88, green: 0.6, blue: 0.04)
    static let ink = Color(red: 0.071, green: 0.075, blue: 0.094)      // #121318
    static let paper = Color(red: 0.965, green: 0.957, blue: 0.937)    // #F6F4EF

    /// Ember for text on light backgrounds, where the bright one is too faint.
    static let emberText = dynamic(light: .init(srgbRed: 0.85, green: 0.27, blue: 0.13, alpha: 1),
                                   dark: .init(srgbRed: 1.0, green: 0.45, blue: 0.32, alpha: 1))
    static let canvas = dynamic(light: .init(srgbRed: 0.965, green: 0.957, blue: 0.937, alpha: 1),
                                dark: .init(srgbRed: 0.086, green: 0.09, blue: 0.11, alpha: 1))
    static let sidebar = dynamic(light: .init(srgbRed: 0.925, green: 0.914, blue: 0.886, alpha: 1),
                                 dark: .init(srgbRed: 0.063, green: 0.067, blue: 0.082, alpha: 1))
    static let surface = dynamic(light: .white, dark: .init(srgbRed: 0.125, green: 0.129, blue: 0.153, alpha: 1))
    /// Inset fields and keycaps on a surface.
    static let well = dynamic(light: .init(srgbRed: 0.945, green: 0.937, blue: 0.918, alpha: 1),
                              dark: .init(srgbRed: 0.165, green: 0.169, blue: 0.196, alpha: 1))
    static let hairline = dynamic(light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.08))

    static let nsCanvas = NSColor(name: nil) { isDark($0) ? NSColor(srgbRed: 0.086, green: 0.09, blue: 0.11, alpha: 1)
        : NSColor(srgbRed: 0.965, green: 0.957, blue: 0.937, alpha: 1) }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { isDark($0) ? dark : light })
    }

    private static func isDark(_ a: NSAppearance) -> Bool { a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Font {
    /// Headlines: New York, so the app reads like a writing tool rather than a utility.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - The mark

/// The mark's geometry on a unit width (height 0.81): bars, then the line of text.
enum MarkGeometry {
    static let barWidth: CGFloat = 0.1345
    static let gap: CGFloat = 0.0793
    static let heights: [CGFloat] = [0.517, 0.81, 0.397]
    static let aspect: CGFloat = 0.81

    static func rects(in r: CGRect) -> (bars: [CGRect], line: CGRect) {
        let u = min(r.width, r.height / aspect)
        let x0 = r.midX - u / 2, cy = r.midY, w = barWidth * u
        var bars: [CGRect] = []
        var x = x0
        for h in heights {
            bars.append(CGRect(x: x, y: cy - h * u / 2, width: w, height: h * u))
            x += w + gap * u
        }
        return (bars, CGRect(x: x, y: cy - w / 2, width: x0 + u - x, height: w))
    }
}

struct BrandMark: View {
    var bars: Color = Brand.ember
    var line: Color = .primary

    var body: some View {
        Canvas { ctx, size in
            let g = MarkGeometry.rects(in: CGRect(origin: .zero, size: size))
            for b in g.bars { ctx.fill(Capsule().path(in: b), with: .color(bars)) }
            ctx.fill(Capsule().path(in: g.line), with: .color(line))
        }
        .aspectRatio(1 / MarkGeometry.aspect, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct Wordmark: View {
    var size: CGFloat = 17

    var body: some View {
        HStack(spacing: size * 0.45) {
            BrandMark().frame(height: size * 0.85)
            Text("OpenFlow").font(.display(size)).kerning(-0.2)
        }
    }
}

// MARK: - Layout pieces

/// A page's headline and the one sentence that says what it's for.
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.display(28)).kerning(-0.3)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A group of settings: a small label above a card whose rows are separated by hairlines.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    var footerStyle: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 11, weight: .semibold)).kerning(0.6).textCase(.uppercase)
                    .foregroundStyle(.secondary).padding(.leading, 4)
            }
            Card {
                Group(subviews: content) { rows in
                    VStack(spacing: 0) {
                        ForEach(rows.indices, id: \.self) { i in
                            rows[i]
                            if i < rows.count - 1 { Hairline().padding(.leading, 16) }
                        }
                    }
                }
            }
            if let footer {
                Text(footer).font(.system(size: 11.5))
                    .foregroundStyle(footerStyle.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline))
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Brand.hairline).frame(height: 1) }
}

/// One setting: what it is (and what it does) on the left, the control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 46)
    }
}

/// A key as it's printed on the keyboard: "right ⌥", "Esc", "⌃⌥T".
struct KeyCap: View {
    let text: String
    var dark = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .foregroundStyle(dark ? AnyShapeStyle(Brand.paper) : AnyShapeStyle(.primary))
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dark ? AnyShapeStyle(.white.opacity(0.1)) : AnyShapeStyle(Brand.well)))
            .overlay(alignment: .bottom) {
                // the key's lower edge
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(dark ? Color.white.opacity(0.14) : Brand.hairline)
            }
            .fixedSize()
    }
}

/// A coloured dot with a short state: "Ready", "Starting…".
struct StatusBadge: View {
    enum Tone { case ok, busy, warn }
    let tone: Tone
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .overlay(Circle().stroke(color.opacity(0.3), lineWidth: 3))
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch tone {
        case .ok: return Brand.ok
        case .busy: return Brand.warn
        case .warn: return Brand.ember
        }
    }
}

// MARK: - Buttons

/// The one thing to do on a screen: an ember capsule.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Capsule().fill(Brand.ember.opacity(configuration.isPressed ? 0.8 : 1)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// Everything else: a quiet capsule on the surface.
struct QuietButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 24 : 30)
            .background(Capsule().fill(Brand.well.opacity(configuration.isPressed ? 0.6 : 1)))
            .overlay(Capsule().strokeBorder(Brand.hairline))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
    static var quietSmall: QuietButtonStyle { QuietButtonStyle(compact: true) }
}

/// A text field drawn as a well, matching the cards.
struct WellFieldStyle: TextFieldStyle {
    var icon: String?

    func _body(configuration: TextField<Self._Label>) -> some View {
        HStack(spacing: 7) {
            if let icon { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.tertiary) }
            configuration.textFieldStyle(.plain).font(.system(size: 13))
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Brand.hairline))
    }
}

/// An SF Symbol in a soft ember circle, for feature lists and permissions.
struct IconBadge: View {
    let symbol: String
    var size: CGFloat = 30
    var tint: Color = Brand.ember

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(0.12)))
    }
}

/// Picks a button style at runtime (e.g. primary until something is set up, then quiet).
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
