import Foundation
import RealityKit
import UIKit
import CoreGraphics
import Metal
import AbloxCore

/// Pictures the engine paints for itself: the patterns of the natural
/// materials (wood grain, bricks, grass…), the sky, and the pictures a world
/// carries for its blocks.
///
/// Patterns are grey, so the block's own colour tints them — a red brick
/// wall and a white one share one texture. Everything is made once and kept.
enum SurfaceTextures {

    private static var patterns: [SurfacePattern: TextureResource] = [:]
    private static var pictures: [UUID: (data: Data, texture: TextureResource)] = [:]
    private static let lock = NSLock()

    /// Repeats rather than stretching at the edges.
    static var repeatingSampler: MaterialParameters.Texture.Sampler {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        return MaterialParameters.Texture.Sampler(descriptor)
    }

    /// A sine wave across `over` points, `cycles` times, moved by `shift`.
    /// A function of its own so the drawing code stays quick to compile.
    private static func wave(_ x: CGFloat, over length: CGFloat, cycles: CGFloat, shift: CGFloat) -> CGFloat {
        let turns: CGFloat = x / length * cycles
        let angle: CGFloat = turns * CGFloat.pi + shift
        return sin(angle)
    }

    // MARK: Meaning marks

    private static var marks: [MeaningMark: TextureResource] = [:]

