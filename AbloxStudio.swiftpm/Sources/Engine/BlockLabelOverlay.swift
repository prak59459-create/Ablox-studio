import UIKit

/// Words floating over blocks (`BlockLabel`): a sign's text, a price, a
/// pet's name with its rarity above and its earnings below.
///
/// Laid over the 3D view like the name tags, for the same reasons: a view
/// always faces the camera, and text in a view is sharp at any size in any
/// script. Only the nearest few dozen are drawn, nearest on top.
@MainActor
final class BlockLabelOverlay: UIView {

    struct Item {
        let id: UUID
        let label: BlockLabel
        /// Just above the block, on screen.
        let anchor: CGPoint
        let distance: Float
    }

    /// More than this at once would cost frames and say nothing more. The
    /// graphics level lowers it (`GraphicsProfile.labelLimit`).
    var maximumShown = 48

    private var views: [UUID: BlockLabelView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Exactly these labels this frame.
    func update(_ items: [Item]) {
        let nearest = items.sorted { $0.distance < $1.distance }.prefix(maximumShown)
        var seen = Set<UUID>()
        for item in nearest {
            seen.insert(item.id)
            let view = views[item.id] ?? {
                let made = BlockLabelView()
                addSubview(made)
                views[item.id] = made
                return made
            }()
            view.show(item.label)
            // Each step typed: mixed Float and CGFloat arithmetic in one
            // nested expression is slow for the compiler to resolve.
            let distance: Float = item.distance
            let range: Float = item.label.range
            // Smaller with distance, but never too small to read.
            let nearness: Float = 16 / Swift.max(distance, 1)
            let fade: Float = Swift.max(0.5, Swift.min(1.25, nearness))
            let scale: CGFloat = CGFloat(fade * item.label.size)
            view.transform = CGAffineTransform(scaleX: scale, y: scale)
            let lift: CGFloat = view.bounds.height * scale / 2
            view.center = CGPoint(x: item.anchor.x, y: item.anchor.y - lift)
            // Nearer words over farther ones.
            view.layer.zPosition = CGFloat(-distance)
            // Fades out over the last part of its range rather than popping.
            let fadeLength: Float = Swift.max(range * 0.15, 1)
            let left: Float = (range - distance) / fadeLength
            view.alpha = CGFloat(Swift.min(1, Swift.max(0, left)))
        }
        for (id, view) in views where !seen.contains(id) {
            view.removeFromSuperview()
            views.removeValue(forKey: id)
        }
    }

    func removeAll() {
        for view in views.values { view.removeFromSuperview() }
        views.removeAll()
    }
}

/// The lines, centred, bold, each in its colour with a dark outline so they
/// read over a bright sky or a dark floor alike.
private final class BlockLabelView: UIView {
    private var labels: [UILabel] = []
    private var shown: BlockLabel?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ label: BlockLabel) {
        guard label != shown else { return }
        shown = label
        for view in labels { view.removeFromSuperview() }
        labels = label.lines.map { line in
            let view = UILabel()
            view.attributedText = NSAttributedString(string: line.text, attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .heavy),
                .foregroundColor: UIColor(red: CGFloat(line.color.r), green: CGFloat(line.color.g), blue: CGFloat(line.color.b), alpha: 1),
                .strokeColor: UIColor.black.withAlphaComponent(0.85),
                .strokeWidth: -3.5
            ])
            view.textAlignment = .center
            view.sizeToFit()
            addSubview(view)
            return view
        }
        let width = labels.map(\.bounds.width).max() ?? 0
        var y: CGFloat = 0
        for view in labels {
            view.frame = CGRect(x: (width - view.bounds.width) / 2, y: y, width: view.bounds.width, height: view.bounds.height)
            y += view.bounds.height - 2
        }
        bounds = CGRect(x: 0, y: 0, width: width, height: max(y + 2, 0))
    }
}
