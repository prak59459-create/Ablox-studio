import Foundation
import RealityKit
import UIKit
import CoreImage
import Metal
import simd
import AbloxCore

/// The sky, the weather, the time of day and a world's screen look.
///
/// Everything here is worked out on each iPad from the world document and
/// the clock — the host sends nothing while the day passes or the rain
/// falls. `Atmosphere.update` runs every frame but only repaints the sky
/// when it has visibly changed.
@MainActor
final class Atmosphere {

    /// The sky's picture, and what it was painted from.
    private let dome: ModelEntity
    private struct SkyKey: Equatable {
        var style: SkyStyle
        var top: [Int]
        var bottom: [Int]
        var night: Int
    }
    private var skyKey: SkyKey?
    private var skyClock: Float = 10

    private weak var view: ARView?
    /// Haze and cloud-dark, laid over the 3D view below the names.
    private let haze = UIView()
    private let flash = UIView()
    private var lightningIn: Float = 9
    private let post = PostEffect()
    private var appliedEffect: ScreenEffect = .none
    private var appliedVision: ColourVision = .off

    init(parent: Entity) {
        dome = ModelEntity(mesh: ProceduralMesh.skyDome, materials: [UnlitMaterial(color: .black)])
        dome.name = "ablox.sky"
        dome.scale = SIMD3<Float>(repeating: 320)
        parent.addChild(dome)
    }

    func attach(to view: ARView) {
        self.view = view
        for layer in [haze, flash] {
            layer.isUserInteractionEnabled = false
            layer.frame = view.bounds
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            layer.backgroundColor = .clear
            view.insertSubview(layer, at: 0)
        }
        flash.backgroundColor = .white
        flash.alpha = 0
    }

    func detach() {
        view?.renderCallbacks.postProcess = nil
        haze.removeFromSuperview()
        flash.removeFromSuperview()
        dome.removeFromParent()
    }

    /// What the day and the weather look like now.
    struct Light {
        var pitch: Float
        var yaw: Float
        var brightness: Float
        var skyBottom: ColorRGBA
    }

    /// Moves the sky with the camera, repaints it when the day or the
    /// weather has changed it, and returns where the sun should be.
    func update(environment: EnvironmentSettings, camera: Vec3, dt: Float, reduceFlashing: Bool,
                onThunder: () -> Void) -> Light {
        dome.position = camera.simd

        var top = environment.skyTop
        var bottom = environment.skyBottom
        var pitch = environment.sunPitchDegrees
        var yaw = environment.sunYawDegrees
        var brightness = max(0.1, environment.ambientIntensity)
        var night: Float = 0
        if let hour = environment.hour(atWallClock: Date().timeIntervalSince1970) {
            (top, bottom) = DayCycle.sky(hour: hour, top: top, bottom: bottom)
            pitch = DayCycle.sunPitch(hour: hour)
            yaw = DayCycle.sunYaw(hour: hour)
            brightness *= DayCycle.light(hour: hour)
            night = max(0, min(1, -DayCycle.sunHeight(hour: hour) * 3))
        }
        let weather = environment.weather
        if weather.gloom > 0 {
            let grey = ColorRGBA(r: 0.42, g: 0.45, b: 0.5)
            top = top.mixed(with: grey, amount: weather.gloom * 1.4)
            bottom = bottom.mixed(with: grey, amount: weather.gloom * 1.2)
            brightness *= 1 - weather.gloom
        }

        skyClock += dt
        func steps(_ color: ColorRGBA) -> [Int] { [color.r, color.g, color.b].map { Int(($0 * 40).rounded()) } }
        let key = SkyKey(style: environment.skyStyle, top: steps(top), bottom: steps(bottom), night: Int((night * 8).rounded()))
        // At most every half second: painting a sky costs a few ms.
        if key != skyKey, skyClock > 0.5 || skyKey == nil {
            skyKey = key
            skyClock = 0
            if let texture = SurfaceTextures.sky(style: environment.skyStyle, top: top, bottom: bottom, night: night) {
                var material = UnlitMaterial()
                material.color = .init(tint: .white, texture: .init(texture))
                dome.model?.materials = [material]
            }
            view?.environment.background = .color(UIColor(red: CGFloat(bottom.r), green: CGFloat(bottom.g),
                                                          blue: CGFloat(bottom.b), alpha: 1))
        }

        let hazeAmount = CGFloat(weather.haze) * 0.55
        let hazeColor = UIColor(red: CGFloat(bottom.r), green: CGFloat(bottom.g), blue: CGFloat(bottom.b), alpha: hazeAmount)
        if haze.backgroundColor != hazeColor { haze.backgroundColor = hazeColor }

        if weather == .storm {
            lightningIn -= dt
            if lightningIn <= 0 {
                lightningIn = Float.random(in: 7...16)
                if !reduceFlashing {
                    flash.alpha = 0.55
                    UIView.animate(withDuration: 0.35) { [flash] in flash.alpha = 0 }
                }
                onThunder()
            }
        }

        setEffect(environment.screenEffect)
        return Light(pitch: pitch, yaw: yaw, brightness: brightness, skyBottom: bottom)
    }

