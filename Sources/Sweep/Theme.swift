import SwiftUI

/// Colours and shared building blocks from the approved mockup.
enum Theme {
    static let window = Color(hex: 0x121318)
    static let panel = Color(hex: 0x1B1C23)
    static let footer = Color(hex: 0x16171D)
    static let surface = Color(hex: 0x24252E)
    static let border = Color(hex: 0x2C2D37)
    static let divider = Color(hex: 0x24252E)
    static let track = Color(hex: 0x33343F)
    static let selection = Color(hex: 0x2F3A5C)
    static let selectionSubtle = Color(hex: 0x1C2236)

    static let text = Color(hex: 0xF2F2F5)
    static let secondaryText = Color(hex: 0xC9CAD3)
    static let mutedText = Color(hex: 0xA9AAB6)
    static let faintText = Color(hex: 0x9A9BA8)

    static let accent = Color(hex: 0x5B8CFF)
    static let accentText = Color(hex: 0x8FB0FF)
    static let protection = Color(hex: 0xFFB066)
    static let speed = Color(hex: 0x5FE0A8)
    static let danger = Color(hex: 0xFF8A65)
    static let lavender = Color(hex: 0xB48CFF)

    /// Text colour that reads well on top of a bright accent fill.
    static let onAccent = Color(hex: 0x0B1020)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: Buttons

/// The rounded pill used for every main action.
struct PillButtonStyle: ButtonStyle {
    var fill: Color = Theme.accent
    var foreground: Color = Theme.onAccent
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, fill: fill, foreground: foreground, height: height)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let fill: Color
        let foreground: Color
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 15, weight: .bold))
                .padding(.horizontal, 30)
                .frame(height: height)
                .foregroundStyle(foreground)
                .background(Capsule().fill(fill))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .contentShape(Capsule())
        }
    }
}

/// An outlined pill for secondary actions such as "Reveal in Finder".
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 20)
            .frame(height: 44)
            .foregroundStyle(Theme.secondaryText)
            .background(Capsule().strokeBorder(Color(hex: 0x3A3B47)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// A plain text link in the accent colour.
struct LinkButtonStyle: ButtonStyle {
    var color: Color = Theme.accentText
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: Layout pieces

extension View {
    /// The bordered card used for panels and summaries.
    func card(radius: CGFloat = 12) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.border))
    }
}

/// Title and subtitle at the top of each screen.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 22, weight: .bold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.mutedText)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The bar pinned to the bottom of a screen with a summary and the main action.
struct FooterBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack { content }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(Theme.footer)
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

/// A square tile with a tinted background and an SF Symbol, as in the summary cards.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(tint.opacity(0.16))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(tint))
            .accessibilityHidden(true)
    }
}

/// A thin horizontal usage bar.
struct UsageBar: View {
    let fraction: Double
    var tint: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(tint).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityValue(Text("\(Int(fraction * 100)) percent"))
    }
}

/// Column header text for tables ("NAME", "SIZE").
struct ColumnLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Theme.faintText)
    }
}

/// Centered message for empty or loading states.
struct StatusMessage: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var showsProgress = false

    var body: some View {
        VStack(spacing: 12) {
            if showsProgress {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(Theme.faintText)
            }
            Text(title).font(.system(size: 16, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A checkbox that matches the mockup's blue tick boxes.
struct CheckBox: View {
    @Binding var isOn: Bool
    var tint: Color = Theme.accent
    var label: String

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.checkbox)
            .labelsHidden()
            .tint(tint)
    }
}
