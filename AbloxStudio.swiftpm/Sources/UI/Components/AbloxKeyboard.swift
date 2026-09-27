import SwiftUI
import UIKit

// Ablox's own on-screen keyboard, for iPads where the system one never
// appears inside the app.
//
// It is drawn in a window of its own above everything else — sheets, the
// full-screen game, alerts — so it shows wherever a text field is, and it
// needs nothing from the system keyboard at all. Text fields are
// `AbloxTextField` (one line, or a few) and `AbloxTextEditor` (code, with a
// real cursor); with the setting off they are the ordinary iPad fields.
//
// The keys and the kana rules are in `AbloxCore/KeyboardLayout.swift`.

// MARK: - The setting

public enum KeyboardPreference {
    /// On: every text field types with Ablox's keyboard.
    public static let key = "ablox.useAbloxKeyboard"

    public static var usesAbloxKeyboard: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - What is being typed into

/// A field the keyboard is typing into: plain text through a binding, or a
/// text view with its own cursor.
@MainActor
public final class KeyboardTarget {
    let id: UUID
    let title: String
    let multiline: Bool
    let read: () -> String
    let insert: (String) -> Void
    let deleteBackward: () -> Void
    /// Changes the character before the cursor (゛゜ and 小), if it can.
    let changeLast: ((Character) -> Character?) -> Void
    let submit: (() -> Void)?

    init(id: UUID, title: String, multiline: Bool, read: @escaping () -> String, insert: @escaping (String) -> Void,
         deleteBackward: @escaping () -> Void, changeLast: @escaping ((Character) -> Character?) -> Void, submit: (() -> Void)?) {
        self.id = id
        self.title = title
        self.multiline = multiline
        self.read = read
        self.insert = insert
        self.deleteBackward = deleteBackward
        self.changeLast = changeLast
        self.submit = submit
    }

    /// Typing at the end of a string.
    static func binding(id: UUID, title: String, text: Binding<String>, multiline: Bool, limit: Int?,
                        submit: (() -> Void)?) -> KeyboardTarget {
        KeyboardTarget(
            id: id, title: title, multiline: multiline,
            read: { text.wrappedValue },
            insert: { typed in
                var value = text.wrappedValue + typed
                if let limit, value.count > limit { value = String(value.prefix(limit)) }
                text.wrappedValue = value
            },
            deleteBackward: {
                guard !text.wrappedValue.isEmpty else { return }
                text.wrappedValue.removeLast()
            },
            changeLast: { change in
                guard let last = text.wrappedValue.last, let changed = change(last) else { return }
                text.wrappedValue.removeLast()
                text.wrappedValue.append(changed)
            },
            submit: submit
        )
    }
}

// MARK: - The keyboard's state

@MainActor
public final class KeyboardController: ObservableObject {
    public static let shared = KeyboardController()

    public enum Shift { case off, once, locked }

    @Published public private(set) var targetID: UUID?
    /// The field's text, for the strip above the keys.
    @Published private(set) var preview = ""
    @Published private(set) var title = ""
    @Published var page: KeyboardPage = .letters
    @Published var shift: Shift = .off
    @Published var katakana = false
    /// The system keyboard did not come up: offer this one.
    @Published var offersAbloxKeyboard = false
    @Published var tip: String?

    private var target: KeyboardTarget?

    private init() {}

    public func begin(_ target: KeyboardTarget) {
        if targetID == nil {
            // A fresh start: the page for the language the app is in.
            page = Localization.language == .japanese ? .kana : .letters
            shift = .off
        }
        self.target = target
        targetID = target.id
        title = target.title
        offersAbloxKeyboard = false
        refresh()
        KeyboardWindow.shared.update()
    }

    /// Stops typing — into `id` only, when given, so a field closing does
    /// not take the keyboard away from another one.
    public func end(_ id: UUID? = nil) {
        guard id == nil || id == targetID else { return }
        target = nil
        targetID = nil
        KeyboardWindow.shared.update()
    }

