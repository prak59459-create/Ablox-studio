import SwiftUI

/// The thirty characters a room code can contain, as buttons.
///
/// The system keyboard does not appear on an iPad with a keyboard case
/// attached, even with the case folded back out of reach — which on a
/// classroom iPad is most of the time. A code that can only be typed on a
/// keyboard is then a code that cannot be typed, and the player cannot join.
/// See `RoomCodeFormat`.
public struct CodePad: View {
    @Binding var code: String

    public init(code: Binding<String>) {
        self._code = code
    }

    public var body: some View {
        VStack(spacing: 7) {
            ForEach(Array(RoomCodeFormat.padRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            code = RoomCodeFormat.typing(key, into: code)
                        } label: {
                            Text(String(key))
                                .font(.system(size: 19, weight: .bold, design: .monospaced))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .foregroundStyle(Ablox.Palette.ink)
                        }
                        .buttonStyle(.plain)
                        .disabled(RoomCodeFormat.normalize(code).count >= RoomCodeFormat.length)
                    }
                }
            }

            Button {
                code = RoomCodeFormat.deleting(from: code)
            } label: {
                Label(L("Delete"), systemImage: "delete.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44 * 6 + 7 * 5, height: 40)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(Ablox.Palette.inkMuted)
            }
            .buttonStyle(.plain)
            .disabled(RoomCodeFormat.normalize(code).isEmpty)

            Text(L("Codes never contain O, 0, I, 1, L or U."))
                .font(.caption2)
                .foregroundStyle(Ablox.Palette.inkFaint)
        }
    }
}
