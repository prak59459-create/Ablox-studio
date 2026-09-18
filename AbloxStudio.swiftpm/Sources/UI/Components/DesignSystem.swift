import SwiftUI
import AbloxCore

/// Shared visual language: one place to change the look, rather than the same
/// gradient pasted into nine views.
public enum Ablox {

    public enum Palette {
        public static let accent = Color(red: 0.13, green: 0.83, blue: 0.93)     // cyan
        public static let accentDeep = Color(red: 0.23, green: 0.51, blue: 0.96) // blue
        public static let magenta = Color(red: 0.66, green: 0.33, blue: 0.97)
        public static let success = Color(red: 0.29, green: 0.87, blue: 0.50)
        public static let warning = Color(red: 1.00, green: 0.62, blue: 0.11)
        public static let danger = Color(red: 1.00, green: 0.35, blue: 0.37)

        public static let ink = Color.white
        public static let inkMuted = Color.white.opacity(0.62)
        public static let inkFaint = Color.white.opacity(0.38)

        public static let brand = LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public enum Metrics {
        public static let cardRadius: CGFloat = 20
        public static let controlRadius: CGFloat = 14
        public static let sidebarWidth: CGFloat = 264
        public static let gutter: CGFloat = 28
        /// Minimum tappable size. 44pt is Apple's guidance, and this app is
        /// aimed at children with imprecise aim, so controls go bigger where
        /// there is room.
        public static let minimumTapTarget: CGFloat = 44
    }
}

// MARK: - Dynamic background

/// Slow-drifting aurora blobs behind everything.
///
/// Two large blurred circles rather than a particle system or a shader: it
/// costs almost nothing, and it keeps rendering budget for the 3D viewport
/// that shares the screen.
public struct DynamicBackgroundView: View {
    @State private var animate = false
    /// Respect the system setting — a permanently drifting background is
    /// exactly what Reduce Motion exists to switch off.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.04, blue: 0.09).ignoresSafeArea()

            Circle()
                .fill(Ablox.Palette.magenta.opacity(0.30))
                .frame(width: 520, height: 520)
                .blur(radius: 96)
                .offset(x: animate ? -160 : 150, y: animate ? -210 : 110)

            Circle()
                .fill(Ablox.Palette.accent.opacity(0.24))
                .frame(width: 420, height: 420)
                .blur(radius: 84)
                .offset(x: animate ? 190 : -110, y: animate ? 160 : -150)

            Circle()
                .fill(Ablox.Palette.accentDeep.opacity(0.18))
                .frame(width: 360, height: 360)
                .blur(radius: 78)
                .offset(x: animate ? -60 : 120, y: animate ? 220 : -60)
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

// MARK: - Glass card

public struct GlassCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    public init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Ablox.Metrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Ablox.Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
    }
}

// MARK: - Buttons

public struct NeonButtonStyle: ButtonStyle {
    public enum Prominence {
        case primary
        case secondary
        case destructive
    }

    private let prominence: Prominence
    private let fullWidth: Bool

    public init(_ prominence: Prominence = .primary, fullWidth: Bool = false) {
        self.prominence = prominence
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: Ablox.Metrics.minimumTapTarget)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(borderColor, lineWidth: prominence == .secondary ? 1 : 0)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }

    @ViewBuilder private var background: some View {
        switch prominence {
        case .primary: Ablox.Palette.brand
        case .secondary: Color.white.opacity(0.06)
        case .destructive: Ablox.Palette.danger
        }
    }

    private var foreground: Color {
        switch prominence {
        case .primary: return .black
        case .secondary: return .white
        case .destructive: return .white
        }
    }

    private var borderColor: Color {
        prominence == .secondary ? Color.white.opacity(0.18) : .clear
    }
}

public extension ButtonStyle where Self == NeonButtonStyle {
    static var neon: NeonButtonStyle { NeonButtonStyle(.primary) }
    static var neonSecondary: NeonButtonStyle { NeonButtonStyle(.secondary) }
    static var neonDestructive: NeonButtonStyle { NeonButtonStyle(.destructive) }
}

// MARK: - Badge

public struct Badge: View {
    private let text: String
    private let color: Color
    private let systemImage: String?

    public init(_ text: String, color: Color = Ablox.Palette.accent, systemImage: String? = nil) {
        self.text = text
        self.color = color
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.18)))
        .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
        .foregroundStyle(color)
    }
}

// MARK: - Section header

public struct SectionHeader: View {
    private let title: String
    private let systemImage: String
    private let trailing: AnyView?

    public init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = nil
    }

    public init<Trailing: View>(_ title: String, systemImage: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = AnyView(trailing())
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Ablox.Palette.accent)
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Ablox.Palette.ink)
            Spacer()
            trailing
        }
    }
}

// MARK: - Empty state

public struct EmptyStateView: View {
    private let title: String
    private let message: String
    private let systemImage: String

    public init(title: String, message: String, systemImage: String) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(Ablox.Palette.inkFaint)
            Text(title)
                .font(.headline)
                .foregroundStyle(Ablox.Palette.ink)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Ablox.Palette.inkMuted)
        }
        .frame(maxWidth: 360)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Colour swatch

public struct ColorSwatch: View {
    private let color: ColorRGBA
    private let isSelected: Bool
    private let size: CGFloat
    private let action: () -> Void

    public init(color: ColorRGBA, isSelected: Bool, size: CGFloat = 40, action: @escaping () -> Void) {
        self.color = color
        self.isSelected = isSelected
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(color))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.15), lineWidth: isSelected ? 2.5 : 1)
                )
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.black))
                        // Contrast against the swatch itself, so a checkmark
                        // on pale yellow is still legible.
                        .foregroundStyle(color.luminance > 0.6 ? .black : .white)
                        .opacity(isSelected ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(color.hexString))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