    func type(_ key: String) {
        var text = key
        if page == .letters, shift != .off {
            text = text.uppercased()
            if shift == .once { shift = .off }
        }
        if page == .kana, katakana { text = KanaInput.katakana(text) }
        target?.insert(text)
        refresh()
    }

    func space() {
        target?.insert(page == .kana ? "\u{3000}" : " ")
        refresh()
    }

    func backspace() {
        target?.deleteBackward()
        refresh()
    }

    func voiced() {
        target?.changeLast { KanaInput.voiced($0) }
        refresh()
    }

    func small() {
        target?.changeLast { KanaInput.small($0) }
        refresh()
    }

    /// A new line in a multi-line field; otherwise "done".
    func returnKey() {
        guard let target else { return }
        if target.multiline {
            target.insert("\n")
            refresh()
        } else {
            let submit = target.submit
            end()
            submit?()
        }
    }

    func tapShift() {
        switch shift {
        case .off: shift = .once
        case .once: shift = .locked
        case .locked: shift = .off
        }
    }

    /// Back to the iPad's own keyboard.
    func useSystemKeyboard() {
        KeyboardPreference.usesAbloxKeyboard = false
        end()
    }

    private func refresh() {
        preview = target?.read() ?? ""
    }

    // MARK: Noticing a missing keyboard

    private var observers: [NSObjectProtocol] = []
    private var editingStarted: Date?
    private var keyboardShown: Date?

    /// Watches for a text field that started editing with no keyboard coming
    /// up, and offers this one. Called once when the app starts.
    public func startWatching() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.editingBegan() }
        })
        observers.append(center.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.editingBegan() }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.keyboardShown = Date() }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.keyboardShown = Date() }
        })
    }

    private func editingBegan() {
        guard !KeyboardPreference.usesAbloxKeyboard else { return }
        let started = Date()
        editingStarted = started
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard let self, self.editingStarted == started, !KeyboardPreference.usesAbloxKeyboard else { return }
            // Nothing came up — no keyboard, not even the bar a keyboard case
            // shows.
            if (self.keyboardShown ?? .distantPast) < started {
                self.offersAbloxKeyboard = true
                KeyboardWindow.shared.update()
            }
        }
    }

    func acceptOffer() {
        KeyboardPreference.usesAbloxKeyboard = true
        offersAbloxKeyboard = false
        // Out of the system field, so the next tap opens this keyboard.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        tip = L("Tap the text box again to type.")
        KeyboardWindow.shared.update()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            self?.tip = nil
            KeyboardWindow.shared.update()
        }
    }

    func declineOffer() {
        offersAbloxKeyboard = false
        KeyboardWindow.shared.update()
    }

    var needsWindow: Bool { targetID != nil || offersAbloxKeyboard || tip != nil }
}

// MARK: - The window it lives in

/// A window above the app's own, covering the screen but letting every touch
/// through except those on the keyboard itself.
@MainActor
final class KeyboardWindow {
    static let shared = KeyboardWindow()
    private var window: PassthroughWindow?

    func update() {
        if KeyboardController.shared.needsWindow {
            show()
        } else {
            window?.isHidden = true
        }
    }

    private func show() {
        if window == nil {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
            let window = PassthroughWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            let host = UIHostingController(rootView: KeyboardOverlay())
            host.view.backgroundColor = .clear
            window.rootViewController = host
            window.backgroundColor = .clear
            self.window = window
        }
        window?.isHidden = false
    }
}

final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // The empty, see-through part: not ours.
        return hit === rootViewController?.view ? nil : hit
    }
}

// MARK: - Drawing it

struct KeyboardOverlay: View {
    @ObservedObject private var keyboard = KeyboardController.shared

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if let tip = keyboard.tip {
                Text(tip)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if keyboard.offersAbloxKeyboard {
                offer
            }
            if keyboard.targetID != nil {
                KeyboardPanel()
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: keyboard.targetID)
        .ignoresSafeArea(.keyboard)
        .preferredColorScheme(.dark)
    }

