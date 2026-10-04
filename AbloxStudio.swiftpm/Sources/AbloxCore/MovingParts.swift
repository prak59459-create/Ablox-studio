import Foundation

// Platforms that move by themselves, in a file of its own, split from
// WorldFeatures.swift: a change here rebuilds only the files that use what
// is here, not every file that uses anything that was declared beside it.

public enum MovingParts {

    /// Where a moving platform is, relative to where it was built, at `time`
    /// seconds: waits, goes to `offset`, waits, comes back — for ever. Every
    /// iPad works it out from its own clock, so nothing is sent while it runs.
    public static func offset(for gimmick: GimmickSettings, at time: Double) -> Vec3 {
        let travel = Swift.max(0.2, gimmick.moveSeconds)
        let pause = Swift.max(0, gimmick.movePause)
        let cycle = 2 * (travel + pause)
        guard time.isFinite, cycle > 0 else { return .zero }
        let t = time.truncatingRemainder(dividingBy: cycle)
        let local = t < 0 ? t + cycle : t
        let amount: Double
        switch local {
        case ..<pause: amount = 0
        case ..<(pause + travel): amount = ease((local - pause) / travel)
        case ..<(2 * pause + travel): amount = 1
        default: amount = 1 - ease((local - 2 * pause - travel) / travel)
        }
        return gimmick.moveOffset * Float(amount)
    }

    private static func ease(_ t: Double) -> Double {
        let x = Swift.max(0, Swift.min(1, t))
        return x * x * (3 - 2 * x)
    }

    /// The world with every moving platform where it is at `time`.
    public static func placed(_ world: WorldDocument, at time: Double) -> WorldDocument {
        var moved = world
        for index in moved.blocks.indices where moved.blocks[index].behavior == .elevator {
            moved.blocks[index].position += offset(for: moved.blocks[index].gimmick, at: time)
        }
        return moved
    }
}
