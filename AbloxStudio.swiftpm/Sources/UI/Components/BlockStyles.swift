import SwiftUI
import AbloxCore

// "Ablox Blocks": the look of the new menus. Buttons are chunky blocks that
// sit on their own shadow and press down into it; cards are glass with a
// solid edge underneath; every tap can make a small sound. The same look as
// the browser version (web/src/app/next.css), so the two feel like one app.

/// A raised block: a colour on top, its darker edge below, pressed down when touched.
public struct BlockButtonStyle: ButtonStyle {
    public enum Tint {
        case blue, green, gold, pink, plain, danger

        var top: Color {
            switch self {
            case .blue: return Color(red: 0.31, green: 0.56, blue: 0.97)
            case .green: return Color(red: 0.43, green: 0.91, blue: 0.60)
            case .gold: return Color(red: 1.0, green: 0.85, blue: 0.42)
            case .pink: return Color(red: 0.98, green: 0.66, blue: 0.83)
            case .plain: return Color.white.opacity(0.16)
            case .danger: return Color(red: 1.0, green: 0.48, blue: 0.49)
            }
        }

        var bottom: Color {
            switch self {
            case .blue: return Color(red: 0.23, green: 0.51, blue: 0.96)
            case .green: return Color(red: 0.13, green: 0.77, blue: 0.37)
            case .gold: return Color(red: 1.0, green: 0.79, blue: 0.24)
            case .pink: return Color(red: 0.96, green: 0.45, blue: 0.71)
            case .plain: return Color.white.opacity(0.09)
            case .danger: return Color(red: 1.0, green: 0.35, blue: 0.37)
            }
        }

        var edge: Color {
            switch self {
            case .blue: return Color(red: 0.11, green: 0.31, blue: 0.72)
            case .green: return Color(red: 0.08, green: 0.50, blue: 0.24)
            case .gold: return Color(red: 0.77, green: 0.54, blue: 0.0)
            case .pink: return Color(red: 0.75, green: 0.09, blue: 0.36)
            case .plain: return Color.black.opacity(0.35)
            case .danger: return Color(red: 0.70, green: 0.15, blue: 0.17)
            }
        }

        var ink: Color {
            switch self {
            case .green: return Color(red: 0.02, green: 0.19, blue: 0.06)
            case .gold: return Color(red: 0.23, green: 0.14, blue: 0.0)
            case .pink: return Color(red: 0.29, green: 0.04, blue: 0.17)
            default: return .white
            }
        }
    }

    private let tint: Tint
    private let fullWidth: Bool
    private let big: Bool

    public init(_ tint: Tint = .blue, fullWidth: Bool = false, big: Bool = false) {
        self.tint = tint
        self.fullWidth = fullWidth
        self.big = big
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let depth: CGFloat = big ? 5 : 4
        let shape = RoundedRectangle(cornerRadius: big ? 18 : 15, style: .continuous)
        return configuration.label
            .font(.system(size: big ? 20 : 16, weight: .heavy, design: .rounded))
            .foregroundStyle(tint.ink)
            .padding(.horizontal, big ? 22 : 16)
            .padding(.vertical, big ? 14 : 10)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: Ablox.Metrics.minimumTapTarget)
            .background(
                shape.fill(LinearGradient(colors: [tint.top, tint.bottom], startPoint: .top, endPoint: .bottom))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            )
            .background(shape.fill(tint.edge).offset(y: pressed ? 1 : depth))
            .offset(y: pressed ? depth - 1 : 0)
            .padding(.bottom, depth)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: pressed)
            .onChange(of: pressed) { _, down in
                if down { MenuSounds.tap() }
            }
    }
}

/// A card: glass on a darker edge, the same as the web's `.ab-box`.
public struct BlockCard<Content: View>: View {
    private let title: String?
    private let icon: DrawnIcon?
    private let trailing: AnyView?
    private let content: Content

    public init(_ title: String? = nil, icon: DrawnIcon? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.trailing = nil
        self.content = content()
    }

    public init<Trailing: View>(_ title: String, icon: DrawnIcon? = nil, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.trailing = AnyView(trailing())
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 10) {
                    if let icon { DrawnIconImage(icon, size: 36) }
                    Text(title)
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(Ablox.Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    trailing
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.strokeBorder(Ablox.Palette.line, lineWidth: 1.5))
        .background(shape.fill(Color.black.opacity(0.28)).offset(y: 5))
        .padding(.bottom, 5)
    }
}

/// A rounded pill: a picture and a number (coins, a level, days in a row).
public struct CountPill: View {
    private let icon: DrawnIcon
    private let text: String
    private let colour: Color

    public init(_ icon: DrawnIcon, _ text: String, colour: Color = Ablox.Palette.accent) {
        self.icon = icon
        self.text = text
        self.colour = colour
    }

    public var body: some View {
        HStack(spacing: 5) {
            DrawnIconImage(icon, size: 28)
            Text(verbatim: text)
                .font(.system(size: 16, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(Ablox.Palette.ink)
        }
        .padding(.leading, 5)
        .padding(.trailing, 12)
        .frame(height: 38)
        .background(Capsule().fill(colour.opacity(0.18)))
        .overlay(Capsule().strokeBorder(colour.opacity(0.45), lineWidth: 1.5))
    }
}

/// The small sounds of the menus: a tap, coins, a new thing, a page turning.
/// Through the same player as the games, so the volume and Settings → Sound
/// apply; Settings → Sound → Menu sounds turns them off on their own.
/// Callable from anywhere (a button style's press is not on the main actor
/// everywhere); the sound itself plays on the main actor.
public enum MenuSounds {
    public static let enabledKey = "ablox.menuSounds"

    public static func tap() { play(.click, volume: 0.5) }
    public static func coins() { play(.coin) }
    public static func reward() { play(.powerUp) }
    public static func page() { play(.pop, volume: 0.6) }
    public static func fanfare() { play(.win) }

    private static func play(_ cue: SoundCue, volume: Float = 1) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) as? Bool ?? true else { return }
        let sound = defaults.object(forKey: "ablox.soundEnabled") as? Bool ?? true
        let haptics = defaults.object(forKey: "ablox.hapticsEnabled") as? Bool ?? true
        Task { @MainActor in MenuSoundPlayer.shared.play(cue, volume: volume, sound: sound, haptics: haptics) }
    }
}

@MainActor
final class MenuSoundPlayer {
    static let shared = MenuSoundPlayer()
    private let player = FeedbackPlayer()

    func play(_ cue: SoundCue, volume: Float, sound: Bool, haptics: Bool) {
        player.isSoundEnabled = sound
        player.isHapticsEnabled = haptics
        player.play(cue, volume: volume)
    }
}
