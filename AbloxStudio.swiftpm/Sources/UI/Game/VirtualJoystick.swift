import SwiftUI
import AbloxCore

/// A thumbstick for touch.
///
/// Floating by default: the stick centres itself wherever the thumb first
/// lands inside its zone. On a 13" iPad there is no single spot a thumb
/// reliably reaches, and a fixed stick forces the hand to hunt for it. Some
/// players still prefer one that stays put (Play screen options), and its
/// size, how solid it looks and its still zone are theirs to choose too.
public struct VirtualJoystick: View {
    /// Normalised offset, `x` right and `z` forward, each in `-1...1`.
    @Binding var value: Vec3
    var onRunStateChange: ((Bool) -> Void)?
    var options: HUDOptions
    /// Which lower corner a fixed stick sits in.
    var fixedOnLeft: Bool

    private var outerRadius: CGFloat { 78 * CGFloat(options.joystickScale) }
    private var knobRadius: CGFloat { 32 * CGFloat(options.joystickScale) }

    @State private var origin: CGPoint?
    @State private var knobOffset: CGSize = .zero
    @State private var isRunning = false

    public init(value: Binding<Vec3>, options: HUDOptions = HUDOptions(), fixedOnLeft: Bool = true,
                onRunStateChange: ((Bool) -> Void)? = nil) {
        self._value = value
        self.options = options
        self.fixedOnLeft = fixedOnLeft
        self.onRunStateChange = onRunStateChange
    }

    // In typed pieces — the zone, the drag, the VoiceOver actions — each
    // checked on its own; inline this was among the slowest views to compile.
    public var body: some View {
        GeometryReader { proxy in
            zone(size: proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityLabel(L("Movement stick"))
        .accessibilityHint(L("Drag to walk. Push all the way to run."))
        // With VoiceOver: a few steps at a time, from the actions menu.
        .accessibilityAction(named: L("Walk forward")) { step(Vec3(0, 0, 1)) }
        .accessibilityAction(named: L("Walk back")) { step(Vec3(0, 0, -1)) }
        .accessibilityAction(named: L("Walk left")) { step(Vec3(-1, 0, 0)) }
        .accessibilityAction(named: L("Walk right")) { step(Vec3(1, 0, 0)) }
    }

    /// Where a fixed stick sits: its lower outer corner.
    private func fixedCentre(in size: CGSize) -> CGPoint {
        let inset = 44 + outerRadius
        return CGPoint(x: fixedOnLeft ? inset : size.width - inset, y: size.height - inset)
    }

    /// The whole zone is the touch target; a floating ring is only drawn
    /// once a thumb is down, a fixed one always.
    private func zone(size: CGSize) -> some View {
        let fixed = options.joystickStyle == .fixed
        return ZStack {
            Color.clear.contentShape(Rectangle())
            if fixed {
                ring.position(fixedCentre(in: size))
            } else if let origin {
                ring
                    .position(origin)
                    .transition(AnyTransition.opacity.combined(with: .scale))
            }
        }
        .gesture(drag(size: size, fixed: fixed))
    }

    private func drag(size: CGSize, fixed: Bool) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if fixed {
                    // Measured from the stick's own centre. A touch that
                    // began far from it is not meant for the stick.
                    let centre = fixedCentre(in: size)
                    let start = CGSize(width: gesture.startLocation.x - centre.x, height: gesture.startLocation.y - centre.y)
                    guard (start.width * start.width + start.height * start.height).squareRoot() < outerRadius * 1.8 else { return }
                    update(with: CGSize(width: gesture.location.x - centre.x, height: gesture.location.y - centre.y))
                } else {
                    touched(at: gesture.startLocation, moved: gesture.translation)
                }
            }
            .onEnded { _ in
                released()
            }
    }

    private func touched(at start: CGPoint, moved translation: CGSize) {
        if origin == nil {
            withAnimation(.easeOut(duration: 0.12)) {
                origin = start
            }
        }
        update(with: translation)
    }

    private func released() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            origin = nil
            knobOffset = .zero
        }
        value = .zero
        setRunning(false)
    }

    /// Walks for a moment, then stops.
    private func step(_ direction: Vec3) {
        value = direction
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            value = .zero
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(Color.white.opacity(isRunning ? 0.5 : 0.18), lineWidth: isRunning ? 2 : 1))
                .frame(width: outerRadius * 2, height: outerRadius * 2)

            Circle()
                .fill(isRunning ? Ablox.Palette.accent : Color.white.opacity(0.85))
                .frame(width: knobRadius * 2, height: knobRadius * 2)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                .offset(knobOffset)
        }
        .opacity(options.joystickOpacity)
        .allowsHitTesting(false)
    }

    private func update(with translation: CGSize) {
        let maxTravel = outerRadius - knobRadius
        let raw = CGVector(dx: translation.width, dy: translation.height)
        let distance = (raw.dx * raw.dx + raw.dy * raw.dy).squareRoot()

        // Clamp to the ring so the knob never leaves its housing, and so the
        // reported magnitude tops out at exactly 1.
        let clamped: CGVector
        if distance > maxTravel, distance > 0 {
            let scale = maxTravel / distance
            clamped = CGVector(dx: raw.dx * scale, dy: raw.dy * scale)
        } else {
            clamped = raw
        }

        knobOffset = CGSize(width: clamped.dx, height: clamped.dy)

        let nx = Float(clamped.dx / maxTravel)
        // Screen-down is +y, but forward is +z in the movement input, so the
        // vertical axis is negated here rather than at every read site.
        let nz = Float(-clamped.dy / maxTravel)
        // The still zone and eight directions, as the player chose.
        let shaped = TouchStick.shape(x: nx, z: nz, deadZone: Float(options.stickDeadZone),
                                      eightWay: options.eightWay, alwaysRun: false)
        value = shaped.stick
        setRunning(shaped.running)
    }

    private func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        onRunStateChange?(running)
    }
}