    /// Settings → Colour vision, drawn over whatever the world looks like.
    func setColourVision(_ vision: ColourVision) {
        guard vision != appliedVision else { return }
        appliedVision = vision
        post.colourMatrix = vision.matrix
        installPostProcess()
    }

    /// The world's screen look, drawn by Core Image after each frame.
    private func setEffect(_ effect: ScreenEffect) {
        guard effect != appliedEffect else { return }
        appliedEffect = effect
        post.effect = effect
        installPostProcess()
    }

    /// Core Image only runs when there is something for it to do.
    private func installPostProcess() {
        guard let view else { return }
        if appliedEffect == .none && appliedVision == .off {
            view.renderCallbacks.postProcess = nil
        } else {
            let post = self.post
            view.renderCallbacks.postProcess = { context in post.process(context) }
        }
    }
}

/// Core Image over the finished frame, the way Apple's own sample does it.
/// Called on the render thread, so it keeps its own lock.
final class PostEffect: @unchecked Sendable {
    private let lock = NSLock()
    private var context: CIContext?
    private var _effect: ScreenEffect = .none
    private var _colourMatrix: [Float]?

    var effect: ScreenEffect {
        get { lock.withLock { _effect } }
        set { lock.withLock { _effect = newValue } }
    }

    /// Three rows of three for colour vision, or nil.
    var colourMatrix: [Float]? {
        get { lock.withLock { _colourMatrix } }
        set { lock.withLock { _colourMatrix = newValue } }
    }

    func process(_ frame: ARView.PostProcessContext) {
        let (effect, matrix, existing) = lock.withLock { (_effect, _colourMatrix, context) }
        let ciContext = existing ?? CIContext(mtlDevice: frame.device)
        if existing == nil { lock.withLock { context = ciContext } }
        guard let input = CIImage(mtlTexture: frame.sourceColorTexture) else { return }
        var picture = Self.filtered(input, effect)
        if let m = matrix, m.count == 9 {
            picture = CIFilter(name: "CIColorMatrix", parameters: [
                kCIInputImageKey: picture,
                "inputRVector": CIVector(x: CGFloat(m[0]), y: CGFloat(m[1]), z: CGFloat(m[2]), w: 0),
                "inputGVector": CIVector(x: CGFloat(m[3]), y: CGFloat(m[4]), z: CGFloat(m[5]), w: 0),
                "inputBVector": CIVector(x: CGFloat(m[6]), y: CGFloat(m[7]), z: CGFloat(m[8]), w: 0)
            ])?.outputImage ?? picture
        }
        let output = picture.cropped(to: input.extent)
        let destination = CIRenderDestination(mtlTexture: frame.targetColorTexture, commandBuffer: frame.commandBuffer)
        destination.isFlipped = false
        _ = try? ciContext.startTask(toRender: output, to: destination)
    }

    static func filtered(_ image: CIImage, _ effect: ScreenEffect) -> CIImage {
        func apply(_ name: String, _ input: CIImage, _ parameters: [String: Any]) -> CIImage {
            var all = parameters
            all[kCIInputImageKey] = input
            return CIFilter(name: name, parameters: all)?.outputImage ?? input
        }
        switch effect {
        case .none:
            return image
        case .bloom:
            return apply("CIBloom", image, [kCIInputRadiusKey: 8, kCIInputIntensityKey: 0.6])
        case .vivid:
            return apply("CIColorControls", image, [kCIInputSaturationKey: 1.45, kCIInputContrastKey: 1.08])
        case .warm:
            return apply("CIColorMatrix", image, ["inputRVector": CIVector(x: 1.08, y: 0, z: 0, w: 0),
                                                  "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
                                                  "inputBVector": CIVector(x: 0, y: 0, z: 0.86, w: 0)])
        case .cool:
            return apply("CIColorMatrix", image, ["inputRVector": CIVector(x: 0.9, y: 0, z: 0, w: 0),
                                                  "inputGVector": CIVector(x: 0, y: 0.98, z: 0, w: 0),
                                                  "inputBVector": CIVector(x: 0, y: 0, z: 1.12, w: 0)])
        case .noir:
            return apply("CIPhotoEffectNoir", image, [:])
        case .retro:
            let blocky = apply("CIPixellate", image, [kCIInputScaleKey: 5, kCIInputCenterKey: CIVector(x: 0, y: 0)])
            return apply("CIColorPosterize", blocky, ["inputLevels": 10])
        case .dream:
            let glow = apply("CIBloom", image, [kCIInputRadiusKey: 16, kCIInputIntensityKey: 0.9])
            return apply("CIColorControls", glow, [kCIInputSaturationKey: 1.15, kCIInputBrightnessKey: 0.02])
        }
    }
}

