import Foundation

// Which way a body faces, kept in one place.
//
// A player's `yawDegrees` is a bearing: 0 faces -z (north, up on the map),
// 90 faces +x (east). A rotation about +y by +90°, though, turns -z towards
// -x — the other way. Drawing a body with `Quat.yaw(degrees: yaw)` therefore
// mirrored it: walking right, the face looked left. Everything that turns a
// bearing into a rotation, or back, goes through here.

/// A body's facing, as a bearing, and the rotation that draws it.
public enum Facing {

    /// The bearing of a body facing along `direction` (only x and z count).
    public static func yaw(toward direction: Vec3) -> Float {
        guard direction.x.isFinite, direction.z.isFinite, direction.x != 0 || direction.z != 0 else { return 0 }
        return atan2(direction.x, -direction.z) * 180 / .pi
    }

    /// The rotation that turns a model whose face is on its -z side to face
    /// `yawDegrees`.
    public static func rotation(yawDegrees: Float) -> Quat {
        Quat.yaw(degrees: -(yawDegrees.isFinite ? yawDegrees : 0))
    }

    /// The bearing a yaw-only rotation from `rotation(yawDegrees:)` faces.
    public static func yawDegrees(of rotation: Quat) -> Float {
        normalizeDegrees(-rotation.eulerDegrees.y)
    }

    /// The way the face looks, on the ground.
    public static func forward(yawDegrees: Float) -> Vec3 {
        rotation(yawDegrees: yawDegrees).act(Vec3(0, 0, -1))
    }

    /// The bearing of a body facing where the camera looks.
    public static func yaw(cameraYaw: Float) -> Float {
        normalizeDegrees(-(cameraYaw.isFinite ? cameraYaw : 0))
    }
}

/// Shift lock: a button on the play screen. Off, the body turns to the way
/// the stick walks it. On, it keeps facing where the camera looks, and the
/// stick steps it forward, back and sideways.
public enum ShiftLock {

    /// Whether the body follows the camera this frame. Only behind the
    /// player; first person and aiming already face the camera, and a photo
    /// or watching someone else moves the camera without the body.
    public static func turnsBody(isOn: Bool, cameraMode: CameraSettings.Mode, photoMode: Bool, spectating: Bool) -> Bool {
        isOn && cameraMode == .thirdPerson && !photoMode && !spectating
    }

    /// The body's bearing: the camera's when shift lock turns it, otherwise
    /// what walking made it.
    public static func bodyYaw(walking: Float, cameraYaw: Float, turnsBody: Bool) -> Float {
        turnsBody ? Facing.yaw(cameraYaw: cameraYaw) : walking
    }
}