    private var offer: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.title3)
            Text(L("No keyboard? Use the Ablox keyboard instead."))
                .font(.subheadline.weight(.semibold))
            Button(L("Use it")) { keyboard.acceptOffer() }
                .buttonStyle(.borderedProminent)
            Button {
                keyboard.declineOffer()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(L("Close"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 20)
    }
}

struct KeyboardPanel: View {
    @ObservedObject private var keyboard = KeyboardController.shared

    var body: some View {
        VStack(spacing: 7) {
            previewStrip
            switch keyboard.page {
            case .letters: letters
            case .kana: kana
            case .symbols: symbols
            }
            bottomRow
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: 1000)
        .background(
            Color(red: 0.09, green: 0.10, blue: 0.15).opacity(0.97)
                .shadow(color: .black.opacity(0.4), radius: 12, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// What is being typed, so it can be read even when the field itself is
    /// under the keys.
    private var previewStrip: some View {
        HStack(spacing: 10) {
            Text(keyboard.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            HStack(spacing: 1) {
                Text(verbatim: String(keyboard.preview.suffix(80)))
                    .lineLimit(1)
                    .truncationMode(.head)
                BlinkingCaret()
            }
            .font(.body)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                keyboard.useSystemKeyboard()
            } label: {
                Label(L("iPad keyboard"), systemImage: "keyboard")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.7))
            Button {
                keyboard.end()
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.title3)
                    .frame(width: 44, height: 36)
            }
            .foregroundStyle(.white)
            .accessibilityLabel(L("Hide the keyboard"))
        }
        .padding(.horizontal, 6)
    }

    private var letters: some View {
        VStack(spacing: 7) {
            keyRow(KeyboardKeys.letters[0])
            keyRow(KeyboardKeys.letters[1])
                .padding(.horizontal, 24)
            HStack(spacing: 6) {
                special(keyboard.shift == .locked ? "capslock.fill" : (keyboard.shift == .once ? "shift.fill" : "shift"),
                        label: L("Shift"), width: 70) { keyboard.tapShift() }
                ForEach(KeyboardKeys.letters[2], id: \.self) { key in
                    character(key)
                }
                special("delete.left", label: L("Delete"), width: 70, repeats: true) { keyboard.backspace() }
            }
        }
    }

    private var kana: some View {
        VStack(spacing: 6) {
            ForEach(KeyboardKeys.kana.indices, id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(KeyboardKeys.kana[row], id: \.self) { key in
                        character(key)
                    }
                    kanaSideKey(row)
                }
            }
        }
    }

    /// The column beside the chart: ゛゜, 小, カナ and marks.
    @ViewBuilder
    private func kanaSideKey(_ row: Int) -> some View {
        switch row {
        case 0: textKey("゛゜", width: 64) { keyboard.voiced() }
        case 1: textKey(L("small"), width: 64) { keyboard.small() }
        case 2: textKey(keyboard.katakana ? "かな" : "カナ", width: 64) { keyboard.katakana.toggle() }
        case 3: character(KeyboardKeys.kanaMarks[0], width: 64)
        default: character(KeyboardKeys.kanaMarks[1], width: 64)
        }
    }

