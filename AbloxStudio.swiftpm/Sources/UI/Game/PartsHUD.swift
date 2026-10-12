import SwiftUI
import AbloxCore

/// The runtime's own screens, which a script opens with one line: the
/// things a player carries, a character talking, a shop, a big timer, a
/// leaderboard and the "Get out" button of a vehicle. Taps go back to the
/// host as reserved buttons (`ReservedButton`), which the runtime handles
/// before the script's `on button` would see them.
struct PartsHUDLayer: View {
    @ObservedObject var session: SessionCoordinator
    /// Settings → Sound → Read lines aloud.
    var readAloud: Bool

    @State private var countdownStarted = Date()

    var body: some View {
        let state = session.scripted
        ZStack {
            if let countdown = state.countdown {
                CountdownBadge(countdown: countdown, started: countdownStarted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, state.showsDefaultUI ? 70 : 16)
                    .allowsHitTesting(false)
            }

            if let board = state.leaderboard {
                LeaderboardCard(board: board) { press(.closeLeaderboard) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 16)
            }

            VStack(spacing: 10) {
                Spacer()
                if state.inVehicle {
                    Button {
                        press(.exitVehicle)
                    } label: {
                        Label(L("Get out"), systemImage: "figure.walk")
                    }
                    .buttonStyle(NeonButtonStyle(.secondary))
                }
                if let dialog = state.dialog {
                    DialogCard(dialog: dialog,
                               onChoice: { index in press(.choose(dialog: dialog.id, index: index)) },
                               onClose: { press(.closeDialog) })
                }
                if !state.inventory.isEmpty {
                    InventoryBar(items: state.inventory) { item in press(.use(item: item.name)) }
                }
            }
            .padding(.bottom, 24)
            .frame(maxWidth: 640)

            if let shop = state.shop {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { press(.closeShop) }
                ShopCard(shop: shop,
                         onBuy: { offer in press(.buy(shop: shop.id, item: offer.name)) },
                         onClose: { press(.closeShop) })
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.dialog)
        .animation(.easeOut(duration: 0.2), value: state.shop)
        .onChange(of: state.countdownSerial) { _, _ in countdownStarted = Date() }
        .onChange(of: state.dialog) { _, dialog in
            guard readAloud, let dialog else { return }
            LineReader.shared.speak(dialog.text)
        }
    }

    private func press(_ button: ReservedButton) {
        session.send(input: .button(id: button.id))
    }
}

/// An emoji, or an SF Symbol when the name is one.
private struct PartIcon: View {
    let icon: String
    var size: CGFloat = 26

    var body: some View {
        if icon.isEmpty {
            Image(systemName: "shippingbox.fill").font(.system(size: size * 0.8))
        } else if UIImage(systemName: icon) != nil {
            Image(systemName: icon).font(.system(size: size * 0.8))
        } else {
            Text(verbatim: String(icon.prefix(2))).font(.system(size: size))
        }
    }
}

private struct InventoryBar: View {
    let items: [InventoryItem]
    var onUse: (InventoryItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Button {
                        onUse(item)
                    } label: {
                        VStack(spacing: 2) {
                            PartIcon(icon: item.icon)
                                .frame(width: 34, height: 34)
                            Text(item.name)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        .frame(width: 64, height: 60)
                        .overlay(alignment: .topTrailing) {
                            if item.count > 1 {
                                Text("\(item.count)")
                                    .font(.caption2.weight(.black))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Ablox.Palette.accent, in: Capsule())
                                    .offset(x: 4, y: -4)
                            }
                        }
                        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .accessibilityLabel(L("Use {}", item.name))
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 66)
    }
}

private struct DialogCard: View {
    let dialog: DialogBox
    var onChoice: (Int) -> Void
    var onClose: () -> Void

