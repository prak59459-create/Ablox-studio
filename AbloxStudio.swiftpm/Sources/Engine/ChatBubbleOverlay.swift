import UIKit

/// Speech bubbles over people's heads, as in Roblox: a white card with what
/// they said, always turned to face you, gone after a few seconds.
///
/// Drawn as UIKit views laid over the 3D view rather than as entities in the
/// scene. A view on the screen faces the camera by definition — RealityKit's
/// `BillboardComponent` needs iPadOS 18, and Ablox runs on 17 — and text in a
/// view is sharp at every size and in every script, Japanese included, where
/// text baked into a texture would blur up close and need re-rendering for
/// every message.
@MainActor
final class ChatBubbleOverlay: UIView {

    /// How long a message stays up, the last second of it fading.
    static let lifetime: TimeInterval = 8
    static let fadeTime: TimeInterval = 1
    /// Older lines stack above the newest, as many as this.
    static let linesPerSpeaker = 3

    struct Message: Equatable {
        let id: UUID
        let text: String
        /// Seconds since it was said.
        let age: TimeInterval
    }

    /// One speaker, this frame.
    struct Speaker {
        let id: PeerID
        /// Oldest first.
        let messages: [Message]
        /// The point on screen just above their head.
        let anchor: CGPoint
        /// From the camera, in metres: far bubbles are drawn smaller.
        let distance: Float
    }

    private var stacks: [PeerID: SpeakerStack] = [:]

    var isShowingAnything: Bool { !stacks.isEmpty }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows exactly these speakers; anyone not listed has their bubbles
    /// taken down.
    func update(_ speakers: [Speaker]) {
        var seen = Set<PeerID>()
        // Farthest first, so a nearer speaker's bubble is drawn on top.
        for speaker in speakers.sorted(by: { $0.distance > $1.distance }) {
            seen.insert(speaker.id)
            let stack: SpeakerStack
            if let existing = stacks[speaker.id] {
                stack = existing
            } else {
                stack = SpeakerStack()
                addSubview(stack)
                stacks[speaker.id] = stack
            }
            stack.show(speaker.messages)
            stack.place(at: speaker.anchor, scale: Self.scale(forDistance: speaker.distance))
            bringSubviewToFront(stack)
        }
        for (id, stack) in stacks where !seen.contains(id) {
            stack.removeFromSuperview()
            stacks.removeValue(forKey: id)
        }
    }

    func removeAll() {
        for stack in stacks.values { stack.removeFromSuperview() }
        stacks.removeAll()
    }

    /// Full size up close, shrinking with distance so a crowd far away does
    /// not cover the screen — but never so small it cannot be read.
    static func scale(forDistance distance: Float) -> CGFloat {
        let near: Float = 10
        let far: Float = 45
        guard distance > near else { return 1 }
        let t = min(1, (distance - near) / (far - near))
        return CGFloat(1 - t * 0.45)
    }
}

// MARK: - One speaker's bubbles

/// The bubbles over one head, newest at the bottom with the tail.
@MainActor
private final class SpeakerStack: UIView {

    private var bubbles: [UUID: BubbleView] = [:]
    private var order: [UUID] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        // Positioned by its bottom middle: that is the point over the head.
        layer.anchorPoint = CGPoint(x: 0.5, y: 1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ messages: [ChatBubbleOverlay.Message]) {
        let ids = messages.map(\.id)
        if ids != order {
            rebuild(messages)
        }
        // Fading is the only thing that changes frame to frame.
        for (index, message) in messages.enumerated() {
            guard let bubble = bubbles[message.id] else { continue }
            let remaining = ChatBubbleOverlay.lifetime - message.age
            var alpha = CGFloat(max(0, min(1, remaining / ChatBubbleOverlay.fadeTime)))
            // Older lines sit back a little, so the newest reads first.
            if index < messages.count - 1 { alpha *= 0.82 }
            if bubble.alpha != alpha { bubble.alpha = alpha }
        }
    }

    private func rebuild(_ messages: [ChatBubbleOverlay.Message]) {
        let ids = Set(messages.map(\.id))
        for (id, bubble) in bubbles where !ids.contains(id) {
            bubble.removeFromSuperview()
            bubbles.removeValue(forKey: id)
        }
        for message in messages where bubbles[message.id] == nil {
            let bubble = BubbleView(text: message.text)
            addSubview(bubble)
            bubbles[message.id] = bubble
        }
        order = messages.map(\.id)

        // Lay out bottom-up: the newest just over the head, with the tail.
        let spacing: CGFloat = 5
        var sizes: [CGSize] = []
        for (index, id) in order.enumerated() {
            let bubble = bubbles[id]!
            bubble.showsTail = index == order.count - 1
            sizes.append(bubble.fittedSize)
        }
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var y: CGFloat = 0
        for (index, id) in order.enumerated() {
            let size = sizes[index]
            bubbles[id]!.frame = CGRect(x: (width - size.width) / 2, y: y, width: size.width, height: size.height)
            y += size.height + spacing
        }
    }

    func place(at point: CGPoint, scale: CGFloat) {
        // `bounds` and `layer.position`, never `frame`: the frame of a view
        // with a transform is not defined.
        if layer.position != point { layer.position = point }
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        if self.transform != transform { self.transform = transform }
    }
}

// MARK: - One bubble

/// A white rounded card with dark text and a little tail pointing down.
@MainActor
private final class BubbleView: UIView {

    private static let maxTextWidth: CGFloat = 230
    private static let padding = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
    private static let tailSize = CGSize(width: 14, height: 8)

    private let label = UILabel()
    private let card = UIView()
    private let tail = CAShapeLayer()

    var showsTail = true {
        didSet {
            tail.isHidden = !showsTail
            setNeedsLayout()
        }
    }

    init(text: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        card.backgroundColor = .white
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        // A soft edge so a white bubble still reads against a white sky.
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.25
        card.layer.shadowRadius = 3
        card.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(card)

        label.text = text
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = UIColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1)
        label.numberOfLines = 4
        label.lineBreakMode = .byTruncatingTail
        label.textAlignment = .center
        card.addSubview(label)

        tail.fillColor = UIColor.white.cgColor
        layer.addSublayer(tail)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private var textSize: CGSize {
        let fitted = label.sizeThatFits(CGSize(width: Self.maxTextWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(Self.maxTextWidth, ceil(fitted.width)), height: ceil(fitted.height))
    }

    /// The whole bubble, tail included.
    var fittedSize: CGSize {
        let text = textSize
        let padding = Self.padding
        return CGSize(
            width: max(36, text.width + padding.left + padding.right),
            height: text.height + padding.top + padding.bottom + (showsTail ? Self.tailSize.height : 0)
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let tailHeight = showsTail ? Self.tailSize.height : 0
        card.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - tailHeight)
        label.frame = card.bounds.inset(by: Self.padding)

        let path = UIBezierPath()
        let midX = bounds.width / 2
        let top = card.frame.maxY - 1
        path.move(to: CGPoint(x: midX - Self.tailSize.width / 2, y: top))
        path.addLine(to: CGPoint(x: midX + Self.tailSize.width / 2, y: top))
        path.addLine(to: CGPoint(x: midX, y: top + Self.tailSize.height + 1))
        path.close()
        tail.path = path.cgPath
    }
}