    private var symbols: some View {
        VStack(spacing: 7) {
            ForEach(KeyboardKeys.symbols.indices, id: \.self) { row in
                keyRow(KeyboardKeys.symbols[row])
            }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            ForEach(KeyboardPage.allCases.filter { $0 != keyboard.page }, id: \.self) { page in
                textKey(pageName(page), width: 74) { keyboard.page = page }
            }
            if keyboard.page == .kana {
                ForEach(KeyboardKeys.kanaMarks.dropFirst(2), id: \.self) { mark in
                    character(mark, width: 48)
                }
            }
            Button { keyboard.space() } label: {
                Text(L("space"))
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(KeyPressStyle())
            if keyboard.page == .kana {
                special("delete.left", label: L("Delete"), width: 70, repeats: true) { keyboard.backspace() }
            }
            textKey(L("return"), width: 96, prominent: true) { keyboard.returnKey() }
        }
    }

    private func pageName(_ page: KeyboardPage) -> String {
        switch page {
        case .letters: return "ABC"
        case .kana: return "かな"
        case .symbols: return "123"
        }
    }

    // MARK: Keys

    private func keyRow(_ keys: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in character(key) }
        }
    }

    private func character(_ key: String, width: CGFloat? = nil) -> some View {
        let shown = displayed(key)
        return Button {
            keyboard.type(key)
        } label: {
            Text(verbatim: shown)
                .font(.title3)
                .frame(maxWidth: width ?? .infinity, minHeight: 46)
                .frame(width: width)
                .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityLabel(shown)
    }

    private func displayed(_ key: String) -> String {
        switch keyboard.page {
        case .letters: return keyboard.shift == .off ? key : key.uppercased()
        case .kana: return keyboard.katakana ? KanaInput.katakana(key) : key
        case .symbols: return key
        }
    }

    private func textKey(_ title: String, width: CGFloat, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: width, height: 46)
                .background(prominent ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(KeyPressStyle())
    }

    private func special(_ symbol: String, label: String, width: CGFloat, repeats: Bool = false,
                         action: @escaping () -> Void) -> some View {
        RepeatingKey(repeats: repeats, action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: width, height: 46)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel(label)
    }
}

/// Keys dim while pressed, like the real thing.
private struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// A key that repeats while held (delete), or acts once.
private struct RepeatingKey<Label: View>: View {
    let repeats: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var timer: Timer?
    @State private var pressed = false

    var body: some View {
        label()
            .foregroundStyle(.white)
            .opacity(pressed ? 0.55 : 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        guard repeats else { return }
                        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                            Task { @MainActor in
                                timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                                    Task { @MainActor in action() }
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        timer?.invalidate()
                        timer = nil
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

private struct BlinkingCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2, height: 20)
                .opacity(on ? 1 : 0)
        }
    }
}

// MARK: - Fields

/// A text field that types with Ablox's keyboard when the setting is on, and
/// is the iPad's own `TextField` when it is off.
public struct AbloxTextField: View {
    private let placeholder: String
    @Binding private var text: String
    private let axis: Axis
    private let limit: Int?
    private let onSubmit: (() -> Void)?

    @AppStorage(KeyboardPreference.key) private var usesAbloxKeyboard = false
    @ObservedObject private var keyboard = KeyboardController.shared
    @State private var id = UUID()

    public init(_ placeholder: String, text: Binding<String>, axis: Axis = .horizontal, limit: Int? = nil,
                onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.axis = axis
        self.limit = limit
        self.onSubmit = onSubmit
    }

    public var body: some View {
        if usesAbloxKeyboard {
            let active = keyboard.targetID == id
            Button {
                keyboard.begin(.binding(id: id, title: placeholder, text: $text, multiline: axis == .vertical,
                                        limit: limit, submit: onSubmit))
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    if text.isEmpty && !active {
                        Text(placeholder)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: text)
                    }
                    if active { BlinkingCaret() }
                    Spacer(minLength: 0)
                }
                .lineLimit(axis == .vertical ? 6 : 1)
                .multilineTextAlignment(.leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDisappear { keyboard.end(id) }
            .accessibilityLabel(placeholder)
            .accessibilityValue(text)
        } else {
            TextField(placeholder, text: $text, axis: axis)
                .onSubmit { onSubmit?() }
        }
    }
}

/// A multi-line editor with a real cursor (scripts, long notes). With the
/// setting on, the iPad keyboard is kept away and Ablox's types at the cursor.
public struct AbloxTextEditor: UIViewRepresentable {
    @Binding var text: String
    let title: String
    var monospaced = true
    var fontSize: CGFloat = 15
    /// Starts typing once it is on screen (a script opened to be edited).
    var autoFocus = false

    @AppStorage(KeyboardPreference.key) private var usesAbloxKeyboard = false

    public init(_ title: String, text: Binding<String>, monospaced: Bool = true, fontSize: CGFloat = 15, autoFocus: Bool = false) {
        self.title = title
        self._text = text
        self.monospaced = monospaced
        self.fontSize = fontSize
        self.autoFocus = autoFocus
    }

