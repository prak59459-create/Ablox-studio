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

    private var isFull: Bool { RoomCodeFormat.normalize(code).count >= RoomCodeFormat.length }

    // In small typed pieces: nested inline this took the compiler over half
    // a second.
    public var body: some View {
        let rows: [[Character]] = RoomCodeFormat.padRows
        return VStack(spacing: 7) {
            ForEach(rows.indices, id: \.self) { index in
                row(rows[index])
            }
            deleteButton
            Text(verbatim: L("Codes never contain O, 0, I, 1, L or U."))
                .font(.caption2)
                .foregroundStyle(Ablox.Palette.inkFaint)
        }
    }

    private func row(_ keys: [Character]) -> some View {
        HStack(spacing: 7) {
            ForEach(keys, id: \.self) { key in
                keyButton(key)
            }
        }
    }

    private func keyButton(_ key: Character) -> some View {
        Button {
            code = RoomCodeFormat.typing(key, into: code)
        } label: {
            Text(verbatim: String(key))
                .font(.system(size: 19, weight: .bold, design: .monospaced))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(Ablox.Palette.ink)
        }
        .buttonStyle(.plain)
        .disabled(isFull)
    }

    /// As wide as a row of six keys.
    private static let rowWidth: CGFloat = 299

    private var deleteButton: some View {
        Button {
            code = RoomCodeFormat.deleting(from: code)
        } label: {
            Label(L("Delete"), systemImage: "delete.left")
                .font(.subheadline.weight(.semibold))
                .frame(width: Self.rowWidth, height: 40)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(Ablox.Palette.inkMuted)
        }
        .buttonStyle(.plain)
        .disabled(RoomCodeFormat.normalize(code).isEmpty)
    }
}
