import Foundation

// The enums a block is made of compared by their case, not through their
// text.
//
// An enum with a `String` raw value gets its `==` and `hash(into:)` from
// `RawRepresentable`, which builds the text of both sides to compare them.
// A block has several such fields, so comparing two blocks spent most of its
// time making strings — and the renderer compares every block on every change
// to the world, as do the world index and the editor. An enum without
// payloads is stored as its case number alone, so comparing those bytes gives
// exactly the same answer, and hashing them keeps equal values hashing alike.

@inline(__always)
func sameCase<T>(_ a: T, _ b: T) -> Bool {
    withUnsafeBytes(of: a) { x in withUnsafeBytes(of: b) { y in x.elementsEqual(y) } }
}

@inline(__always)
func hashCase<T>(_ value: T, into hasher: inout Hasher) {
    withUnsafeBytes(of: value) { hasher.combine(bytes: $0) }
}

extension BlockShape {
    public static func == (lhs: BlockShape, rhs: BlockShape) -> Bool { sameCase(lhs, rhs) }
    public func hash(into hasher: inout Hasher) { hashCase(self, into: &hasher) }
}

extension MaterialKind {
    public static func == (lhs: MaterialKind, rhs: MaterialKind) -> Bool { sameCase(lhs, rhs) }
    public func hash(into hasher: inout Hasher) { hashCase(self, into: &hasher) }
}

extension BlockBehavior {
    public static func == (lhs: BlockBehavior, rhs: BlockBehavior) -> Bool { sameCase(lhs, rhs) }
    public func hash(into hasher: inout Hasher) { hashCase(self, into: &hasher) }
}

extension ParticleKind {
    public static func == (lhs: ParticleKind, rhs: ParticleKind) -> Bool { sameCase(lhs, rhs) }
    public func hash(into hasher: inout Hasher) { hashCase(self, into: &hasher) }
}

extension BlockLight.Kind {
    public static func == (lhs: BlockLight.Kind, rhs: BlockLight.Kind) -> Bool { sameCase(lhs, rhs) }
    public func hash(into hasher: inout Hasher) { hashCase(self, into: &hasher) }
}

extension BlockAnimation.Kind {
    public static func == (lhs: BlockAnimation.Kind, rhs: BlockAnimation.Kind) -> Bool { sameCase(lhs, rhs) }
    public func hash(into hasher: inout Hasher) { hashCase(self, into: &hasher) }
}
