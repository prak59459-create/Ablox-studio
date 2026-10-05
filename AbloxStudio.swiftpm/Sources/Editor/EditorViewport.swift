import SwiftUI
import RealityKit
import ARKit
import simd
import Combine
import AbloxCore

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

        /// The box being drawn with the box-select tool.
        private var boxStart: CGPoint?
        private let boxView = UIView()
        /// Co-editors and pins, as labels over the view.
        private var labels: [String: UILabel] = [:]
        /// Words floating over blocks (`BlockLabel`), as players will see them.
        private var blockWords: BlockLabelOverlay?
        /// When test play began, for blocks that move by themselves.
        private var animationStart: Date?
        private var updateSubscription: Cancellable?
        /// Blocks hidden because their layer is.
        private var layerHidden: Set<UUID> = []

        /// Settings → Drag speed.
        private var sensitivity: Float {
            let stored = UserDefaults.standard.object(forKey: "ablox.studio.dragSensitivity") as? Double ?? 1
            return Float(max(0.25, min(3, stored)))
        }

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

            boxView.isHidden = true
            boxView.isUserInteractionEnabled = false
            boxView.layer.borderColor = UIColor.cyan.cgColor
            boxView.layer.borderWidth = 2
            boxView.backgroundColor = UIColor.cyan.withAlphaComponent(0.12)
            view.addSubview(boxView)

            let words = BlockLabelOverlay(frame: view.bounds)
            words.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(words, belowSubview: boxView)
            blockWords = words

            updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLabels() }
            }
        }

        func detach() {
            updateSubscription?.cancel()
            updateSubscription = nil
            worldScene.removeAll()
            labels.values.forEach { $0.removeFromSuperview() }
            labels.removeAll()
            blockWords?.removeAll()
            blockWords?.removeFromSuperview()
            blockWords = nil
        }

        /// Co-editors' names where they are working, and pins pointed in the
        /// chat, kept over the right place as the camera moves.
        private func updateLabels() {
            guard let view else { return }
            updateBlockWords(in: view)
            // Blocks that move by themselves do so in test play; while
            // editing they hold still to be picked and dragged.
            if parent.session.mode == .play {
                animationStart = animationStart ?? Date()
                let seconds = Date().timeIntervalSince(animationStart ?? Date())
                worldScene.animateBlocks(time: seconds, eye: Vec3(camera.position(relativeTo: nil)))
            } else if animationStart != nil {
                animationStart = nil
            }
            let session = parent.session
            var wanted: [String: (text: String, point: Vec3, color: UIColor)] = [:]
            let colors: [UIColor] = [.systemPink, .systemOrange, .systemGreen, .systemPurple, .systemTeal]
            for (index, person) in session.collaborators.enumerated() where person.peerID != session.localID {
                guard let point = session.presence[person.peerID] else { continue }
                wanted["p" + person.peerID.raw.uuidString] = ("● " + person.profile.displayName, point, colors[index % colors.count])
            }
            for pin in session.pins {
                wanted["pin" + pin.id.uuidString] = ("📍 " + pin.name, pin.point, .systemYellow)
            }
            for (key, label) in labels where wanted[key] == nil {
                label.removeFromSuperview()
                labels[key] = nil
            }
            for (key, item) in wanted {
                let label = labels[key] ?? {
                    let made = UILabel()
                    made.font = .systemFont(ofSize: 12, weight: .bold)
                    made.textColor = .white
                    made.layer.cornerRadius = 8
                    made.clipsToBounds = true
                    made.textAlignment = .center
                    view.addSubview(made)
                    labels[key] = made
                    return made
                }()
                label.text = "  " + item.text + "  "
                label.backgroundColor = item.color.withAlphaComponent(0.85)
                label.sizeToFit()
                if let point = view.project((item.point + Vec3(0, 1, 0)).simd) {
                    label.isHidden = false
                    label.center = point
                } else {
                    label.isHidden = true
                }
            }
        }

        /// Each labelled block's words just above it, in front of the camera
        /// and within the label's range.
        private func updateBlockWords(in view: ARView) {
            guard let overlay = blockWords else { return }
            let labelled = worldScene.labeledBlocks
            guard !labelled.isEmpty else {
                overlay.update([])
                return
            }
            let eye = Vec3(camera.position(relativeTo: nil))
            let looking = (focus - eye).normalized
            var items: [BlockLabelOverlay.Item] = []
            for (id, label) in labelled {
                guard let entity = worldScene.entity(for: id), entity.isEnabled, entity.parent != nil else { continue }
                let top = Vec3(entity.position(relativeTo: nil)) + Vec3(0, entity.scale(relativeTo: nil).y / 2 + label.height, 0)
                let toTop = top - eye
                let distance = toTop.length
                guard distance > 0.5, distance < label.range, toTop.dot(looking) > 0.2 * distance,
                      let point = view.project(top.simd) else { continue }
                items.append(BlockLabelOverlay.Item(id: id, label: label, anchor: point, distance: distance))
            }
            overlay.update(items)
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
                layerHidden.removeAll()
            }
            // Hidden layers, in this editor only.
            let hidden = Set(world.blocks.filter { session.document.hiddenLayers.contains($0.layerName) }.map(\.id))
            for id in layerHidden.subtracting(hidden) {
                worldScene.apply(effect: .setVisible(blockID: id, visible: world.block(id: id)?.isVisible ?? true))
            }
            for id in hidden.subtracting(layerHidden) {
                worldScene.apply(effect: .setVisible(blockID: id, visible: false))
            }
            layerHidden = hidden
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
            parent.session.noteFocus(focus)
        }

        /// Straight down, from the front, from the side, or back to the
        /// usual angle.
        func setView(_ angle: ViewAngle) {
            switch angle {
            case .top: pitch = -89; yaw = 0
            case .front: pitch = -5; yaw = 0
            case .side: pitch = -5; yaw = 90
            case .usual: pitch = -28; yaw = -30
            }
            updateCamera()
        }

        /// Where the camera is looking, on the ground.
        var focusPoint: Vec3 { focus }

        /// The camera as it is, to come back to later.
        var spot: CameraBookmarks.Spot {
            CameraBookmarks.Spot(target: focus, yaw: yaw, pitch: pitch, distance: distance)
        }

        func go(to spot: CameraBookmarks.Spot) {
            focus = spot.target
            yaw = spot.yaw
            pitch = max(-89, min(89, spot.pitch))
            distance = max(1, min(400, spot.distance))
            updateCamera()
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
            // Parts can be picked and changed while testing too; the change
            // shows straight away.
            guard let view else { return }
            let location = recognizer.location(in: view)
            let session = parent.session
            let hitID = view.entity(at: location).flatMap { worldScene.blockID(forHit: $0) }
                .flatMap { id in layerHidden.contains(id) ? nil : id }

            switch session.document.tool {
            case .paint:
                // Read first: the edit must not read the document it is changing.
                let color = session.document.paintColor
                if let hitID { session.edit { $0.paint(hitID, with: color) } }
                return
            case .eyedropper:
                if let hitID, let block = session.document.world.block(id: hitID) {
                    session.setPaintColor(block.color.withAlpha(1))
                    session.setTool(.paint)
                }
                return
            case .terrain:
                if let point = groundPoint(at: location, hit: hitID) {
                    session.edit { $0.shapeTerrain($0.terrainAction, at: point, brush: $0.terrainBrush) }
                }
                return
            case .select, .move, .rotate, .scale, .boxSelect:
                break
            }

            guard let blockID = hitID, let block = session.document.world.block(id: blockID) else {
                session.select(nil)
                return
            }
            guard session.document.isPickable(block) else { return }

            // Two fingers, or a tap while something is selected, extends the
            // selection instead of replacing it.
            let additive = recognizer.numberOfTouches > 1
            session.select(blockID, additive: additive)
        }

        /// The point on the ground (or on top of the part) under a finger.
        private func groundPoint(at location: CGPoint, hit: UUID?) -> Vec3? {
            guard let view else { return nil }
            if let hit, let bounds = parent.session.document.world.worldBounds(of: hit) {
                return Vec3(bounds.center.x, bounds.max.y, bounds.center.z)
            }
            guard let through = view.ray(through: location) else { return nil }
            let ray = Ray(origin: Vec3(through.origin), direction: Vec3(through.direction))
            guard let t = ray.intersectionWithHorizontalPlane(atHeight: 0) else { return nil }
            return ray.point(at: t)
        }

        /// Selects the parts whose middles are inside the box drawn.
        private func finishBox(to end: CGPoint, additive: Bool) {
            guard let view, let start = boxStart else { return }
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            let world = parent.session.document.world
            let ids = world.blocks.compactMap { block -> UUID? in
                guard !layerHidden.contains(block.id), let bounds = world.worldBounds(of: block.id),
                      let point = view.project(bounds.center.simd), rect.contains(point) else { return nil }
                return block.id
            }
            parent.session.edit { $0.selectBlocks(ids, additive: additive) }
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
            guard let view else { return }
            let session = parent.session
            let tool = session.document.tool

            if tool == .boxSelect {
                let location = recognizer.location(in: view)
                switch recognizer.state {
                case .began:
                    boxStart = location
                    boxView.frame = CGRect(origin: location, size: .zero)
                    boxView.isHidden = false
                case .changed:
                    if let start = boxStart {
                        boxView.frame = CGRect(x: min(start.x, location.x), y: min(start.y, location.y),
                                               width: abs(location.x - start.x), height: abs(location.y - start.y))
                    }
                case .ended:
                    finishBox(to: location, additive: false)
                    boxView.isHidden = true
                    boxStart = nil
                default:
                    boxView.isHidden = true
                    boxStart = nil
                }
                return
            }

            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            let hasSelection = !session.document.selection.isEmpty

            switch recognizer.state {
            case .began:
                isDragging = hasSelection && tool != .select
                if isDragging { session.edit { $0.beginGesture() } }

            case .changed:
                guard isDragging else {
                    // Painting and shaping by dragging over parts and ground.
                    if tool == .paint || tool == .terrain {
                        let location = recognizer.location(in: view)
                        let hit = view.entity(at: location).flatMap { worldScene.blockID(forHit: $0) }
                        if tool == .paint, let hit {
                            let color = session.document.paintColor
                            session.edit { $0.paint(hit, with: color) }
                        }
                        return
                    }
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
                let scale = distance * 0.0016 * sensitivity
                var offset = right * (dx * scale) + forward * (dy * scale)

                // Two fingers on the move tool lifts vertically instead.
                if abs(dy) > abs(dx) * 2, isVerticalModifierActive {
                    offset = Vec3(0, -dy * scale, 0)
                }
                session.edit { $0.translateSelection(by: offset) }

            case .rotate:
                session.edit { $0.rotateSelection(byDegrees: Vec3(0, dx * 0.6 * sensitivity, 0)) }

            case .scale:
                // Drag right or up to grow. A multiplicative step keeps the
                // feel consistent at any current size.
                let factor = 1 + (dx - dy) * 0.004 * sensitivity
                session.edit { $0.scaleSelection(by: Vec3(repeating: max(0.9, min(1.1, factor)))) }

            case .boxSelect, .paint, .eyedropper, .terrain:
                break
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

    @MainActor
    public func setView(_ angle: ViewAngle) {
        coordinator?.setView(angle)
    }

    /// The middle of the screen, on the ground: where "here" is.
    @MainActor
    public func focusPoint() -> Vec3 {
        coordinator?.focusPoint ?? .zero
    }

    /// Where the camera is now; nil before the viewport has attached.
    @MainActor
    public func cameraSpot() -> CameraBookmarks.Spot? {
        coordinator?.spot
    }

    @MainActor
    public func go(to spot: CameraBookmarks.Spot) {
        coordinator?.go(to: spot)
    }
}

/// The camera's preset angles.
public enum ViewAngle: String, CaseIterable, Identifiable, Sendable {
    case usual, top, front, side
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .usual: return L("Usual view")
        case .top: return L("From above (2D)")
        case .front: return L("From the front")
        case .side: return L("From the side")
        }
    }

    public var symbolName: String {
        switch self {
        case .usual: return "cube"
        case .top: return "square.grid.3x3"
        case .front: return "square.stack.3d.forward.dottedline"
        case .side: return "square.stack.3d.down.right"
        }
    }
}
