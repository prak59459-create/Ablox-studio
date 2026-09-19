import Foundation

/// A cover picture drawn from the world itself.
///
/// Publishing needs a picture, and the honest options were asking for one —
/// which means a photo library, a picker, and a blank card for anyone who
/// skips it — or drawing one. Drawing one means every published game has a
/// cover, it is always of the actual world, and it never goes stale.
///
/// This is the geometry: which rectangle each block occupies on the card, in
/// what order, in what colour. The drawing itself is a dozen lines of
/// `UIGraphicsImageRenderer` in the view layer. Keeping the layout here means
/// the part that can be wrong in an invisible way — a world that maps to
/// nothing, or to one pixel, or off the edge of the card — is tested.
///
/// It is a plan view: looking straight down, tallest last. Not a render. A
/// perspective view of a world with no lighting set up looks worse than an
/// honest diagram, and a diagram reads at the size a card is actually shown.
public struct CoverArtwork: Equatable, Sendable {

    public struct Shape: Equatable, Sendable {
        /// In card coordinates: 0,0 is top-left, sizes are in points.
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var color: ColorRGBA
        /// Drawn on top of everything, with a ring, so the route reads.
        public var isLandmark: Bool

        public init(x: Double, y: Double, width: Double, height: Double, color: ColorRGBA, isLandmark: Bool) {
            self.x = x; self.y = y; self.width = width; self.height = height
            self.color = color; self.isLandmark = isLandmark
        }
    }

    /// 16:9, the shape the card is shown at.
    public static let size = (width: 1_200.0, height: 675.0)

    /// Space left around the world so nothing touches the edge.
    public static let inset = 48.0

    /// Below this, a block is a smudge; it is drawn at this size instead so a
    /// row of coins does not vanish.
    public static let minimumShapeSize = 6.0

    public var shapes: [Shape]
    public var background: ColorRGBA

    public init(shapes: [Shape], background: ColorRGBA) {
        self.shapes = shapes
        self.background = background
    }

    /// Lays a world out on the card.
    public static func make(from world: WorldDocument) -> CoverArtwork {
        let visible = world.blocks.filter(\.isVisible)
        guard !visible.isEmpty else {
            return CoverArtwork(shapes: [], background: world.environment.skyBottom)
        }

        // The footprint of everything, in world XZ.
        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude

        for block in visible {
            let halfWidth = abs(block.scale.x) / 2
            let halfDepth = abs(block.scale.z) / 2
            minX = Swift.min(minX, block.position.x - halfWidth)
            maxX = Swift.max(maxX, block.position.x + halfWidth)
            minZ = Swift.min(minZ, block.position.z - halfDepth)
            maxZ = Swift.max(maxZ, block.position.z + halfDepth)
        }

        // A world one block wide would divide by zero and, scaled to fit,
        // would fill the card with a single colour.
        let worldWidth = Swift.max(1, Double(maxX - minX))
        let worldDepth = Swift.max(1, Double(maxZ - minZ))

        let usableWidth = size.width - inset * 2
        let usableHeight = size.height - inset * 2

        // One scale for both axes, so a long thin world stays long and thin
        // rather than being stretched into the card's proportions.
        let scale = Swift.min(usableWidth / worldWidth, usableHeight / worldDepth)

        // Centred in whatever room is left over.
        let originX = inset + (usableWidth - worldWidth * scale) / 2
        let originY = inset + (usableHeight - worldDepth * scale) / 2

        // Lowest first, so a platform does not cover the goal standing on it.
        // Landmarks last regardless of height — they are the point of the
        // picture.
        let ordered = visible.sorted { a, b in
            let aLandmark = isLandmark(a.behavior)
            let bLandmark = isLandmark(b.behavior)
            if aLandmark != bLandmark { return !aLandmark }
            return a.position.y < b.position.y
        }

        let shapes = ordered.map { block -> Shape in
            let width = Swift.max(minimumShapeSize, Double(abs(block.scale.x)) * scale)
            let depth = Swift.max(minimumShapeSize, Double(abs(block.scale.z)) * scale)

            // Centre-based in the world, corner-based on the card.
            let centreX = originX + (Double(block.position.x) - Double(minX)) * scale
            let centreY = originY + (Double(block.position.z) - Double(minZ)) * scale

            return Shape(
                x: centreX - width / 2,
                y: centreY - depth / 2,
                width: width,
                height: depth,
                color: block.color,
                isLandmark: isLandmark(block.behavior)
            )
        }

        return CoverArtwork(shapes: shapes, background: world.environment.skyBottom)
    }

    /// The things worth picking out of a plan view: where you start, where you
    /// are going, and what will kill you.
    static func isLandmark(_ behavior: BlockBehavior) -> Bool {
        switch behavior {
        case .spawn, .goal, .checkpoint, .hazard, .collectible:
            return true
        case .none, .trigger, .bounce, .disappear, .teleport:
            return false
        }
    }

    /// Everything fits on the card, which is the property a drawing routine
    /// cannot check for itself.
    public var fitsOnTheCard: Bool {
        shapes.allSatisfy { shape in
            shape.x >= -0.5
                && shape.y >= -0.5
                && shape.x + shape.width <= CoverArtwork.size.width + 0.5
                && shape.y + shape.height <= CoverArtwork.size.height + 0.5
        }
    }
}