    public func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .white
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.spellCheckingType = .no
        view.keyboardDismissMode = .interactive
        view.text = text
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        if autoFocus {
            // Once a sheet has finished presenting: asked any earlier, some
            // iPads drop the request.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak view] in
                view?.becomeFirstResponder()
            }
        }
        return view
    }

    public func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.font = monospaced
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
        let wantsCustom = usesAbloxKeyboard
        if wantsCustom != context.coordinator.usingCustom {
            context.coordinator.usingCustom = wantsCustom
            // An empty input view keeps the system keyboard away.
            view.inputView = wantsCustom ? UIView(frame: .zero) : nil
            view.inputAssistantItem.leadingBarButtonGroups = []
            view.inputAssistantItem.trailingBarButtonGroups = []
            if view.isFirstResponder { view.reloadInputViews() }
        }
    }

    public static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        KeyboardController.shared.end(coordinator.id)
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: AbloxTextEditor
        var usingCustom = false
        let id = UUID()

        init(_ parent: AbloxTextEditor) {
            self.parent = parent
        }

        public func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        public func textViewDidBeginEditing(_ textView: UITextView) {
            if usingCustom { attach(textView) }
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard usingCustom, let view = recognizer.view as? UITextView else { return }
            attach(view)
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// Types at the text view's own cursor.
        @MainActor private func attach(_ view: UITextView) {
            let target = KeyboardTarget(
                id: id, title: parent.title, multiline: true,
                read: { [weak view] in
                    // The line being typed on.
                    guard let view, let text = view.text else { return "" }
                    let cursor = min(view.selectedRange.location, (text as NSString).length)
                    let before = (text as NSString).substring(to: cursor)
                    return String(before.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
                },
                insert: { [weak self, weak view] typed in
                    guard let view else { return }
                    view.insertText(typed)
                    self?.parent.text = view.text
                },
                deleteBackward: { [weak self, weak view] in
                    guard let view else { return }
                    view.deleteBackward()
                    self?.parent.text = view.text
                },
                changeLast: { [weak self, weak view] change in
                    guard let view, let text = view.text else { return }
                    let location = view.selectedRange.location
                    guard location > 0, location <= (text as NSString).length else { return }
                    let range = (text as NSString).rangeOfComposedCharacterSequence(at: location - 1)
                    let last = (text as NSString).substring(with: range)
                    guard let character = last.first, last.count == 1, let changed = change(character) else { return }
                    view.textStorage.replaceCharacters(in: range, with: String(changed))
                    view.selectedRange = NSRange(location: range.location + (String(changed) as NSString).length, length: 0)
                    self?.parent.text = view.text
                },
                submit: nil
            )
            KeyboardController.shared.begin(target)
        }
    }
}

// MARK: - The switch in Settings

/// "Use the Ablox keyboard", with a line on why.
public struct KeyboardSettingToggle: View {
    @AppStorage(KeyboardPreference.key) private var usesAbloxKeyboard = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $usesAbloxKeyboard) {
                Label(L("Use the Ablox keyboard"), systemImage: "keyboard")
            }
            Text(L("For iPads where the keyboard doesn't come up. Types letters, kana, numbers and marks. Turn it off to use the iPad's own keyboard again."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: usesAbloxKeyboard) { _, on in
            if !on { KeyboardController.shared.end() }
        }
    }
}

// MARK: - Asking for a line of text

/// A small sheet with one text field, in place of an alert with a text
/// field — an alert's field only works with the iPad keyboard.
public struct TextPromptSheet: View {
    let title: String
    let message: String?
    let placeholder: String
    let confirm: String
    @Binding var text: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    public init(title: String, message: String? = nil, placeholder: String, confirm: String,
                text: Binding<String>, onConfirm: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.confirm = confirm
        self._text = text
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.bold))
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AbloxTextField(placeholder, text: $text, onSubmit: done)
                .textFieldStyle(.plain)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Button(L("Cancel")) { dismiss() }
                Spacer()
                Button(confirm, action: done)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .presentationDetents([.height(250)])
        .preferredColorScheme(.dark)
    }

    private func done() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onConfirm()
        dismiss()
    }
}