    // In small pieces with their types written out: as one body this took
    // the compiler most of a second.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            speaker
            Text(verbatim: dialog.text)
                .font(.body)
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
            choices
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.18)))
        .padding(.horizontal, 16)
        .transition(AnyTransition.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder private var speaker: some View {
        if !dialog.speaker.isEmpty {
            Text(verbatim: dialog.speaker)
                .font(.headline)
                .foregroundStyle(Ablox.Palette.accent)
        }
    }

    private var choices: some View {
        HStack(spacing: 8) {
            if dialog.choices.isEmpty {
                Spacer()
                Button(L("OK"), action: onClose)
                    .buttonStyle(NeonButtonStyle(.primary))
            } else {
                ForEach(dialog.choices.indices, id: \.self) { index in
                    choiceButton(index)
                }
            }
        }
    }

    private func choiceButton(_ index: Int) -> some View {
        let prominence: NeonButtonStyle.Prominence = index == 0 ? .primary : .secondary
        return Button {
            onChoice(index)
        } label: {
            Text(verbatim: dialog.choices[index])
        }
        .buttonStyle(NeonButtonStyle(prominence))
    }
}

private struct ShopCard: View {
    let shop: ShopPanel
    var onBuy: (ShopOffer) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            header
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                    ForEach(shop.offers) { offer in
                        offerButton(offer)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: 560)
        .background(Color(red: 0.07, green: 0.09, blue: 0.16).opacity(0.96), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(20)
        .transition(.scale(scale: 0.94).combined(with: .opacity))
    }

    private var header: some View {
        let title: String = shop.title.isEmpty ? L("Shop") : shop.title
        let balance: String = "\(shop.balance) \(L(shop.currency))"
        return HStack {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            Label(balance, systemImage: "dollarsign.circle.fill")
                .font(.headline)
                .foregroundStyle(Ablox.Palette.warning)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Close"))
        }
    }

    private func offerButton(_ offer: ShopOffer) -> some View {
        let affordable: Bool = shop.balance >= offer.price
        let price: String = offer.price == 0 ? L("Free") : "\(offer.price)"
        let priceColour: Color = affordable ? Ablox.Palette.warning : Ablox.Palette.inkFaint
        let tile: Color = Color.white.opacity(affordable ? 0.1 : 0.04)
        return Button {
            onBuy(offer)
        } label: {
            VStack(spacing: 6) {
                PartIcon(icon: offer.icon, size: 34)
                    .frame(height: 40)
                Text(offer.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(price)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(priceColour)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(affordable ? 1 : 0.6)
    }
}

private struct CountdownBadge: View {
    let countdown: CountdownDisplay
    let started: Date

    var body: some View {
        TimelineView(.periodic(from: started, by: 0.2)) { context in
            let left = max(0, countdown.seconds - context.date.timeIntervalSince(started))
            VStack(spacing: 0) {
                if !countdown.label.isEmpty {
                    Text(countdown.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Ablox.Palette.inkMuted)
                }
                Text(Self.format(left))
                    .font(.system(size: 34, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(left <= 10 ? Ablox.Palette.danger : .white)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5), in: Capsule())
        }
    }

    static func format(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.up))
        return whole >= 60 ? String(format: "%d:%02d", whole / 60, whole % 60) : "\(whole)"
    }
}

private struct LeaderboardCard: View {
    let board: LeaderboardPanel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(board.title, systemImage: "trophy.fill")
                    .font(.headline)
                    .foregroundStyle(Ablox.Palette.warning)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close"))
            }
            if board.rows.isEmpty {
                Text(L("No scores yet."))
                    .font(.subheadline)
                    .foregroundStyle(Ablox.Palette.inkMuted)
            }
            ForEach(Array(board.rows.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text("\(index + 1)")
                        .font(.subheadline.weight(.black))
                        .frame(width: 24, alignment: .leading)
                        .foregroundStyle(index == 0 ? Ablox.Palette.warning : Ablox.Palette.inkMuted)
                    Text(row.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Text(Self.format(row.value))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 260)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}
