import SwiftUI

/// Studio's built-in "how to make a map" guide.
///
/// The words come from `MapGuide` in EditorCore, not from this file, so the
/// same text is what `docs/making-maps.md` contains — and `MapGuideTests`
/// fails if the two ever disagree. This view is only the presentation.
struct MapGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Which section is open. The first one starts open so the sheet does not
    /// present as a wall of closed rows with nothing to read.
    @State private var expanded: Set<String> = [MapGuide.sections.first?.title ?? ""]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    intro

                    ForEach(Array(MapGuide.sections.enumerated()), id: \.element.title) { index, section in
                        sectionCard(index: index, section: section)
                    }
                }
                .padding(18)
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.11))
            .navigationTitle("Making a map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Ablox.Palette.accent)
    }

    private var intro: some View {
        Text("Ten steps from an empty grid to something people can play. Tap a heading to open it.")
            .font(.callout)
            .foregroundStyle(Ablox.Palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
    }

    private func sectionCard(index: Int, section: MapGuide.Section) -> some View {
        let isOpen = expanded.contains(section.title)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isOpen {
                        expanded.remove(section.title)
                    } else {
                        expanded.insert(section.title)
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 11) {
                    Image(systemName: section.symbolName)
                        .font(.subheadline)
                        .foregroundStyle(Ablox.Palette.accent)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(index + 1). \(section.title)")
                            .font(.headline)
                            .foregroundStyle(Ablox.Palette.ink)
                        Text(section.summary)
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { _, step in
                        stepRow(step)
                    }
                }
                .padding(.top, 13)
            }
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Ablox.Metrics.cardRadius, style: .continuous))
    }

    private func stepRow(_ step: MapGuide.Step) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(Ablox.Palette.accent.opacity(0.7))
                .frame(width: 5, height: 5)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(step.text)
                    .font(.subheadline)
                    .foregroundStyle(Ablox.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let aside = step.aside {
                    // The part you would otherwise only learn by getting it
                    // wrong — set apart so it reads as a reason, not a step.
                    Text(aside)
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