// MARK: - Camera pad

/// The half of the screen that turns the camera. Invisible by design: any
/// drag that is not on the stick or a button orbits the view.
public struct CameraPad: View {
    @Binding var yaw: Float
    @Binding var pitch: Float
    var sensitivity: Double
    var invertY: Bool
    /// How far up and down the view may tilt. An orbit camera behind the
    /// player must not dip under the floor; a first-person view needs to look
    /// up at someone on a ledge.
    var pitchRange: ClosedRange<Float>
    /// A tap that did not move is forwarded, so tapping a block still works
    /// through the pad.
    var onTap: ((CGPoint) -> Void)?
    /// Left-right flipped, and up-down at its own speed (Play screen options).
    var invertX = false
    var verticalSpeed: Double = 1
    /// Two quick taps: the camera goes back behind the player.
    var onDoubleTap: (() -> Void)?

    @State private var lastTranslation: CGSize = .zero
    @State private var didDrag = false
    @State private var lastTapAt: Date?

    public init(
        yaw: Binding<Float>,
        pitch: Binding<Float>,
        sensitivity: Double = 1,
        invertY: Bool = false,
        pitchRange: ClosedRange<Float> = -75...20,
        invertX: Bool = false,
        verticalSpeed: Double = 1,
        onTap: ((CGPoint) -> Void)? = nil,
        onDoubleTap: (() -> Void)? = nil
    ) {
        self._yaw = yaw
        self._pitch = pitch
        self.sensitivity = sensitivity
        self.invertY = invertY
        self.pitchRange = pitchRange
        self.invertX = invertX
        self.verticalSpeed = verticalSpeed
        self.onTap = onTap
        self.onDoubleTap = onDoubleTap
    }

    public var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        // Deltas, not absolute translation: a long drag must
                        // keep turning rather than snapping back.
                        let dx = gesture.translation.width - lastTranslation.width
                        let dy = gesture.translation.height - lastTranslation.height
                        lastTranslation = gesture.translation

                        if abs(gesture.translation.width) > 6 || abs(gesture.translation.height) > 6 {
                            didDrag = true
                        }

                        let factor = Float(0.28 * sensitivity)
                        let look = CameraHabits.look(dx: Float(dx), dy: Float(dy), invertX: invertX, verticalSpeed: verticalSpeed)
                        yaw = normalizeDegrees(yaw - look.dx * factor)
                        let tilted = pitch + look.dy * factor * (invertY ? -1 : 1)
                        pitch = max(pitchRange.lowerBound, min(pitchRange.upperBound, tilted))
                    }
                    .onEnded { gesture in
                        if !didDrag {
                            onTap?(gesture.startLocation)
                            let now = Date()
                            if let last = lastTapAt, now.timeIntervalSince(last) < 0.35, let onDoubleTap {
                                lastTapAt = nil
                                onDoubleTap()
                            } else {
                                lastTapAt = now
                            }
                        }
                        lastTranslation = .zero
                        didDrag = false
                    }
            )
            .accessibilityLabel(L("Camera"))
            .accessibilityHint(L("Drag to look around. Swipe up or down to turn."))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: yaw = normalizeDegrees(yaw - 45)
                case .decrement: yaw = normalizeDegrees(yaw + 45)
                @unknown default: break
                }
            }
    }
}

// MARK: - Jump button

public struct JumpButton: View {
    @Binding var isPressed: Bool
    /// A small tap felt on each press (Play screen options).
    var haptics: Bool

    public init(isPressed: Binding<Bool>, haptics: Bool = false) {
        self._isPressed = isPressed
        self.haptics = haptics
    }

    public var body: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(Circle().strokeBorder(Ablox.Palette.accent.opacity(isPressed ? 0.9 : 0.4), lineWidth: 2))
            .overlay(
                Image(systemName: "arrow.up")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(isPressed ? Ablox.Palette.accent : .white)
            )
            .frame(width: 76, height: 76)
            .scaleEffect(isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
            .gesture(
                // A press-and-hold gesture rather than a Button, so holding
                // the key down keeps `isJumping` true for the solver.
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !isPressed { isPressed = true } }
                    .onEnded { _ in isPressed = false }
            )
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: isPressed) { _, pressed in haptics && pressed }
            .accessibilityLabel(L("Jump"))
            .accessibilityAddTraits(.isButton)
    }
}
