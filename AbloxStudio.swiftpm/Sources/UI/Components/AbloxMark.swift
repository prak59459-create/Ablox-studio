import SwiftUI

/// The Ablox cube, drawn rather than bundled.
///
/// The brand mark is an isometric cube with a square aperture cut through its
/// top face. That is three quadrilaterals and a diamond — a few dozen points
/// of geometry — so it is drawn as a `Shape` instead of shipped as a PNG.
///
/// Drawing it buys three things a bitmap would not:
///
/// - It is sharp at every size, from a 16pt list row to a full-screen splash,
///   with no `@2x`/`@3x` set to keep in sync.
/// - It inherits the foreground style, so the same mark works on the dark
///   sidebar and inverted on a light sheet without a second asset.
/// - It keeps the Playground made of readable Swift. A binary in the bundle is
///   the one thing you cannot inspect or diff on an iPad.
///
/// The app icon is a separate matter — iOS requires a real image file for
/// that, and it cannot be drawn at runtime.
public struct AbloxMark: View {

    /// How the three faces are shaded relative to one another.
    public enum Style {
        /// Light top, mid left, dark right — the mark as it appears on the
        /// icon sheet, reading as a solid object.
        case dimensional
        /// A single flat colour. For small sizes and for tinted contexts where
        /// three shades would turn to mud.
        case flat
    }

    private let style: Style

    public init(style: Style = .dimensional) {
        self.style = style
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                // Painted back to front. The right face is darkest so the
                // light appears to come from the upper left, matching the sheet.
                CubeFace(.right).fill(shade(0.42))
                CubeFace(.left).fill(shade(0.68))
                // Even-odd, not the default non-zero rule: the aperture winds
                // the same direction as the face around it, so under non-zero
                // winding it would fill solid and the hole would vanish.
                CubeFace(.top).fill(shade(1.0), style: FillStyle(eoFill: true))
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Ablox")
    }

    private func shade(_ level: Double) -> some ShapeStyle {
        switch style {
        case .dimensional:
            // Opacity rather than three fixed greys, so the mark takes on
            // whatever foreground colour it is given.
            return AnyShapeStyle(.foreground.opacity(level))
        case .flat:
            return AnyShapeStyle(.foreground)
        }
    }
}

// MARK: - Geometry

/// One face of the isometric cube, in a unit square.
///
/// The aperture is cut only from the top face, which is what gives the mark
/// its keyhole silhouette. Using the even-odd fill rule to punch it out keeps
/// this to a single path rather than a mask.
private struct CubeFace: Shape {
    enum Facing {
        case top, left, right
    }

    private let facing: Facing

    init(_ facing: Facing) {
        self.facing = facing
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height

        // Isometric layout inside the unit square. `midY` is where the two
        // side faces meet the top face at the left and right corners.
        let cx = rect.midX
        let top = rect.minY + h * 0.06
        let upperY = rect.minY + h * 0.30
        let lowerY = rect.minY + h * 0.70
        let bottom = rect.maxY - h * 0.06
        let left = rect.minX + w * 0.08
        let right = rect.maxX - w * 0.08

        var path = Path()

        switch facing {
        case .top:
            let meetY = (upperY - top) + upperY

            // The top rhombus.
            path.move(to: CGPoint(x: cx, y: top))
            path.addLine(to: CGPoint(x: right, y: upperY))
            path.addLine(to: CGPoint(x: cx, y: meetY))
            path.addLine(to: CGPoint(x: left, y: upperY))
            path.closeSubpath()

            // The aperture, as the same rhombus scaled about the face centre.
            // Scaling both half-extents by one factor is what keeps it a
            // similar shape — scaling width and height independently would
            // read as a squashed diamond rather than a hole in the surface.
            let faceCentreY = (top + meetY) / 2
            let halfWidth = (right - left) / 2
            let halfHeight = (meetY - top) / 2
            let scale: CGFloat = 0.34

            path.move(to: CGPoint(x: cx, y: faceCentreY - halfHeight * scale))
            path.addLine(to: CGPoint(x: cx + halfWidth * scale, y: faceCentreY))
            path.addLine(to: CGPoint(x: cx, y: faceCentreY + halfHeight * scale))
            path.addLine(to: CGPoint(x: cx - halfWidth * scale, y: faceCentreY))
            path.closeSubpath()

        case .left:
            let meetY = (upperY - top) + upperY
            path.move(to: CGPoint(x: left, y: upperY))
            path.addLine(to: CGPoint(x: cx, y: meetY))
            path.addLine(to: CGPoint(x: cx, y: bottom))
            path.addLine(to: CGPoint(x: left, y: lowerY))
            path.closeSubpath()

        case .right:
            let meetY = (upperY - top) + upperY
            path.move(to: CGPoint(x: right, y: upperY))
            path.addLine(to: CGPoint(x: right, y: lowerY))
            path.addLine(to: CGPoint(x: cx, y: bottom))
            path.addLine(to: CGPoint(x: cx, y: meetY))
            path.closeSubpath()
        }

        return path
    }
}

// MARK: - Lockup

/// The mark beside the wordmark, as used in the sidebar and the Studio header.
public struct AbloxLockup: View {
    private let showsSubtitle: Bool
    private let subtitle: String
    private let markSize: CGFloat

    public init(subtitle: String = "", markSize: CGFloat = 44) {
        self.subtitle = subtitle
        self.showsSubtitle = !subtitle.isEmpty
        self.markSize = markSize
    }

    public var body: some View {
        HStack(spacing: 12) {
            AbloxMark()
                .foregroundStyle(.white)
                .frame(width: markSize * 0.62, height: markSize * 0.62)
                .frame(width: markSize, height: markSize)
                .background(
                    RoundedRectangle(cornerRadius: markSize * 0.27, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: markSize * 0.27, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                )

            VStack(alignment: .leading, spacing: 1) {
                // Tracking matches the wordmark on the brand sheet, which is
                // set wide rather than tight.
                Text("ABLOX")
                    .font(.system(size: markSize * 0.52, weight: .black, design: .rounded))
                    .kerning(markSize * 0.055)
                    .foregroundStyle(.white)

                if showsSubtitle {
                    Text(subtitle)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Ablox.Palette.inkFaint)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsSubtitle ? "Ablox, \(subtitle)" : "Ablox")
    }
}

#Preview("Mark") {
    VStack(spacing: 30) {
        AbloxMark().foregroundStyle(.white).frame(width: 120, height: 120)
        AbloxMark(style: .flat).foregroundStyle(Ablox.Palette.accent).frame(width: 60, height: 60)
        AbloxLockup(subtitle: "iPad Edition")
    }
    .padding(40)
    .background(Color.black)
}
