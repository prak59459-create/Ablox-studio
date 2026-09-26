import Foundation

// MARK: - Saved game data

/// `p.saved` and `p.save(key, value)`: progress that outlives the session.
///
/// The data lives on each player's own iPad. When they arrive it is sent to
/// the host (`PlayerInputPayload.Input.saved`), the script reads it as
/// `p.saved` — `on loaded(p)` says when — and `p.save` changes it. Changes
/// go back to that player's iPad at most once a second (`ScriptEffect.store`),
/// so a script can save on every coin without flooding the network.
extension GameRuntime {

    enum SaveTiming {
        /// Seconds between two copies sent to the same player. Leaving loses
        /// at most this much.
        static let flushInterval = 1.0
    }

    /// A player's saved data, read from their iPad.
    func receiveSave(_ data: SaveData, for state: PlayerState) {
        // Only the first copy counts. A second one — a reconnect, a replayed
        // packet — would put back what was saved before this session's
        // progress.
        guard state.saved == nil else { return }
        state.saved = SaveData(data.values)
        guard hasStarted, !isRoundOver else { return }
        run(.loaded, [object(for: state)])
    }

    /// `p.saved`: a copy, so changing it does not save anything by accident.
    func savedValue(of state: PlayerState) -> ScriptValue {
        guard let saved = state.saved else { return .null }
        return scriptValue(.map(saved.values))
    }

    /// `p.save("coins", 120)`, or `p.save("coins")` to forget it.
    ///
    /// True when it is saved. False, without an error, before the player's
    /// data has arrived (see `PlayerState.saved`) and for an NPC, which has
    /// no iPad to keep it on.
    func save(_ arguments: [ScriptValue], for state: PlayerState, line: Int) throws -> ScriptValue {
        guard case let .string(key) = arguments.first ?? .null, SaveData.isValidKey(key) else {
            throw ScriptError(line: line, kind: .runtime,
                              message: L("“save” needs a name first, like p.save(\"coins\", 10)."))
        }
        guard !state.isNPC, var saved = state.saved else { return .bool(false) }
        let value = arguments.count > 1 ? arguments[1] : .null
        let converted: SaveValue? = value.isNull ? nil : try saveValue(value, line: line)
        if saved[key] == converted { return .bool(true) }
        guard saved.set(key, converted) else {
            throw ScriptError(line: line, kind: .limit,
                              message: L("That is too much to save (the limit is {} KB).", SaveData.Limits.maximumEncodedBytes / 1024))
        }
        state.saved = saved
        state.saveChanged = true
        return .bool(true)
    }

    func saveValue(_ value: ScriptValue, line: Int, depth: Int = 1) throws -> SaveValue {
        guard depth <= SaveData.Limits.maximumDepth else {
            throw ScriptError(line: line, kind: .limit,
                              message: L("Saved lists and maps can only go {} deep.", SaveData.Limits.maximumDepth))
        }
        switch value {
        case let .bool(flag):
            return .bool(flag)
        case let .number(number):
            guard number.isFinite else {
                throw ScriptError(line: line, kind: .runtime, message: L("Only a real number can be saved."))
            }
            return .number(number)
        case let .string(text):
            return .string(text)
        case let .list(list):
            // nil keeps its place in a list — `[3, nil, 5]` comes back the same.
            return .list(try list.items.map { $0.isNull ? .null : try saveValue($0, line: line, depth: depth + 1) })
        case let .map(map):
            var entries: [String: SaveValue] = [:]
            for key in map.keys {
                // A key set to nil is a key that is not there.
                guard let item = map[key], !item.isNull else { continue }
                entries[key] = try saveValue(item, line: line, depth: depth + 1)
            }
            return .map(entries)
        case .null, .function, .native, .object:
            throw ScriptError(line: line, kind: .runtime,
                              message: L("Only numbers, text, true/false, lists and maps can be saved — not {}.", value.typeName))
        }
    }

    func scriptValue(_ value: SaveValue) -> ScriptValue {
        switch value {
        case .null: return .null
        case let .number(number): return .number(number)
        case let .string(text): return .string(text)
        case let .bool(flag): return .bool(flag)
        case let .list(items): return .list(ScriptList(items.map(scriptValue)))
        case let .map(entries):
            let map = ScriptMap()
            for key in entries.keys.sorted() {
                if let item = entries[key] { map[key] = scriptValue(item) }
            }
            return .map(map)
        }
    }

    /// Sends changed saves back to their players' iPads.
    func flushSaves() {
        for state in orderedStates where state.saveChanged {
            guard let saved = state.saved, clock - state.lastSaveSent >= SaveTiming.flushInterval else { continue }
            state.saveChanged = false
            state.lastSaveSent = clock
            send(state, .script(.store(saved)))
        }
    }
}
