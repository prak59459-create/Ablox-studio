import UIKit

/// Names (and titles) over people's heads, and the emoji stamps they send.
///
/// Laid over the 3D view like the chat bubbles, and for the same reasons: a
/// view faces the camera by definition, and text in a view is sharp at any
/// size in any script.
@MainActor
final class NameTagOverlay: UIView {

    struct Tag {
        let id: PeerID
        let name: String
        let title: String
        /// Just above the head, on screen.
        let anchor: CGPoint
        let distance: Float
        let isNPC: Bool
    }

    /// How long a stamp floats before it has gone.
    static let stampLifetime: TimeInterval = 2.6

    private var labels: [PeerID: TagView] = [:]
    private var stamps: [PeerID: (emoji: String, since: Date)] = [:]
    private var stampViews: [PeerID: UILabel] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func showStamp(_ emoji: String, for peer: PeerID) {
        stamps[peer] = (emoji, Date())
    }

    /// Exactly these tags this frame; stamps float over the same anchors.
    func update(_ tags: [Tag], showNames: Bool) {
        var seen = Set<PeerID>()
        let now = Date()
        for tag in tags.sorted(by: { $0.distance > $1.distance }) {
            seen.insert(tag.id)
            let scale = CGFloat(max(0.55, min(1.1, 14 / max(tag.distance, 1))))
            // NPCs are named only up close; players to a good distance.
            let nameVisible = showNames && !tag.name.isEmpty && tag.distance < (tag.isNPC ? 18 : 45)
            if nameVisible {
                let view = labels[tag.id] ?? {
                    let made = TagView()
                    addSubview(made)
                    labels[tag.id] = made
                    return made
                }()
                view.set(name: tag.name, title: tag.title)
                view.transform = CGAffineTransform(scaleX: scale, y: scale)
                view.center = CGPoint(x: tag.anchor.x, y: tag.anchor.y - view.bounds.height * scale / 2)
            } else if let view = labels.removeValue(forKey: tag.id) {
                view.removeFromSuperview()
            }

            if let stamp = stamps[tag.id] {
                let age = now.timeIntervalSince(stamp.since)
                if age > Self.stampLifetime {
                    stamps[tag.id] = nil
                    stampViews.removeValue(forKey: tag.id)?.removeFromSuperview()
                } else {
                    let view = stampViews[tag.id] ?? {
                        let label = UILabel()
                        label.font = .systemFont(ofSize: 44)
                        label.textAlignment = .center
                        addSubview(label)
                        stampViews[tag.id] = label
                        return label
                    }()
                    view.text = stamp.emoji
                    view.sizeToFit()
                    // Pops up, floats up a little, fades at the end.
                    let pop = CGFloat(min(1, age / 0.18))
                    let rise = CGFloat(age) * 18
                    view.transform = CGAffineTransform(scaleX: pop * scale, y: pop * scale)
                    view.center = CGPoint(x: tag.anchor.x, y: tag.anchor.y - 44 * scale - rise)
                    view.alpha = CGFloat(min(1, (Self.stampLifetime - age) / 0.5))
                }
            }
        }
        for (id, view) in labels where !seen.contains(id) {
            view.removeFromSuperview()
            labels.removeValue(forKey: id)
        }
        for (id, view) in stampViews where !seen.contains(id) {
            view.removeFromSuperview()
            stampViews.removeValue(forKey: id)
        }
    }

    func removeAll() {
        for view in labels.values { view.removeFromSuperview() }
        for view in stampViews.values { view.removeFromSuperview() }
        labels.removeAll()
        stampViews.removeAll()
        stamps.removeAll()
    }
}

/// A name, and a title under it, on a dark rounded card.
private final class TagView: UIView {
    private let name = UILabel()
    private let title = UILabel()
    private var shown: (String, String)?

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.42)
        layer.cornerRadius = 8
        name.font = .systemFont(ofSize: 13, weight: .bold)
        name.textColor = .white
        name.textAlignment = .center
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = UIColor(red: 1, green: 0.84, blue: 0.3, alpha: 1)
        title.textAlignment = .center
        addSubview(name)
        addSubview(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func set(name text: String, title subtitle: String) {
        guard shown?.0 != text || shown?.1 != subtitle else { return }
        shown = (text, subtitle)
        name.text = text
        title.text = subtitle
        title.isHidden = subtitle.isEmpty
        let nameSize = name.sizeThatFits(CGSize(width: 220, height: 40))
        let titleSize = subtitle.isEmpty ? .zero : title.sizeThatFits(CGSize(width: 220, height: 30))
        let width = min(220, max(nameSize.width, titleSize.width) + 16)
        let height = nameSize.height + (subtitle.isEmpty ? 0 : titleSize.height) + 6
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        name.frame = CGRect(x: 0, y: 3, width: width, height: nameSize.height)
        title.frame = CGRect(x: 0, y: 3 + nameSize.height, width: width, height: titleSize.height)
    }
}