// MARK: - Particles

/// Little bits that fly, fall and fade: fire, rain, confetti. Small cubes,
/// drawn with one shared mesh and a material per colour, and recycled
/// rather than made and thrown away.
@MainActor
final class ParticleField {

    private struct Particle {
        var entity: ModelEntity
        var velocity: SIMD3<Float>
        var age: Float
        var life: Float
        var size: SIMD3<Float>
        var shrinks: Bool
        var gravity: Float
    }

    private struct Stream {
        var kind: ParticleKind
        var position: Vec3
        var rate: Float
        var remaining: Double
        var color: ColorRGBA?
        var carry: Float = 0
    }

    let root = Entity()
    private var live: [Particle] = []
    private var pool: [ModelEntity] = []
    private var streams: [Stream] = []
    private var materials: [String: RealityKit.Material] = [:]
    private static let cube = MeshResource.generateBox(size: 1)
    /// Most bits alive at once; the graphics setting lowers it.
    var budget = 600
    /// Carried-over fractions of a bit, per steady source.
    private var carry: [String: Float] = [:]

    init(parent: Entity) {
        root.name = "ablox.particles"
        parent.addChild(root)
    }

    func removeAll() {
        for particle in live { particle.entity.removeFromParent() }
        for entity in pool { entity.removeFromParent() }
        live.removeAll()
        pool.removeAll()
        streams.removeAll()
    }

    /// A script's puff, or a few seconds of them.
    func burst(_ burst: ParticleBurst) {
        if burst.seconds > 0 {
            streams.append(Stream(kind: burst.kind, position: burst.position, rate: Float(burst.amount),
                                  remaining: burst.seconds, color: burst.color))
        } else {
            emit(burst.kind, at: burst.position, count: burst.amount, color: burst.color)
        }
    }

    /// A steady source (a burning block, the rain): `rate` a second, kept
    /// smooth across frames by `key`.
    func stream(_ kind: ParticleKind, key: String, at position: Vec3, rate: Float, spread: Vec3 = .zero, dt: Float,
                color: ColorRGBA? = nil) {
        var amount = (carry[key] ?? 0) + rate * dt
        let whole = Int(amount)
        amount -= Float(whole)
        carry[key] = amount
        if whole > 0 { emit(kind, at: position, count: whole, color: color, spread: spread) }
    }

    func emit(_ kind: ParticleKind, at position: Vec3, count: Int, color: ColorRGBA?, spread: Vec3 = .zero) {
        let spec = kind.spec
        let room = budget - live.count
        guard room > 0 else { return }
        for _ in 0..<min(count, room) {
            let tint: ColorRGBA = color ?? spec.colors.randomElement() ?? ColorRGBA(r: 1, g: 1, b: 1)
            let entity: ModelEntity = pool.popLast() ?? ModelEntity(mesh: Self.cube, materials: [])
            entity.model?.materials = [material(tint, glows: spec.glows)]
            entity.isEnabled = true
            if entity.parent == nil { root.addChild(entity) }
            live.append(launch(entity, kind: kind, spec: spec, from: position, spread: spread))
        }
    }

