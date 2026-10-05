import SwiftUI
import AbloxCore

/// Shared visual language: one place to change the look, rather than the same
/// gradient pasted into nine views.
public enum Ablox {

    public enum Palette {
        /// The player's chosen colour (Settings → Look), cyan to begin with.
        public static var accent: Color { AbloxAccent.current.color }
        public static var accentDeep: Color { AbloxAccent.current.deep }
        public static let magenta = Color(red: 0.66, green: 0.33, blue: 0.97)
        public static let success = Color(red: 0.29, green: 0.87, blue: 0.50)
        public static let warning = Color(red: 1.00, green: 0.62, blue: 0.11)
        public static let danger = Color(red: 1.00, green: 0.35, blue: 0.37)

        // Text and lines follow light or dark mode.
        public static let ink = dynamic(dark: UIColor.white, light: UIColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1))
        public static let inkMuted = dynamic(dark: UIColor(white: 1, alpha: 0.62), light: UIColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 0.68))
        public static let inkFaint = dynamic(dark: UIColor(white: 1, alpha: 0.38), light: UIColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 0.45))
        /// Behind everything.
        public static let background = dynamic(dark: UIColor(red: 0.03, green: 0.04, blue: 0.09, alpha: 1),
                                               light: UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1))
        /// Behind a sheet's contents.
        public static let surface = dynamic(dark: UIColor(red: 0.05, green: 0.06, blue: 0.11, alpha: 1),
                                            light: UIColor(red: 0.97, green: 0.98, blue: 1, alpha: 1))
        /// Card edges and dividers.
        public static let line = dynamic(dark: UIColor(white: 1, alpha: 0.09), light: UIColor(white: 0, alpha: 0.10))
        public static let lineStrong = dynamic(dark: UIColor(white: 1, alpha: 0.18), light: UIColor(white: 0, alpha: 0.16))
        /// A faint fill behind a row or a quiet button.
        public static let wash = dynamic(dark: UIColor(white: 1, alpha: 0.06), light: UIColor(white: 0, alpha: 0.05))

        public static var brand: LinearGradient {
            LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
        }

        private static func dynamic(dark: UIColor, light: UIColor) -> Color {
            Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .light ? light : dark })
        }
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

// MARK: - Themes

/// The colour buttons, highlights and the background glow are drawn in.
public enum AbloxAccent: String, CaseIterable, Identifiable, Sendable {
    case cyan, pink, lime, orange, violet

    public var id: String { rawValue }
    public static let key = "ablox.accent"

    // A plain `static var` and a lock, like `Localization.language`.
    private static let lock = NSLock()
    private static var _current: AbloxAccent?

    /// Read on every draw, so kept in memory after the first look.
    public static var current: AbloxAccent {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let _current { return _current }
            let stored = AbloxAccent(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .cyan
            _current = stored
            return stored
        }
        set {
            lock.lock()
            _current = newValue
            lock.unlock()
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }

    public var color: Color {
        switch self {
        case .cyan: return Color(red: 0.13, green: 0.83, blue: 0.93)
        case .pink: return Color(red: 0.98, green: 0.45, blue: 0.71)
        case .lime: return Color(red: 0.52, green: 0.86, blue: 0.25)
        case .orange: return Color(red: 1.0, green: 0.62, blue: 0.2)
        case .violet: return Color(red: 0.65, green: 0.52, blue: 1.0)
        }
    }

    public var deep: Color {
        switch self {
        case .cyan: return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .pink: return Color(red: 0.86, green: 0.25, blue: 0.62)
        case .lime: return Color(red: 0.13, green: 0.64, blue: 0.4)
        case .orange: return Color(red: 0.93, green: 0.35, blue: 0.2)
        case .violet: return Color(red: 0.45, green: 0.3, blue: 0.93)
        }
    }

    public var displayName: String {
        switch self {
        case .cyan: return L("Cyan")
        case .pink: return L("Pink")
        case .lime: return L("Lime")
        case .orange: return L("Orange")
        case .violet: return L("Violet")
        }
    }
}

/// Dark, light, or whatever the iPad is set to.
public enum AbloxAppearance: String, CaseIterable, Identifiable, Sendable {
    case dark, light, system

    public var id: String { rawValue }
    public static let key = "ablox.appearance"

    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .dark: return L("Dark")
        case .light: return L("Light")
        case .system: return L("Match the iPad")
        }
    }
}

private struct AbloxColorSchemeModifier: ViewModifier {
    @AppStorage(AbloxAppearance.key) private var appearance = AbloxAppearance.dark.rawValue

    func body(content: Content) -> some View {
        content.preferredColorScheme((AbloxAppearance(rawValue: appearance) ?? .dark).colorScheme)
    }
}

public extension View {
    /// Dark or light, as chosen in Settings → Look. The game itself is
    /// always dark.
    func abloxColorScheme() -> some View {
        modifier(AbloxColorSchemeModifier())
    }
}

// MARK: - Icons

public extension Image {
    /// Renders an icon from the Ablox vocabulary.
    ///
    /// Views ask for `Image(icon: .trophy)` rather than
    /// `Image(systemName: "trophy.fill")`, so the symbol a given icon resolves
    /// to is decided in exactly one place. Swapping in custom artwork later is
    /// a change to `AbloxIcon.symbolName`, not a sweep through the UI.
    init(icon: AbloxIcon) {
        self.init(systemName: icon.symbolName)
    }
}

public extension Label where Title == Text, Icon == Image {
    init(_ title: String, icon: AbloxIcon) {
        self.init(title, systemImage: icon.symbolName)
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
            Ablox.Palette.background.ignoresSafeArea()

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
                    .strokeBorder(Ablox.Palette.line, lineWidth: 1)
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
        case .secondary: Ablox.Palette.wash
        case .destructive: Ablox.Palette.danger
        }
    }

    private var foreground: Color {
        switch prominence {
        case .primary: return .black
        case .secondary: return Ablox.Palette.ink
        case .destructive: return .white
        }
    }

    private var borderColor: Color {
        prominence == .secondary ? Ablox.Palette.lineStrong : .clear
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
                .accessibilityAddTraits(.isHeader)
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
                        .strokeBorder(isSelected ? Ablox.Palette.ink : Ablox.Palette.lineStrong, lineWidth: isSelected ? 2.5 : 1)
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
        .accessibilityLabel(Text(color.spokenName))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
