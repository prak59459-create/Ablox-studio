import SwiftUI
import AbloxCore

/// What a world's script puts on the screen: its own GUI, placed freely, and
/// the shooter furniture — crosshair, health, hit marker — that appears only
/// once the script involves it. A world without a script shows none of this.
struct ScriptHUDLayer: View {
    @ObservedObject var session: SessionCoordinator
    /// Settings → Comfort → Fewer flashes.
    var reduceFlashing = false
    /// Settings → Controls: how the aiming mark looks.
    var crosshair: CrosshairStyle = .plus
    var crosshairColor: CrosshairColor = .white

    var body: some View {
        let state = session.scripted
        ZStack {
            DamageFlash(count: state.damageFlashCount, gentle: reduceFlashing)

            // Below the top bar while it shows, so a script's "top" is never
            // under the leave button.
            ScriptUICanvas(
                state: state,
                parent: nil,
                onButton: { id in session.send(input: .button(id: id)) },
                onSubmit: { id, text in session.send(input: .text(id: id, value: text)) }
            )
            .padding(.top, state.showsDefaultUI ? 64 : 0)

            if state.weapon != nil || state.camera.mode == .firstPerson {
                Crosshair(hitCount: state.hitMarkerCount, knockedOut: state.lastHitWasKnockout,
                          style: crosshair, colour: Color(crosshairColor.color))
                    .allowsHitTesting(false)
            }

            if let health = state.health {
                HealthBar(health: health)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }

            if state.isKnockedOut {
                knockedOutBanner
            }

            FadeOverlay(fade: state.fade, gentle: reduceFlashing)
        }
    }

