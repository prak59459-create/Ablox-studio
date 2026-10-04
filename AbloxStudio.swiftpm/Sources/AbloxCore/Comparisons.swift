import Foundation

// Every `==`, `<` and `hash(into:)` the app writes by hand, as protocols.
//
// Why here, and why protocols: to check any `a == b`, even of two numbers,
// the compiler looks at every `==` written in the module, so each file that
// compares anything depends on every type that declares its own `==` — and
// on the file that type is in. An update that touched such a file, even to
// add a private function, rebuilt almost the whole app. Written once here,
// in protocol extensions, the comparisons depend on this file alone, which
// should hardly ever change. A type takes one by naming the protocol among
// its conformances; scripts/check-playgrounds-project.sh refuses an operator
// written anywhere else (docs/ipad-build.md, "One module again").

// MARK: - Enums compared by their case

/// An enum without payloads compared and hashed by its case, not its text.
///
/// An enum with a `String` raw value otherwise gets its `==` and
/// `hash(into:)` from `RawRepresentable`, which builds the text of both
/// sides to compare them. A block has several such fields, so comparing two
/// blocks spent most of its time making strings — and the renderer compares
/// every block on every change to the world, as do the world index and the
/// editor. An enum without payloads is stored as its case number alone, so
/// comparing those bytes gives exactly the same answer, and hashing them
/// keeps equal values hashing alike.
///
/// Refining `RawRepresentable` is what makes these win over its own `==`
/// and `hash(into:)`: the more specific protocol's are chosen.
public protocol ComparedByCase: RawRepresentable, Hashable where RawValue: Hashable {}

public extension ComparedByCase {
    @inline(__always)
    static func == (lhs: Self, rhs: Self) -> Bool {
        withUnsafeBytes(of: lhs) { x in withUnsafeBytes(of: rhs) { y in x.elementsEqual(y) } }
    }

    @inline(__always)
    func hash(into hasher: inout Hasher) {
        withUnsafeBytes(of: self) { hasher.combine(bytes: $0) }
    }
}

// MARK: - Ordered by raw value

/// Ordered by its raw value: for levels written lowest first, as
/// `case low = 0, medium, high`.
public protocol RankedByRawValue: RawRepresentable, Comparable where RawValue: Comparable {}

public extension RankedByRawValue {
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Equal by something else

/// Always equal to another of its kind, and hashed as nothing: for a cache
/// or a log kept inside a value, which must not make two otherwise equal
/// values differ.
public protocol AlwaysEqual: Hashable {}

public extension AlwaysEqual {
    static func == (lhs: Self, rhs: Self) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// Equal when the ids are: the same session, the same peer, whatever else
/// it carries.
public protocol EqualByID: Identifiable, Equatable {}

public extension EqualByID {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Equal when `equalityKey` is: for a value holding something that is not
/// `Equatable` itself (an array of tuples), compared through what it holds.
public protocol EqualByKey: Equatable {
    associatedtype EqualityKey: Equatable
    var equalityKey: EqualityKey { get }
}

public extension EqualByKey {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.equalityKey == rhs.equalityKey }
}
