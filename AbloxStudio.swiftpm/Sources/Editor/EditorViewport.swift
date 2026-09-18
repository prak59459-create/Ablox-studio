import SwiftUI
import RealityKit
import ARKit
import simd
import Combine

/// The Studio's 3D canvas.
///
/// Orbit camera, tap to select, drag to transform. Physics is off in edit mode
/// — blocks must not topple while you are arranging them.
public struct EditorViewport: UIViewRepresentable {

    @ObservedObject var session: StudioSession
    /// Lets the toolbar and the part palette drive the camera, and ask where a
    /// new part should land, without owning the coordinator.
    var commands: ViewportCommands

    public init(session: StudioSession, commands: ViewportCommands) {
        self.session = session
        self.commands = commands
    }

    public func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(UIColor(red: 0.05, green: 0.06, blue: 0.11, alpha: 1))
        context.coordinator.attach(to: view)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        // Two fingers orbit; one finger transforms the selection. Separating
        // them means a drag on a block never accidentally spins the camera.
        let orbit = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleOrbit(_:)))
        orbit.minimumNumberOfTouches = 2
        orbit.maximumNumberOfTouches = 2
        view.addGestureRecognizer(orbit)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        pan.require(toFail: orbit)

        return view
    }

    public func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(session: session)
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator {
        var parent: EditorViewport

        private let worldScene = WorldScene()
        private let cameraAnchor = AnchorEntity(world: .zero)
        private let camera = PerspectiveCamera()
        private var gridEntity: ModelEntity?

        private weak var view: ARView?

        // Orbit camera state.
        private var focus = Vec3(0, 1, 0)
        private var yaw: Float = -30
        private var pitch: Float = -28
        private var distance: Float = 18
        private var pinchStartDistance: Float = 18

        private var lastSyncedRevision: Date?
        private var lastSelection: Set<UUID> = []
        private var lastMode: StudioSession.Mode = .edit

        /// Screen-space drag state for the transform tools.
        private var dragLast: CGPoint?
        private var isDragging = false

        init(parent: EditorViewport) {
            self.parent = parent
        }

        func attach(to view: ARView) {
            self.view = view
            parent.commands.coordinator = self
            view.scene.addAnchor(worldScene.anchor)

            camera.camera.fieldOfViewInDegrees = 55
            cameraAnchor.addChild(camera)
            view.scene.addAnchor(cameraAnchor)

            addGrid()
            updateCamera()
        }

        func detach() {
            worldScene.removeAll()
        }

        /// A faint reference grid at y = 0, so an empty world is not a void.
        private func addGrid() {
            var material = UnlitMaterial(color: UIColor.white.withAlphaComponent(0.05))
            material.blending = .transparent(opacity: .init(floatLiteral: 0.05))
            let grid = ModelEntity(mesh: .generatePlane(width: 200, depth: 200), materials: [material])
            grid.position = SIMD3<Float>(0, -0.01, 0)
            grid.name = "studio.grid"
            worldScene.anchor.addChild(grid)
            gridEntity = grid
        }

        // MARK: Sync

        func sync(session: StudioSession) {
            let world = session.document.world
            let isPlaying = session.mode == .play
            // Computed before `lastMode` is updated — reading it afterwards
            // would always compare the mode against itself.
            let modeChanged = isPlaying != (lastMode == .play)

            if world.modifiedAt != lastSyncedRevision || modeChanged {
                lastSyncedRevision = world.modifiedAt
                // Physics only in play mode: blocks must stay where they are
                // put while you are building.
                worldScene.sync(to: world, physicsEnabled: isPlaying)
            }
            lastMode = session.mode
            gridEntity?.isEnabled = !isPlaying

            let selection = session.document.selection
            guard selection != lastSelection || modeChanged else { return }

            if isPlaying {
                worldScene.clearAllHighlights()
            } else {
                for id in lastSelection.subtracting(selection) {
                    worldScene.setHighlight(false, forBlock: id)
                }
                // Re-applied for everything selected, not just newly selected
                // ids: a world re-sync rebuilds entities and loses highlights.
                for id in selection {
                    worldScene.setHighlight(true, forBlock: id)
                }
            }
            lastSelection = selection
        }

        // MARK: Camera

        private func updateCamera() {
            let orbit = Quat.euler(degrees: Vec3(pitch, yaw, 0))
            let offset = orbit.act(Vec3(0, 0, 1)) * distance
            let position = focus + offset
            cameraAnchor.position = position.simd
            camera.look(at: focus.simd, from: position.simd, relativeTo: nil)
        }

        /// Where a new part should land: where the camera is looking, dropped
        /// onto the ground plane.
        ///
        /// Pulled when the palette is tapped rather than pushed every frame.
        /// Publishing it into SwiftUI state sixty times a second would rerun
        /// the view body for a value nobody reads until a button is pressed —
        /// and writing view state from the render loop is how you earn
        /// "Modifying state during view update" warnings.
        func insertionPoint() -> Vec3 {
            let orbit = Quat.euler(degrees: Vec3(pitch, yaw, 0))
            let ray = Ray(
                origin: focus + orbit.act(Vec3(0, 0, 1)) * distance,
                direction: orbit.act(Vec3(0, 0, -1))
            )
            guard let t = ray.intersectionWithHorizontalPlane(atHeight: 0) else { return focus }
            return ray.point(at: t)
        }

        /// Moves the camera to frame the current selection, or the world.
        func frame(_ bounds: BoundingBox?) {
            guard let bounds else { return }
            focus = bounds.center
            let radius = max(1, bounds.size.length * 0.5)
            distance = max(4, radius * 2.6)
            updateCamera()
        }

        // MARK: Gestures

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view, parent.session.mode == .edit else { return }
            let location = recognizer.location(in: view)

            guard let entity = view.entity(at: location),
                  let blockID = worldScene.blockID(forHit: entity) else {
                parent.session.select(nil)
                return
            }

            // Two fingers, or a tap while something is selected, extends the
            // selection instead of replacing it.
            let additive = recognizer.numberOfTouches > 1
            parent.session.select(blockID, additive: additive)
        }

        @objc func handleOrbit(_ recognizer: UIPanGestureRecognizer) {
            guard let view else { return }
            let translation = recognizer.translation(in: view)

            switch recognizer.state {
            case .changed:
                yaw = normalizeDegrees(yaw - Float(translation.x) * 0.3)
                pitch = max(-85, min(85, pitch + Float(translation.y) * 0.3))
                updateCamera()
                recognizer.setTranslation(.zero, in: view)
            default:
                break
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                pinchStartDistance = distance
            case .changed:
                distance = max(2, min(140, pinchStartDistance / Float(recognizer.scale)))
                updateCamera()
            default:
                break
            }
        }

        /// One-finger drag: transforms the selection with the active tool, or
        /// pans the camera when nothing is selected.
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view, parent.session.mode == .edit else { return }
            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)

            let session = parent.session
            let tool = session.document.tool
            let hasSelection = !session.document.selection.isEmpty

            switch recognizer.state {
            case .began:
                isDragging = hasSelection && tool != .select
                if isDragging { session.edit { $0.beginGesture() } }

            case .changed:
                guard isDragging else {
                    pan(by: translation)
                    return
                }
                apply(tool: tool, translation: translation, session: session)

            case .ended, .cancelled, .failed:
                if isDragging { session.edit { $0.endGesture() } }
                isDragging = false

            default:
                break
            }
        }

        /// Drags the camera's focus across the ground plane.
        private func pan(by translation: CGPoint) {
            let orbit = Quat.yaw(degrees: yaw)
            let right = orbit.act(Vec3(1, 0, 0))
            let forward = orbit.act(Vec3(0, 0, 1))
            // Scale with distance so panning feels the same zoomed in or out.
            let scale = distance * 0.0016
            focus -= right * (Float(translation.x) * scale)
            focus -= forward * (Float(translation.y) * scale)
            updateCamera()
        }

        private func apply(tool: EditorDocument.Tool, translation: CGPoint, session: StudioSession) {
            let dx = Float(translation.x)
            let dy = Float(translation.y)

            switch tool {
            case .select:
                break

            case .move:
                // Screen-space drag mapped onto the ground plane in camera
                // space, so dragging right always moves the block right on
                // screen no matter which way the camera faces.
                let orbit = Quat.yaw(degrees: yaw)
                let right = orbit.act(Vec3(1, 0, 0))
                let forward = orbit.act(Vec3(0, 0, 1))
                let scale = distance * 0.0016
                var offset = right * (dx * scale) + forward * (dy * scale)

                // Two fingers on the move tool lifts vertically instead.
                if abs(dy) > abs(dx) * 2, isVerticalModifierActive {
                    offset = Vec3(0, -dy * scale, 0)
                }
                session.edit { $0.translateSelection(by: offset) }

            case .rotate:
                session.edit { $0.rotateSelection(byDegrees: Vec3(0, dx * 0.6, 0)) }

            case .scale:
                // Drag right or up to grow. A multiplicative step keeps the
                // feel consistent at any current size.
                let factor = 1 + (dx - dy) * 0.004
                session.edit { $0.scaleSelection(by: Vec3(repeating: max(0.9, min(1.1, factor)))) }
            }
        }

        /// Placeholder for a modifier the toolbar sets; vertical moves are
        /// driven by the toolbar's axis toggle rather than a hidden gesture.
        private var isVerticalModifierActive = false

        func setVerticalMove(_ enabled: Bool) {
            isVerticalModifierActive = enabled
        }
    }
}

// MARK: - Viewport commands

/// A handle the toolbar can use to drive the camera.
///
/// SwiftUI owns the `UIViewRepresentable` struct, not its coordinator, so a
/// view cannot simply hold a reference to the coordinator and call it. This
/// small object is created by the parent view, handed to the viewport, and the
/// coordinator registers itself on attach. The reference is weak, so a
/// dismissed viewport does not keep its ARView alive.
public final class ViewportCommands: ObservableObject {
    weak var coordinator: EditorViewport.Coordinator?

    public init() {}

    /// Moves the camera to frame the given bounds. No-op before the viewport
    /// has attached, or when there is nothing to frame.
    @MainActor
    public func frame(_ bounds: BoundingBox?) {
        coordinator?.frame(bounds)
    }

    /// Where a new part should be dropped. Falls back to the origin before the
    /// viewport has attached.
    @MainActor
    public func insertionPoint() -> Vec3 {
        coordinator?.insertionPoint() ?? .zero
    }
}