    /// Sets one particle off: its direction, place, size and turn. In typed
    /// steps, which the compiler checks far faster than the vector sums
    /// written inline.
    private func launch(_ entity: ModelEntity, kind: ParticleKind, spec: ParticleSpec, from position: Vec3, spread: Vec3) -> Particle {
        let angle: Float = Float.random(in: 0...(2 * .pi))
        let widest: Float = Swift.max(0.001, spec.spread)
        let tilt: Float = Float.random(in: 0...widest) * .pi / 180
        let direction = SIMD3<Float>(sin(tilt) * cos(angle), cos(tilt), sin(tilt) * sin(angle))
        let push: Float = spec.speed * Float.random(in: 0.6...1.2)
        let velocity: SIMD3<Float> = direction * push + SIMD3<Float>(0, spec.upward, 0)
        let dx: Float = Float.random(in: -1...1) * spread.x
        let dy: Float = Float.random(in: -1...1) * spread.y
        let dz: Float = Float.random(in: -1...1) * spread.z
        entity.position = position.simd + SIMD3<Float>(dx, dy, dz)
        let base: Float = spec.size * Float.random(in: 0.7...1.3)
        // Rain is a streak, not a drop.
        let size: SIMD3<Float> = kind == .rain ? SIMD3<Float>(base * 0.6, base * 8, base * 0.6) : SIMD3<Float>(repeating: base)
        entity.scale = size
        if kind == .rain {
            entity.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        } else {
            let spin: Float = Float.random(in: 0...(2 * .pi))
            entity.orientation = simd_quatf(angle: spin, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.5)))
        }
        let life: Float = Float.random(in: spec.lifetime)
        return Particle(entity: entity, velocity: velocity, age: 0, life: life, size: size, shrinks: spec.shrinks, gravity: spec.gravity)
    }

    func update(dt: Float) {
        for index in streams.indices {
            streams[index].remaining -= Double(dt)
            var amount = streams[index].carry + streams[index].rate * dt
            let whole = Int(amount)
            amount -= Float(whole)
            streams[index].carry = amount
            if whole > 0 {
                emit(streams[index].kind, at: streams[index].position, count: whole, color: streams[index].color)
            }
        }
        streams.removeAll { $0.remaining <= 0 }

        guard !live.isEmpty else { return }
        var index = 0
        while index < live.count {
            live[index].age += dt
            if live[index].age >= live[index].life {
                let entity = live[index].entity
                entity.isEnabled = false
                pool.append(entity)
                live.swapAt(index, live.count - 1)
                live.removeLast()
                continue
            }
            live[index].velocity.y += live[index].gravity * dt
            let entity = live[index].entity
            entity.position += live[index].velocity * dt
            if live[index].shrinks {
                entity.scale = live[index].size * max(0.05, 1 - live[index].age / live[index].life)
            }
            index += 1
        }
    }

    private func material(_ color: ColorRGBA, glows: Bool) -> RealityKit.Material {
        let key = color.hexString + (glows ? "*" : "")
        if let cached = materials[key] { return cached }
        let tint = UIColor(red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: 1)
        let made: RealityKit.Material = glows ? UnlitMaterial(color: tint) : SimpleMaterial(color: tint, isMetallic: false)
        if materials.count > 128 { materials.removeAll() }
        materials[key] = made
        return made
    }
}

// MARK: - The way to go

/// The arrow a script points with `p.waypoint(…)`: a pin over the place when
/// it is on screen, an arrow at the edge pointing round when it is not.
final class WaypointOverlay: UIView {
    private let pin = UIImageView(image: UIImage(systemName: "mappin.circle.fill"))
    private let arrow = UIImageView(image: UIImage(systemName: "location.north.fill"))
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for image in [pin, arrow] {
            image.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
            image.contentMode = .scaleAspectFit
            image.layer.shadowColor = UIColor.black.cgColor
            image.layer.shadowOpacity = 0.6
            image.layer.shadowRadius = 3
            image.layer.shadowOffset = .zero
            addSubview(image)
        }
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        addSubview(label)
        hide()
    }

    required init?(coder: NSCoder) { nil }

    func hide() {
        pin.isHidden = true
        arrow.isHidden = true
        label.isHidden = true
    }

    /// `onScreen`: where the place is drawn, when it is in view. `angle`:
    /// which way round the edge it lies, in radians from straight up.
    func show(_ waypoint: Waypoint, distance: Float, onScreen: CGPoint?, angle: CGFloat) {
        let color = waypoint.color.map { UIColor(red: CGFloat($0.r), green: CGFloat($0.g), blue: CGFloat($0.b), alpha: 1) }
            ?? UIColor(red: 1, green: 0.84, blue: 0.2, alpha: 1)
        pin.tintColor = color
        arrow.tintColor = color
        let metres = Int(distance.rounded())
        label.text = waypoint.label.isEmpty ? " \(metres) m " : " \(waypoint.label) · \(metres) m "
        label.sizeToFit()
        label.isHidden = false

        let point: CGPoint
        if let onScreen {
            point = onScreen
            pin.isHidden = false
            arrow.isHidden = true
            pin.center = CGPoint(x: point.x, y: point.y - 17)
        } else {
            let inset = bounds.insetBy(dx: 60, dy: 70)
            point = CGPoint(x: bounds.midX + sin(angle) * inset.width / 2, y: bounds.midY - cos(angle) * inset.height / 2)
            pin.isHidden = true
            arrow.isHidden = false
            arrow.center = point
            arrow.transform = CGAffineTransform(rotationAngle: angle)
        }
        label.center = CGPoint(x: point.x, y: point.y + 24)
    }
}