    /// Stripes for danger, checks for a goal: dark lines over white, so the
    /// part's own colour still shows through the tint.
    static func texture(for mark: MeaningMark) -> TextureResource? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = marks[mark] { return cached }
        let size: CGFloat = 128
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: size, height: size))
            cg.setFillColor(UIColor(white: 0.12, alpha: 1).cgColor)
            switch mark {
            case .danger:
                // Two diagonal bands that meet at the edges, so the stripes
                // run on unbroken from one tile into the next.
                for start in stride(from: -size, to: size * 2, by: size / 2) {
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: start, y: 0))
                    path.addLine(to: CGPoint(x: start + size / 4, y: 0))
                    path.addLine(to: CGPoint(x: start + size / 4 - size, y: size))
                    path.addLine(to: CGPoint(x: start - size, y: size))
                    path.closeSubpath()
                    cg.addPath(path)
                }
                cg.fillPath()
            case .goal:
                let cell = size / 4
                for row in 0..<4 {
                    for column in 0..<4 where (row + column) % 2 == 0 {
                        cg.fill(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                    }
                }
            }
        }
        guard let cgImage = image.cgImage,
              let texture = try? TextureResource.generate(from: cgImage, options: .init(semantic: .color)) else { return nil }
        marks[mark] = texture
        return texture
    }

    // MARK: Material patterns

    static func texture(for pattern: SurfacePattern) -> TextureResource? {
        guard pattern != .none else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = patterns[pattern] { return cached }
        guard let image = draw(pattern),
              let texture = try? TextureResource.generate(from: image, options: .init(semantic: .color)) else { return nil }
        patterns[pattern] = texture
        return texture
    }

    private static func draw(_ pattern: SurfacePattern) -> CGImage? {
        let size = 128
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return format
        }())
        // The same pattern on every iPad, every time.
        var random = SeededRandom(seed: UInt64(pattern.rawValue.unicodeScalars.reduce(7) { $0 &* 31 &+ UInt64($1.value) }))
        let image = renderer.image { context in
            let cg = context.cgContext
            let full = CGRect(x: 0, y: 0, width: size, height: size)
            func grey(_ value: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
                UIColor(white: value, alpha: alpha).cgColor
            }
            switch pattern {
            case .none:
                cg.setFillColor(grey(1))
                cg.fill(full)
            case .grain:
                cg.setFillColor(grey(0.93))
                cg.fill(full)
                // Long wavy lines along the board, and a knot.
                for line in 0..<18 {
                    let y = CGFloat(line) * 7.1 + CGFloat(random.next(in: 0...3))
                    cg.setStrokeColor(grey(0.72 + CGFloat(random.next(in: 0...0.12)), 0.9))
                    cg.setLineWidth(CGFloat(random.next(in: 0.8...2.2)))
                    cg.move(to: CGPoint(x: 0, y: y))
                    var x: CGFloat = 0
                    while x < CGFloat(size) {
                        x += 16
                        cg.addLine(to: CGPoint(x: x, y: y + CGFloat(random.next(in: -1.6...1.6))))
                    }
                    cg.strokePath()
                }
                cg.setStrokeColor(grey(0.66))
                cg.setLineWidth(1.5)
                cg.strokeEllipse(in: CGRect(x: 80, y: 44, width: 14, height: 8))
            case .speckle:
                cg.setFillColor(grey(0.9))
                cg.fill(full)
                for _ in 0..<420 {
                    let dot = CGFloat(random.next(in: 1...3.5))
                    cg.setFillColor(grey(CGFloat(random.next(in: 0.62...1)), 0.8))
                    cg.fillEllipse(in: CGRect(x: CGFloat(random.next(in: 0...128)), y: CGFloat(random.next(in: 0...128)),
                                              width: dot, height: dot))
                }
            case .bricks:
                cg.setFillColor(grey(0.62))
                cg.fill(full)
                let rows = 8
                let height = CGFloat(size) / CGFloat(rows)
                for row in 0..<rows {
                    let shift: CGFloat = row % 2 == 0 ? 0 : 16
                    var x = -32 + shift
                    while x < CGFloat(size) {
                        cg.setFillColor(grey(0.86 + CGFloat(random.next(in: -0.06...0.08))))
                        cg.fill(CGRect(x: x + 1.5, y: CGFloat(row) * height + 1.5, width: 32 - 3, height: height - 3))
                        x += 32
                    }
                }
            case .blades:
                cg.setFillColor(grey(0.82))
                cg.fill(full)
                for _ in 0..<520 {
                    let x = CGFloat(random.next(in: 0...128))
                    let y = CGFloat(random.next(in: 0...128))
                    cg.setStrokeColor(grey(CGFloat(random.next(in: 0.7...1)), 0.9))
                    cg.setLineWidth(1.2)
                    cg.move(to: CGPoint(x: x, y: y))
                    cg.addLine(to: CGPoint(x: x + CGFloat(random.next(in: -2...2)), y: y - CGFloat(random.next(in: 3...7))))
                    cg.strokePath()
                }
            case .cracks:
                cg.setFillColor(grey(0.97))
                cg.fill(full)
                cg.setStrokeColor(grey(0.8, 0.9))
                cg.setLineWidth(1)
                for _ in 0..<7 {
                    var point = CGPoint(x: CGFloat(random.next(in: 0...128)), y: CGFloat(random.next(in: 0...128)))
                    cg.move(to: point)
                    for _ in 0..<5 {
                        point.x += CGFloat(random.next(in: -18...18))
                        point.y += CGFloat(random.next(in: -18...18))
                        cg.addLine(to: point)
                    }
                    cg.strokePath()
                }
            case .ripples:
                cg.setFillColor(grey(0.9))
                cg.fill(full)
                for line in 0..<14 {
                    let y = CGFloat(line) * 9.3
                    cg.setStrokeColor(grey(1, 0.8))
                    cg.setLineWidth(2)
                    cg.move(to: CGPoint(x: 0, y: y))
                    var x: CGFloat = 0
                    while x <= CGFloat(size) {
                        cg.addLine(to: CGPoint(x: x, y: y + wave(x, over: 128, cycles: 4, shift: CGFloat(line)) * 2.5))
                        x += 4
                    }
                    cg.strokePath()
                }
            }
        }
        return image.cgImage
    }

    // MARK: Pictures from the world

    static func texture(for picture: WorldImage) -> TextureResource? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = pictures[picture.id], cached.data == picture.data { return cached.texture }
        guard picture.isAcceptable, let image = UIImage(data: picture.data)?.cgImage,
              let texture = try? TextureResource.generate(from: image, options: .init(semantic: .color)) else { return nil }
        if pictures.count > 64 { pictures.removeAll() }
        pictures[picture.id] = (picture.data, texture)
        return texture
    }

    // MARK: The sky

    /// The inside of the sky: the top of the picture is straight up, the
    /// middle the horizon. Decorated by style; `night` (0 to 1) brings the
    /// stars out.
    static func sky(style: SkyStyle, top: ColorRGBA, bottom: ColorRGBA, night: Float) -> TextureResource? {
        let width = 512
        let height = 256
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        var random = SeededRandom(seed: 42)
        func ui(_ color: ColorRGBA, alpha: CGFloat = 1) -> UIColor {
            UIColor(red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: alpha)
        }
        let horizon = CGFloat(height) / 2
        let image = renderer.image { context in
            let cg = context.cgContext
            // Top colour overhead, bottom colour at the horizon and below.
            let colors = [ui(top).cgColor, ui(bottom).cgColor, ui(bottom).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: CGFloat(height)), options: [])
            }

            let starAmount: Float
            switch style {
            case .space: starAmount = 1
            case .stars: starAmount = max(0.55, night)
            default: starAmount = night
            }
            if starAmount > 0.05 {
                let count: Int = style == .space ? 900 : 420
                let biggest: Double = style == .space ? 2.6 : 1.9
                let lowest: Double = Double(horizon) * 0.96
                for _ in 0..<count {
                    let size = CGFloat(random.next(in: 0.6...biggest))
                    let y = CGFloat(random.next(in: 0...lowest))
                    let x = CGFloat(random.next(in: 0...Double(width)))
                    let brightness = CGFloat(random.next(in: 0.35...1))
                    cg.setFillColor(UIColor(white: 1, alpha: CGFloat(starAmount) * brightness).cgColor)
                    cg.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
                }
            }

            switch style {
            case .gradient, .stars:
                break
            case .clouds:
                for _ in 0..<26 {
                    let x = CGFloat(random.next(in: 0...Double(width)))
                    let y = CGFloat(random.next(in: Double(horizon) * 0.35...Double(horizon) * 0.92))
                    let w = CGFloat(random.next(in: 40...110))
                    let alpha = CGFloat(0.55 * (1 - night * 0.6))
                    cg.setFillColor(UIColor(white: 1, alpha: alpha).cgColor)
                    for puff in 0..<4 {
                        cg.fillEllipse(in: CGRect(x: x + CGFloat(puff) * w * 0.22, y: y - CGFloat(puff % 2) * 5,
                                                  width: w * 0.5, height: w * 0.18))
                    }
                }
            case .sunset:
                let warm = [UIColor(red: 1, green: 0.55, blue: 0.25, alpha: 0).cgColor,
                            UIColor(red: 1, green: 0.5, blue: 0.3, alpha: 0.75).cgColor,
                            UIColor(red: 1, green: 0.82, blue: 0.45, alpha: 0.9).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: warm, locations: [0, 0.7, 1]) {
                    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: horizon * 0.45), end: CGPoint(x: 0, y: horizon), options: [])
                }
                cg.setFillColor(UIColor(red: 1, green: 0.9, blue: 0.6, alpha: 1).cgColor)
                cg.fillEllipse(in: CGRect(x: 120, y: horizon - 26, width: 40, height: 40))
            case .aurora:
                for band in 0..<3 {
                    let color = band == 1 ? UIColor(red: 0.6, green: 0.35, blue: 1, alpha: 0.35)
                                          : UIColor(red: 0.3, green: 1, blue: 0.6, alpha: 0.4)
                    cg.setStrokeColor(color.cgColor)
                    cg.setLineWidth(CGFloat(14 - band * 3))
                    let base = horizon * (0.35 + CGFloat(band) * 0.12)
                    cg.move(to: CGPoint(x: 0, y: base))
                    var x: CGFloat = 0
                    while x <= CGFloat(width) {
                        cg.addLine(to: CGPoint(x: x, y: base + wave(x, over: CGFloat(width), cycles: 6, shift: CGFloat(band)) * 12))
                        x += 8
                    }
                    cg.strokePath()
                }
            case .space:
                // A planet, low in the sky.
                cg.setFillColor(UIColor(red: 0.55, green: 0.45, blue: 0.9, alpha: 1).cgColor)
                cg.fillEllipse(in: CGRect(x: 300, y: horizon * 0.4, width: 60, height: 60))
                cg.setStrokeColor(UIColor(red: 0.85, green: 0.8, blue: 1, alpha: 0.8).cgColor)
                cg.setLineWidth(3)
                cg.strokeEllipse(in: CGRect(x: 284, y: horizon * 0.4 + 24, width: 92, height: 14))
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource.generate(from: cgImage, options: .init(semantic: .color))
    }
}

/// A small repeatable random number maker, so a pattern is the same each
/// time it is drawn.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func nextUInt() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextUInt() >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}
