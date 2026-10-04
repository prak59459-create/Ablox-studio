import Foundation
import Combine

/// The player's hands on the controls — the stick, the buttons, the camera
/// drag, a game controller — which change many times a second.
///
/// A class the 3D view reads every frame, not view state. As view state,
/// every touch rebuilt the whole play screen: sixty to a hundred and twenty
/// times a second while a thumb moved the stick or the camera, and every
/// frame while a controller's stick was held, which in a big game cost more
/// than drawing the frame. What the screen shows from them — the compass and
/// a map that turns with the camera — follows `shownYaw`, at most fifteen
/// times a second.
@MainActor
public final class PlayControls: ObservableObject {

    // The touch controls.
    public var stick: Vec3 = .zero
    /// The stick pushed all the way.
    public var stickRunning = false
    public var isJumping = false
    public var holdingRun = false
    public var keepWalking = false
    public var alwaysRun = false
    public var isFiring = false

    // A game controller, keyboard or mouse.
    public var padStick: Vec3 = .zero
    public var padJumping = false
    public var padRunning = false
    public var padFiring = false

    // The camera, turned by a drag, a controller or the game.
    public var cameraYaw: Float = 0
    public var cameraPitch: Float = -14

    /// The camera's bearing as the compass and the map last showed it.
    @Published public private(set) var shownYaw: Float = 0
    private var shownAt: Double = -.infinity

    // Nonisolated so a view can make one as a `@State` default.
    nonisolated public init() {}

    /// Where the player is trying to go, as the character solver takes it.
    /// The touch stick wins over a controller's while it is held.
    public var movementInput: MovementInput {
        var move = stick == .zero ? padStick : stick
        if keepWalking { move = TouchStick.keepWalking(move) }
        let running = stickRunning || padRunning || holdingRun || (alwaysRun && move != .zero)
        return MovementInput(stick: move, isJumping: isJumping || padJumping, isRunning: running,
                             cameraYawDegrees: cameraYaw)
    }

    /// A fire button is held, on the screen or on a controller.
    public var wantsToFire: Bool {
        isFiring || padFiring
    }

    /// The 3D view calls this every frame; the compass and the map catch up
    /// with the camera a few times a second, when it has turned.
    public func showBearing(at time: Double) {
        guard time - shownAt >= 1.0 / 15, abs(normalizeDegrees(cameraYaw - shownYaw)) > 0.5 else { return }
        shownAt = time
        shownYaw = cameraYaw
    }
}
