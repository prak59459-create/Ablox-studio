import SwiftUI
import UIKit

// Helpers for editing code in `AbloxTextEditor`: colours for the words of
// `.absc`, a red underline under lines with a problem, and a handle to the
// cursor — for suggestions, snippets and jumping to a line.

/// The colours of the code.
public enum CodeTheme: String, CaseIterable, Identifiable, Sendable {
    case night, ocean, candy, plain, highContrast

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .night: return L("Night")
        case .ocean: return L("Ocean")
        case .candy: return L("Candy")
        case .plain: return L("Plain")
        case .highContrast: return L("High contrast")
        }
    }

    /// What the code sits on.
    public var background: UIColor {
        switch self {
        case .night: return Self.rgb(0x0B0F1A)
        case .ocean: return Self.rgb(0x07263B)
        case .candy: return Self.rgb(0x241026)
        case .plain: return Self.rgb(0x151515)
        case .highContrast: return .black
        }
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    func color(_ kind: ScriptHighlighter.Kind?) -> UIColor {
        func rgb(_ hex: UInt32) -> UIColor { Self.rgb(hex) }
        switch self {
        case .night:
            switch kind {
            case .keyword: return rgb(0xC084FC)
            case .string: return rgb(0xFDE68A)
            case .number: return rgb(0x67E8F9)
            case .comment: return rgb(0x6B7280)
            case .event: return rgb(0x4ADE80)
            case .builtin: return rgb(0x60A5FA)
            case nil: return .white
            }
        case .ocean:
            switch kind {
            case .keyword: return rgb(0x38BDF8)
            case .string: return rgb(0xA7F3D0)
            case .number: return rgb(0xFCA5A5)
            case .comment: return rgb(0x64748B)
            case .event: return rgb(0xFDE047)
            case .builtin: return rgb(0x93C5FD)
            case nil: return rgb(0xE0F2FE)
            }
        case .candy:
            switch kind {
            case .keyword: return rgb(0xF472B6)
            case .string: return rgb(0xFBBF24)
            case .number: return rgb(0xA78BFA)
            case .comment: return rgb(0x9CA3AF)
            case .event: return rgb(0x34D399)
            case .builtin: return rgb(0x22D3EE)
            case nil: return rgb(0xFDF2F8)
            }
        case .plain:
            return kind == .comment ? rgb(0x9CA3AF) : .white
        case .highContrast:
            switch kind {
            case .keyword: return rgb(0xFFFF00)
            case .string: return rgb(0x00FF7F)
            case .number: return rgb(0x00FFFF)
            case .comment: return rgb(0xBBBBBB)
            case .event: return rgb(0xFF9F1A)
            case .builtin: return rgb(0x7FDBFF)
            case nil: return .white
            }
        }
    }
}

/// How code is coloured, and which lines are underlined as problems.
public struct CodeStyling: Equatable {
    public var theme: CodeTheme
    public var builtins: Set<String>
    /// Lines (from 1) with a problem.
    public var problemLines: Set<Int>

    public init(theme: CodeTheme, builtins: Set<String> = [], problemLines: Set<Int> = []) {
        self.theme = theme
        self.builtins = builtins
        self.problemLines = problemLines
    }

    /// Colours the text in place; what is typed and where the cursor is
    /// stay as they are.
    func apply(to view: UITextView, fontSize: CGFloat) {
        let storage = view.textStorage
        let text = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: theme.color(nil)], range: whole)
        for span in ScriptHighlighter.spans(in: text, builtins: builtins) {
            storage.addAttribute(.foregroundColor, value: theme.color(span.kind), range: span.range)
        }
        for line in problemLines {
            guard let range = ScriptHighlighter.range(ofLine: line, in: text), range.length > 0 else { continue }
            storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                   .underlineColor: UIColor.systemRed], range: range)
        }
        storage.endEditing()
        view.typingAttributes = [.font: font, .foregroundColor: theme.color(nil)]
    }
}

/// Reaches the editor's cursor from the view around it.
@MainActor
public final class CodeEditorHandle: ObservableObject {
    weak var textView: UITextView?
    var onChange: (() -> Void)?
    /// Bumped when the cursor moves or the text changes, so suggestions
    /// follow.
    @Published public private(set) var cursorRevision = 0

    nonisolated public init() {}

    func cursorMoved() {
        cursorRevision &+= 1
    }

    /// Where the cursor is, as a UTF-16 offset.
    public var cursor: Int {
        textView?.selectedRange.location ?? 0
    }

    public var text: String {
        textView?.text ?? ""
    }

    /// The selected text's range, or the cursor as an empty one (UTF-16).
    public var selection: NSRange {
        textView?.selectedRange ?? NSRange(location: 0, length: 0)
    }

    /// Selects `range`, kept inside the text.
    public func select(_ range: NSRange) {
        guard let view = textView else { return }
        let length = (view.text as NSString).length
        let location = min(max(0, range.location), length)
        view.selectedRange = NSRange(location: location, length: min(max(0, range.length), length - location))
        view.scrollRangeToVisible(view.selectedRange)
        cursorMoved()
    }

    /// Puts `text` in place of `range` (or at the cursor), cursor after it.
    public func replace(_ range: NSRange? = nil, with text: String) {
        guard let view = textView else { return }
        let target = range ?? view.selectedRange
        let length = (view.text as NSString).length
        guard target.location <= length, target.location + target.length <= length,
              let start = view.position(from: view.beginningOfDocument, offset: target.location),
              let end = view.position(from: start, offset: target.length),
              let textRange = view.textRange(from: start, to: end) else { return }
        view.replace(textRange, withText: text)
        onChange?()
    }

    /// Moves to line `line` (from 1) and shows it.
    public func jump(toLine line: Int) {
        guard let view = textView, let range = ScriptHighlighter.range(ofLine: line, in: view.text) else { return }
        view.becomeFirstResponder()
        view.selectedRange = range
        view.scrollRangeToVisible(range)
        cursorMoved()
    }
}
