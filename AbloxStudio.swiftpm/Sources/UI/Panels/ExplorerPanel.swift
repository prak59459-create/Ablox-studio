import SwiftUI
// `UTType.text`, used by the drag-to-reparent drop target. SwiftUI does not
// re-export it.
import UniformTypeIdentifiers

/// The scene tree. Tap to select, drag onto another row to reparent.
struct ExplorerPanel: View {
    @ObservedObject var session: StudioSession

    @State private var expanded: Set<UUID> = []
    @State private var dropTarget: UUID?
    @State private var searchText = ""

    private var world: WorldDocument { session.document.world }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if world.blocks.isEmpty {
                EmptyStateView(
                    title: "Nothing here yet",
                    message: "Tap a shape in the palette below to add your first part.",
                    systemImage: "square.dashed"
                )
                .padding(.horizontal, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleRows, id: \.block.id) { row in
                            rowView(row)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }

            Divider().background(Color.white.opacity(0.07))
            issuesFooter
        }
        .background(.ultraThinMaterial)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 9) {
            HStack {
                Label(L("Explorer"), systemImage: "list.bullet.indent")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Ablox.Palette.ink)
                Spacer()
                Text("\(world.blocks.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Ablox.Palette.inkFaint)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.inkFaint)
                TextField(L("Find a part"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.inkFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: Rows

    private struct Row {
        let block: BlockData
        let depth: Int
        let hasChildren: Bool
    }

    /// Flattens the tree into the rows currently on screen, respecting
    /// collapsed branches. A filter shows matches flat, since hiding a match
    /// inside a collapsed parent would defeat the search.
    private var visibleRows: [Row] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.isEmpty else {
            return world.blocks
                .filter { $0.name.localizedCaseInsensitiveContains(query) || $0.hasTag(query) }
                .map { Row(block: $0, depth: 0, hasChildren: false) }
        }

        var rows: [Row] = []
        func walk(_ parent: UUID?, depth: Int) {
            for block in world.children(of: parent) {
                let children = world.children(of: block.id)
                rows.append(Row(block: block, depth: depth, hasChildren: !children.isEmpty))
                if expanded.contains(block.id) {
                    walk(block.id, depth: depth + 1)
                }
            }
        }
        walk(nil, depth: 0)
        return rows
    }

    private func rowView(_ row: Row) -> some View {
        let isSelected = session.document.selection.contains(row.block.id)
        let isDropTarget = dropTarget == row.block.id

        return HStack(spacing: 5) {
            // Disclosure triangle, or an equivalent gap so names line up.
            Group {
                if row.hasChildren {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if expanded.contains(row.block.id) {
                                expanded.remove(row.block.id)
                            } else {
                                expanded.insert(row.block.id)
                            }
                        }
                    } label: {
                        Image(systemName: expanded.contains(row.block.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 16, height: 22)
                }
            }

            Image(systemName: row.block.behavior == .none ? row.block.shape.symbolName : row.block.behavior.symbolName)
                .font(.caption)
                .frame(width: 16)
                .foregroundStyle(row.block.behavior == .none ? Color(row.block.color) : Ablox.Palette.warning)

            Text(row.block.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(row.block.isVisible ? Ablox.Palette.ink : Ablox.Palette.inkFaint)

            Spacer(minLength: 4)

            if !row.block.isVisible {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(Ablox.Palette.inkFaint)
            }
            if !row.block.isAnchored {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(Ablox.Palette.warning)
                    .help(L("Falls under gravity in Play mode"))
            }
        }
        .padding(.leading, CGFloat(row.depth) * 13)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowBackground(isSelected: isSelected, isDropTarget: isDropTarget))
        )
        .contentShape(Rectangle())
        .onTapGesture { session.select(row.block.id) }
        .onDrag {
            // The id travels as plain text; the drop side looks it up.
            NSItemProvider(object: row.block.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: ReparentDropDelegate(
            targetID: row.block.id,
            session: session,
            dropTarget: $dropTarget,
            onDropAccepted: { expanded.insert(row.block.id) }
        ))
        .contextMenu {
            Button { session.select(row.block.id); session.duplicateSelection() } label: {
                Label(L("Duplicate"), systemImage: "doc.on.doc")
            }
            Button {
                session.edit { $0.mutateSelection(label: "Toggle visibility") { $0.isVisible.toggle() } }
            } label: {
                Label(row.block.isVisible ? L("Hide") : L("Show"), systemImage: row.block.isVisible ? "eye.slash" : "eye")
            }
            if row.block.parentID != nil {
                Button {
                    session.edit { $0.reparent(row.block.id, to: nil) }
                } label: {
                    Label(L("Move to top level"), systemImage: "arrow.up.to.line")
                }
            }
            Divider()
            Button(role: .destructive) {
                session.select(row.block.id)
                session.deleteSelection()
            } label: {
                Label(L("Delete"), systemImage: "trash")
            }
        }
    }

    private func rowBackground(isSelected: Bool, isDropTarget: Bool) -> Color {
        if isDropTarget { return Ablox.Palette.success.opacity(0.28) }
        if isSelected { return Ablox.Palette.accent.opacity(0.26) }
        return .clear
    }

    // MARK: Issues

    @ViewBuilder private var issuesFooter: some View {
        let issues = session.issues
        if issues.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Ablox.Palette.success)
                Text(L("No problems"))
                    .foregroundStyle(Ablox.Palette.inkMuted)
            }
            .font(.caption2)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(issues.prefix(3).enumerated()), id: \.offset) { _, issue in
                    Button {
                        if let blockID = issue.blockID { session.select(blockID) }
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Ablox.Palette.warning)
                            Text(issue.message)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(Ablox.Palette.inkMuted)
                            Spacer(minLength: 0)
                        }
                        .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                if issues.count > 3 {
                    Text(L("+{} more", issues.count - 3))
                        .font(.system(size: 9))
                        .foregroundStyle(Ablox.Palette.inkFaint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Drop delegate

/// Handles dragging one row onto another to reparent it.
private struct ReparentDropDelegate: DropDelegate {
    let targetID: UUID
    let session: StudioSession
    @Binding var dropTarget: UUID?
    let onDropAccepted: () -> Void

    func dropEntered(info: DropInfo) {
        dropTarget = targetID
    }

    func dropExited(info: DropInfo) {
        if dropTarget == targetID { dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }

        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let string = value as? String, let draggedID = UUID(uuidString: string) else { return }
            Task { @MainActor in
                // `reparent` refuses cycles and no-ops, so an invalid drop
                // simply does nothing rather than corrupting the tree.
                var accepted = false
                session.edit { accepted = $0.reparent(draggedID, to: targetID) }
                if accepted { onDropAccepted() }
            }
        }
        return true
    }
}