    private var knockedOutBanner: some View {
        VStack(spacing: 6) {
            Text(L("Knocked out"))
                .font(.largeTitle.weight(.black))
            Text(L("You'll be back in a moment."))
                .font(.subheadline)
                .foregroundStyle(Ablox.Palette.inkMuted)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
        .background(Ablox.Palette.danger.opacity(0.35), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// The elements inside one parent — the screen, or a panel — each placed at
/// its `x`, `y` (fractions of this canvas), `pivot` and offset.
struct ScriptUICanvas: View {
    let state: ScriptedPlayerState
    let parent: String?
    let onButton: (String) -> Void
    let onSubmit: (String, String) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(state.children(of: parent)) { element in
                    ScriptUIElementView(element: element, state: state, onButton: onButton, onSubmit: onSubmit)
                        .fixedSize()
                        // A zero-size frame aligned on the pivot, then placed:
                        // the element's pivot point lands exactly on (x, y)
                        // without needing to know the element's own size.
                        .frame(width: 0, height: 0, alignment: Self.alignment(element))
                        .position(
                            x: proxy.size.width * element.x + element.offsetX,
                            y: proxy.size.height * element.y + element.offsetY
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// The nearest of the nine alignments to the element's pivot.
    static func alignment(_ element: UIElement) -> Alignment {
        let column = element.pivotX < 0.34 ? 0 : element.pivotX > 0.66 ? 2 : 1
        let row = element.pivotY < 0.34 ? 0 : element.pivotY > 0.66 ? 2 : 1
        let grid: [[Alignment]] = [
            [.topLeading, .top, .topTrailing],
            [.leading, .center, .trailing],
            [.bottomLeading, .bottom, .bottomTrailing]
        ]
        return grid[row][column]
    }
}

/// One element: a panel (with its own canvas inside), text, a button, an
/// icon, a bar or a text box.
struct ScriptUIElementView: View {
    let element: UIElement
    let state: ScriptedPlayerState
    let onButton: (String) -> Void
    let onSubmit: (String, String) -> Void

    private var foreground: Color { element.color.map { Color($0) } ?? .white }
    private var font: Font { .system(size: CGFloat(element.fontSize), weight: element.bold ? .bold : .regular) }
    private var radius: CGFloat { CGFloat(element.cornerRadius) }

    var body: some View {
        content
            .opacity(element.opacity)
    }

    @ViewBuilder
    private var content: some View {
        switch element.kind {
        case .panel:
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(element.background.map { Color($0) } ?? Color.black.opacity(0.5))
                AnyView(ScriptUICanvas(state: state, parent: element.id, onButton: onButton, onSubmit: onSubmit))
            }
            .frame(width: CGFloat(element.width ?? 320), height: CGFloat(element.height ?? 220))

        case .text:
            Text(verbatim: element.text)
                .font(font)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .shadow(color: element.background == nil ? .black.opacity(0.7) : .clear, radius: 2)
                .padding(element.background == nil ? 0 : 10)
                .frame(width: element.width.map { CGFloat($0) }, height: element.height.map { CGFloat($0) })
                .background(element.background.map { Color($0) } ?? .clear,
                            in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .allowsHitTesting(false)

        case .button:
            Button {
                onButton(element.id)
            } label: {
                Text(verbatim: element.text)
                    .font(font)
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(width: element.width.map { CGFloat($0) }, height: element.height.map { CGFloat($0) })
                    .frame(minWidth: Ablox.Metrics.minimumTapTarget, minHeight: Ablox.Metrics.minimumTapTarget)
                    .background(element.background.map { Color($0) } ?? Ablox.Palette.accentDeep,
                                in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
            .buttonStyle(.plain)

        case .image:
            Image(systemName: element.text)
                .font(.system(size: CGFloat(element.fontSize), weight: element.bold ? .bold : .regular))
                .foregroundStyle(foreground)
                .frame(width: element.width.map { CGFloat($0) }, height: element.height.map { CGFloat($0) })
                .background(element.background.map { Color($0) } ?? .clear,
                            in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .allowsHitTesting(false)

        case .bar:
            let width = CGFloat(element.width ?? 200)
            let height = CGFloat(element.height ?? 14)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(element.background.map { Color($0) } ?? Color.black.opacity(0.4))
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(element.color.map { Color($0) } ?? Ablox.Palette.accent)
                    .frame(width: width * CGFloat(element.fraction))
            }
            .frame(width: width, height: height)
            .animation(.easeOut(duration: 0.2), value: element.fraction)
            .allowsHitTesting(false)

        case .input:
            ScriptInputField(element: element, font: font, foreground: foreground, onSubmit: onSubmit)
        }
    }
}

/// A script's text box: typed into, then sent with the return key or the
/// arrow button.
struct ScriptInputField: View {
    let element: UIElement
    let font: Font
    let foreground: Color
    let onSubmit: (String, String) -> Void
    @State private var draft = ""

    init(element: UIElement, font: Font, foreground: Color, onSubmit: @escaping (String, String) -> Void) {
        self.element = element
        self.font = font
        self.foreground = foreground
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: 8) {
            AbloxTextField(element.text, text: $draft, onSubmit: send)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(foreground)
                .autocorrectionDisabled()
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Ablox.Palette.accent)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: CGFloat(element.width ?? 260))
        .background(element.background.map { Color($0) } ?? Color.black.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: CGFloat(element.cornerRadius), style: .continuous))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSubmit(element.id, text)
        draft = ""
    }
}

/// The whole screen fading to a colour and back, for scene changes.
private struct FadeOverlay: View {
    let fade: ScriptedPlayerState.Fade
    /// No fade quicker than half a second: a sudden flash of white is what
    /// "fewer flashes" is for.
    let gentle: Bool
    @State private var shown: Double = 0
    @State private var color: Color = .black

    init(fade: ScriptedPlayerState.Fade, gentle: Bool = false) {
        self.fade = fade
        self.gentle = gentle
    }

    private func duration(_ seconds: Double) -> Double {
        gentle ? max(0.5, seconds) : seconds
    }

    var body: some View {
        Rectangle()
            .fill(color)
            .opacity(shown)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onChange(of: fade) { _, fade in
                if let target = fade.color {
                    color = Color(target)
                    withAnimation(.easeInOut(duration: duration(fade.seconds))) { shown = 1 }
                } else {
                    withAnimation(.easeInOut(duration: duration(fade.seconds))) { shown = 0 }
                }
            }
    }
}

/// A plus in the middle of the screen, which turns into a red cross for a
/// moment when a shot lands.
private struct Crosshair: View {
    let hitCount: Int
    let knockedOut: Bool
    let style: CrosshairStyle
    let colour: Color
    @State private var showingHit = false

    init(hitCount: Int, knockedOut: Bool, style: CrosshairStyle = .plus, colour: Color = .white) {
        self.hitCount = hitCount
        self.knockedOut = knockedOut
        self.style = style
        self.colour = colour
    }

    var body: some View {
        ZStack {
            if let symbol = style.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: style.pointSize, weight: .semibold))
                    .foregroundStyle(colour.opacity(0.9))
                    .shadow(color: .black.opacity(0.6), radius: 2)
            }
            if showingHit {
                Image(systemName: "xmark")
                    .font(.system(size: knockedOut ? 34 : 26, weight: .heavy))
                    .foregroundStyle(knockedOut ? Ablox.Palette.danger : .white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .onChange(of: hitCount) { _, _ in
            withAnimation(.easeOut(duration: 0.08)) { showingHit = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                withAnimation(.easeIn(duration: 0.15)) { showingHit = false }
            }
        }
    }
}

/// A red edge round the screen when you are hit.
private struct DamageFlash: View {
    let count: Int
    /// A faint, slow edge instead of a sharp red flash.
    let gentle: Bool
    @State private var opacity: Double = 0

    init(count: Int, gentle: Bool = false) {
        self.count = count
        self.gentle = gentle
    }

    var body: some View {
        Rectangle()
            .fill(RadialGradient(
                colors: [.clear, Ablox.Palette.danger.opacity(0.75)],
                center: .center, startRadius: 180, endRadius: 700
            ))
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onChange(of: count) { _, _ in
                opacity = gentle ? 0.35 : 1
                withAnimation(.easeOut(duration: gentle ? 0.8 : 0.45)) { opacity = 0 }
            }
    }
}

private struct HealthBar: View {
    let health: ScriptedPlayerState.Health

    private var colour: Color {
        health.fraction > 0.5 ? Ablox.Palette.success : health.fraction > 0.25 ? Ablox.Palette.warning : Ablox.Palette.danger
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "heart.fill")
                .foregroundStyle(colour)
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.35))
                Capsule().fill(colour).frame(width: 220 * health.fraction)
            }
            .frame(width: 220, height: 12)
            .animation(.easeOut(duration: 0.2), value: health.fraction)
            Text(verbatim: "\(Int(health.current.rounded()))")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .frame(minWidth: 34, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Health {} of {}", Int(health.current.rounded()), Int(health.maximum.rounded())))
    }
}

/// The fire button, held to keep firing, with the ammo count and a reload
/// button beside it. Shown only while the script has given a weapon.
struct CombatControls: View {
    @ObservedObject var session: SessionCoordinator
    @Binding var isFiring: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(spacing: 8) {
                if let ammo = session.scripted.ammo {
                    ammoCount(ammo)
                }
                reloadButton
            }
            fireButton(canFire: session.scripted.canFire)
        }
    }

    private func ammoCount(_ ammo: ScriptedPlayerState.Ammo) -> some View {
        let text: String = ammo.isReloading ? "…" : "\(ammo.current) / \(ammo.magazine)"
        let colour: Color = ammo.current == 0 ? Ablox.Palette.warning : .white
        let spoken: String = ammo.isReloading ? L("Reloading") : L("{} of {} rounds", ammo.current, ammo.magazine)
        return Text(verbatim: text)
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(colour)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityLabel(spoken)
    }

    private var reloadButton: some View {
        Button {
            session.send(input: .reload)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.headline)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(.white)
        }
        .accessibilityLabel(L("Reload"))
    }

    private func fireButton(canFire: Bool) -> some View {
        let fill: Color = isFiring ? Ablox.Palette.danger.opacity(0.55) : Color.black.opacity(0.25)
        let ring: Color = Ablox.Palette.danger.opacity(isFiring ? 1 : 0.6)
        let scale: CGFloat = isFiring ? 0.93 : 1
        return Circle()
            .fill(fill)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(ring, lineWidth: 3))
            .overlay(
                Image(systemName: "scope")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
            )
            .frame(width: 96, height: 96)
            .scaleEffect(scale)
            .opacity(canFire ? 1 : 0.5)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isFiring)
            .gesture(hold)
            .accessibilityLabel(L("Fire"))
            .accessibilityAddTraits(.isButton)
    }

    /// Held, not tapped: holding keeps firing at the weapon's rate, which is
    /// how every shooter on a phone works.
    private var hold: some SwiftUI.Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in isFiring = true }
            .onEnded { _ in isFiring = false }
    }
}

/// The world script's errors and printed lines, on the host's screen.
struct ScriptLogBanner: View {
    @ObservedObject var session: SessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L("Script"), systemImage: "curlybraces")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Ablox.Palette.inkMuted)
                Spacer()
                Button {
                    session.clearScriptLog()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Ablox.Palette.inkFaint)
                }
                .accessibilityLabel(L("Dismiss"))
            }
            ForEach(session.scriptLog.suffix(4)) { line in
                Text(verbatim: line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(line.isError ? Ablox.Palette.danger : .white)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
