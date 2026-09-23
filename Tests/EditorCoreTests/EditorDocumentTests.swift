import XCTest
@testable import AbloxCore

final class EditorDocumentTests: XCTestCase {

    private func makeDocument() -> EditorDocument {
        EditorDocument(world: .blank(named: "Test"))
    }

    // MARK: Adding

    func testAddPartInsertsSelectsAndSnaps() {
        var doc = makeDocument()
        doc.gridSize = 0.5
        let before = doc.world.blocks.count

        let id = doc.addPart(.block, at: Vec3(1.2, 0.3, -2.4))

        XCTAssertEqual(doc.world.blocks.count, before + 1)
        XCTAssertEqual(doc.selection, [id])
        let block = doc.world.block(id: id)!
        XCTAssertEqual(block.position, Vec3(1.0, 0.5, -2.5), "the new part snaps to the grid")
        XCTAssertTrue(doc.hasUnsavedChanges)
    }

    func testAddPartWithSnappingOffKeepsExactPosition() {
        var doc = makeDocument()
        doc.gridSize = 0
        let id = doc.addPart(.block, at: Vec3(1.234, 0, 5.678))
        XCTAssertEqual(doc.world.block(id: id)!.position, Vec3(1.234, 0, 5.678))
    }

    func testAddedPartsGetUniqueNames() {
        var doc = makeDocument()
        let a = doc.addPart(.block, at: .zero)
        let b = doc.addPart(.block, at: Vec3(4, 0, 0))
        XCTAssertNotEqual(doc.world.block(id: a)!.name, doc.world.block(id: b)!.name)
    }

    // MARK: Undo / redo

    func testUndoRedoOfAnInsert() {
        var doc = makeDocument()
        let before = doc.world.blocks.count
        let id = doc.addPart(.block, at: .zero)

        XCTAssertTrue(doc.history.canUndo)
        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.world.blocks.count, before)
        XCTAssertNil(doc.world.block(id: id))
        XCTAssertTrue(doc.selection.isEmpty, "undoing an insert must drop it from the selection")

        XCTAssertTrue(doc.history.canRedo)
        XCTAssertTrue(doc.redo())
        XCTAssertNotNil(doc.world.block(id: id))
    }

    func testUndoRedoOfAModify() {
        var doc = makeDocument()
        let id = doc.addPart(.block, at: .zero)
        let original = doc.world.block(id: id)!.position

        doc.translateSelection(by: Vec3(4, 0, 0))
        XCTAssertNotEqual(doc.world.block(id: id)!.position, original)

        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.world.block(id: id)!.position, original)

        XCTAssertTrue(doc.redo())
        XCTAssertEqual(doc.world.block(id: id)!.position.x, original.x + 4, accuracy: 1e-4)
    }

    func testUndoOnEmptyHistoryIsHarmless() {
        var doc = makeDocument()
        XCTAssertFalse(doc.history.canUndo)
        XCTAssertFalse(doc.undo())
        XCTAssertFalse(doc.redo())
    }

    func testNewEditClearsTheRedoBranch() {
        var doc = makeDocument()
        doc.addPart(.block, at: .zero)
        XCTAssertTrue(doc.undo())
        XCTAssertTrue(doc.history.canRedo)

        doc.addPart(.pillar, at: Vec3(5, 0, 0))
        XCTAssertFalse(doc.history.canRedo, "a new edit abandons the redo branch")
    }

    func testHistoryIsBounded() {
        var doc = makeDocument()
        for i in 0..<(EditHistory.defaultLimit + 20) {
            doc.addPart(.block, at: Vec3(Float(i) * 3, 0, 0))
        }
        XCTAssertEqual(doc.history.depth, EditHistory.defaultLimit)
    }

    func testUndoLabelsDescribeTheEdit() {
        var doc = makeDocument()
        doc.addPart(.orb, at: .zero)
        XCTAssertEqual(doc.history.undoLabel?.hasPrefix("Add"), true)

        doc.translateSelection(by: Vec3(1, 0, 0))
        XCTAssertEqual(doc.history.undoLabel?.hasPrefix("Edit"), true)
    }

    // MARK: Gesture coalescing

    func testDragCoalescesIntoOneUndoStep() {
        var doc = makeDocument()
        doc.gridSize = 0
        let id = doc.addPart(.block, at: .zero)
        let start = doc.world.block(id: id)!.position
        let depthAfterInsert = doc.history.depth

        // Simulate a drag: sixty per-frame edits.
        doc.beginGesture()
        for _ in 0..<60 {
            doc.translateSelection(by: Vec3(0.1, 0, 0))
        }
        doc.endGesture()

        XCTAssertEqual(doc.history.depth, depthAfterInsert + 1, "a whole drag is one undo step")

        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.world.block(id: id)!.position.x, start.x, accuracy: 1e-3,
                       "undo returns the block to where the drag began")
    }

    func testEditsOutsideAGestureDoNotCoalesce() {
        var doc = makeDocument()
        doc.gridSize = 0
        doc.addPart(.block, at: .zero)
        let depth = doc.history.depth

        doc.translateSelection(by: Vec3(1, 0, 0))
        doc.translateSelection(by: Vec3(1, 0, 0))
        doc.translateSelection(by: Vec3(1, 0, 0))

        XCTAssertEqual(doc.history.depth, depth + 3)
    }

    // MARK: Deleting

    func testDeleteRemovesSubtreeAndUndoRestoresIt() {
        var doc = makeDocument()
        let parent = doc.addPart(.block, at: .zero)
        let child = doc.addPart(.orb, at: Vec3(0, 3, 0))
        XCTAssertTrue(doc.reparent(child, to: parent))

        doc.select(parent)
        doc.deleteSelection()

        XCTAssertNil(doc.world.block(id: parent))
        XCTAssertNil(doc.world.block(id: child), "children must not be orphaned")

        XCTAssertTrue(doc.undo())
        XCTAssertNotNil(doc.world.block(id: parent))
        XCTAssertNotNil(doc.world.block(id: child), "undo restores the whole subtree")
        XCTAssertEqual(doc.world.block(id: child)?.parentID, parent, "including its parent link")
    }

    func testDeletingAWhollySelectedSubtreeDoesNotDoubleDelete() {
        var doc = makeDocument()
        let parent = doc.addPart(.block, at: .zero)
        let child = doc.addPart(.orb, at: Vec3(0, 3, 0))
        doc.reparent(child, to: parent)

        // Select both parent and child, as a rubber-band select would.
        doc.selection = [parent, child]
        let countBefore = doc.world.blocks.count
        doc.deleteSelection()
        XCTAssertEqual(doc.world.blocks.count, countBefore - 2)

        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.world.blocks.count, countBefore, "undo must not resurrect duplicates")
        XCTAssertEqual(doc.world.blocks.filter { $0.id == child }.count, 1)
    }

    func testDeletingNothingIsHarmless() {
        var doc = makeDocument()
        let depth = doc.history.depth
        doc.clearSelection()
        doc.deleteSelection()
        XCTAssertEqual(doc.history.depth, depth)
    }

    // MARK: Duplicating

    func testDuplicateCopiesSubtreeWithFreshIDs() {
        var doc = makeDocument()
        let parent = doc.addPart(.block, at: .zero)
        let child = doc.addPart(.orb, at: Vec3(0, 3, 0))
        doc.reparent(child, to: parent)

        doc.select(parent)
        let countBefore = doc.world.blocks.count
        doc.duplicateSelection()

        XCTAssertEqual(doc.world.blocks.count, countBefore * 2 - (countBefore - 2), "both blocks copied")
        XCTAssertEqual(doc.selection.count, 1)

        let copyID = doc.selection.first!
        XCTAssertNotEqual(copyID, parent)

        // The copy's child must point at the copy, not at the original.
        let copies = doc.world.children(of: copyID)
        XCTAssertEqual(copies.count, 1)
        XCTAssertNotEqual(copies[0].id, child)
    }

    func testDuplicateIsOneUndoStep() {
        var doc = makeDocument()
        let id = doc.addPart(.block, at: .zero)
        doc.select(id)
        let depth = doc.history.depth
        let countBefore = doc.world.blocks.count

        doc.duplicateSelection()
        XCTAssertEqual(doc.history.depth, depth + 1)

        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.world.blocks.count, countBefore)
    }

    // MARK: Transform operations

    func testRotateSnapsToTheAngleIncrement() {
        var doc = makeDocument()
        doc.angleSnap = 15
        let id = doc.addPart(.block, at: .zero)
        doc.rotateSelection(byDegrees: Vec3(0, 22, 0))
        XCTAssertEqual(doc.world.block(id: id)!.rotationDegrees.y, 15, accuracy: 0.5)
    }

    func testRotateWithoutSnapKeepsTheExactAngle() {
        var doc = makeDocument()
        doc.angleSnap = 0
        let id = doc.addPart(.block, at: .zero)
        doc.rotateSelection(byDegrees: Vec3(0, 22, 0))
        XCTAssertEqual(doc.world.block(id: id)!.rotationDegrees.y, 22, accuracy: 0.5)
    }

    func testScaleIsClampedAboveZero() {
        var doc = makeDocument()
        let id = doc.addPart(.block, at: .zero)
        // Scaling to nothing would make the block invisible and invert its
        // normals; it must clamp instead.
        doc.scaleSelection(by: Vec3(repeating: 0))
        let scale = doc.world.block(id: id)!.scale
        XCTAssertGreaterThan(scale.x, 0)
        XCTAssertGreaterThan(scale.y, 0)
        XCTAssertGreaterThan(scale.z, 0)
    }

    func testMultiSelectEditIsOneUndoStep() {
        var doc = makeDocument()
        let a = doc.addPart(.block, at: .zero)
        let b = doc.addPart(.block, at: Vec3(5, 0, 0))
        doc.selection = [a, b]
        let depth = doc.history.depth

        doc.translateSelection(by: Vec3(0, 2, 0))
        XCTAssertEqual(doc.history.depth, depth + 1)

        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.world.block(id: a)!.position.y, 0.5, accuracy: 0.6)
        XCTAssertEqual(doc.world.block(id: b)!.position.y, 0.5, accuracy: 0.6)
    }

    func testMutatingWithNoChangeRecordsNothing() {
        var doc = makeDocument()
        doc.addPart(.block, at: .zero)
        let depth = doc.history.depth
        doc.mutateSelection(label: "No-op") { _ in }
        XCTAssertEqual(doc.history.depth, depth)
    }

    // MARK: Reparenting

    func testReparentRejectsCycles() {
        var doc = makeDocument()
        let parent = doc.addPart(.block, at: .zero)
        let child = doc.addPart(.block, at: Vec3(3, 0, 0))
        XCTAssertTrue(doc.reparent(child, to: parent))

        let depth = doc.history.depth
        XCTAssertFalse(doc.reparent(parent, to: child), "a cycle must be refused")
        XCTAssertEqual(doc.history.depth, depth, "a refused edit records no undo step")
        XCTAssertNil(doc.world.block(id: parent)?.parentID)
    }

    func testReparentToSelfIsRefused() {
        var doc = makeDocument()
        let id = doc.addPart(.block, at: .zero)
        XCTAssertFalse(doc.reparent(id, to: id))
    }

    func testReparentIsUndoable() {
        var doc = makeDocument()
        let parent = doc.addPart(.block, at: .zero)
        let child = doc.addPart(.block, at: Vec3(3, 0, 0))

        XCTAssertTrue(doc.reparent(child, to: parent))
        XCTAssertEqual(doc.world.block(id: child)?.parentID, parent)

        XCTAssertTrue(doc.undo())
        XCTAssertNil(doc.world.block(id: child)?.parentID)
    }

    func testReparentToTheSameParentIsANoOp() {
        var doc = makeDocument()
        let id = doc.addPart(.block, at: .zero)
        let depth = doc.history.depth
        XCTAssertFalse(doc.reparent(id, to: nil), "already at the root")
        XCTAssertEqual(doc.history.depth, depth)
    }

    // MARK: Environment and rules

    func testEnvironmentChangeIsUndoable() {
        var doc = makeDocument()
        let original = doc.world.environment

        var changed = original
        changed.gravity = -2
        doc.setEnvironment(changed)
        XCTAssertEqual(doc.world.environment.gravity, -2)

        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.world.environment, original)
    }

    func testSettingIdenticalEnvironmentRecordsNothing() {
        var doc = makeDocument()
        let depth = doc.history.depth
        doc.setEnvironment(doc.world.environment)
        XCTAssertEqual(doc.history.depth, depth)
    }

    func testRulesChangeIsUndoable() {
        var doc = makeDocument()
        let rule = EventRule(name: "Test", trigger: .worldStart, actions: [.playSound(name: "x")])
        doc.setRules([rule])
        XCTAssertEqual(doc.world.rules, [rule])

        XCTAssertTrue(doc.undo())
        XCTAssertTrue(doc.world.rules.isEmpty)
    }

    // MARK: Co-editing

    func testEveryEditProducesDeltasForPeers() {
        var doc = makeDocument()
        _ = doc.drainDeltas()

        let id = doc.addPart(.block, at: .zero)
        let deltas = doc.drainDeltas()
        XCTAssertEqual(deltas.count, 1)
        guard case let .insert(block) = deltas[0] else {
            return XCTFail("expected an insert delta, got \(deltas[0])")
        }
        XCTAssertEqual(block.id, id)

        XCTAssertTrue(doc.drainDeltas().isEmpty, "draining twice must not repeat")
    }

    func testUndoAlsoProducesDeltas() {
        var doc = makeDocument()
        let id = doc.addPart(.block, at: .zero)
        _ = doc.drainDeltas()

        XCTAssertTrue(doc.undo())
        let deltas = doc.drainDeltas()
        XCTAssertEqual(deltas.count, 1)
        guard case let .remove(removedID) = deltas[0] else {
            return XCTFail("undoing an insert must broadcast a remove, got \(deltas[0])")
        }
        XCTAssertEqual(removedID, id)
    }

    func testRemoteEditsDoNotEnterLocalHistory() {
        var doc = makeDocument()
        let depth = doc.history.depth

        // A peer adds a block.
        let remote = BlockData(name: "From Taro", transform: Transform3D(position: Vec3(9, 0, 0)))
        doc.applyRemote(.insert(remote))

        XCTAssertNotNil(doc.world.block(id: remote.id))
        XCTAssertEqual(doc.history.depth, depth, "undoing someone else's edit from your history would be baffling")
        XCTAssertTrue(doc.drainDeltas().isEmpty, "a remote edit must not be echoed back")
    }

    func testRemoteDeleteDropsTheBlockFromSelection() {
        var doc = makeDocument()
        let id = doc.addPart(.block, at: .zero)
        XCTAssertEqual(doc.selection, [id])

        doc.applyRemote(.remove(blockID: id))
        XCTAssertTrue(doc.selection.isEmpty)
    }

    // MARK: Selection

    func testAdditiveSelectionToggles() {
        var doc = makeDocument()
        let a = doc.addPart(.block, at: .zero)
        let b = doc.addPart(.block, at: Vec3(5, 0, 0))

        doc.select(a)
        doc.select(b, additive: true)
        XCTAssertEqual(doc.selection, [a, b])

        doc.select(b, additive: true)
        XCTAssertEqual(doc.selection, [a], "tapping an already-selected block deselects it")
    }

    func testSelectNilClearsSelection() {
        var doc = makeDocument()
        doc.addPart(.block, at: .zero)
        doc.select(nil)
        XCTAssertTrue(doc.selection.isEmpty)
    }

    func testSelectionBoundsCoverEverythingSelected() {
        var doc = makeDocument()
        let a = doc.addPart(.block, at: Vec3(-10, 0, 0))
        let b = doc.addPart(.block, at: Vec3(10, 0, 0))
        doc.selection = [a, b]

        let bounds = doc.selectionBounds
        XCTAssertNotNil(bounds)
        XCTAssertLessThanOrEqual(bounds!.min.x, -10)
        XCTAssertGreaterThanOrEqual(bounds!.max.x, 10)

        doc.clearSelection()
        XCTAssertNil(doc.selectionBounds)
    }

    // MARK: Saving

    func testSavingClearsTheDirtyFlag() {
        var doc = makeDocument()
        XCTAssertFalse(doc.hasUnsavedChanges)
        doc.addPart(.block, at: .zero)
        XCTAssertTrue(doc.hasUnsavedChanges)
        doc.markSaved()
        XCTAssertFalse(doc.hasUnsavedChanges)
        doc.addPart(.block, at: Vec3(4, 0, 0))
        XCTAssertTrue(doc.hasUnsavedChanges)
    }

    // MARK: Command algebra

    func testEveryCommandInverseRoundTrips() {
        let block = BlockData(name: "Subject")
        var modified = block
        modified.name = "Changed"

        let commands: [EditCommand] = [
            .insert(block),
            .modify(before: block, after: modified),
            .reparent(blockID: block.id, from: nil, to: UUID()),
            .setEnvironment(before: .default, after: EnvironmentSettings(gravity: -3)),
            .setRules(before: [], after: [EventRule(name: "r", trigger: .worldStart, actions: [])])
        ]

        for command in commands {
            XCTAssertEqual(command.inverse.inverse, command, "\(command.label) must invert twice to itself")
        }
    }

    func testGroupInverseUnwindsInReverseOrder() {
        let a = BlockData(name: "A")
        let b = BlockData(name: "B")
        let group = EditCommand.group(label: "Two", commands: [.insert(a), .insert(b)])

        guard case let .group(_, inverted) = group.inverse else {
            return XCTFail("the inverse of a group must be a group")
        }
        XCTAssertEqual(inverted.count, 2)
        guard case let .delete(first) = inverted[0] else {
            return XCTFail("expected a delete, got \(inverted[0])")
        }
        XCTAssertEqual(first.id, b.id, "the last insert is undone first")
    }

    func testCommandsExposeTheirDeltas() {
        let block = BlockData(name: "X")
        XCTAssertEqual(EditCommand.insert(block).deltas.count, 1)
        XCTAssertEqual(EditCommand.group(label: "g", commands: [.insert(block), .delete(block)]).deltas.count, 2)
    }

    // MARK: Scripts

    func testScriptFilesAreUndoableAndTravelToCoEditors() {
        var doc = makeDocument()
        let id = doc.addScript(named: "main", source: "on start()\nend")
        XCTAssertNotNil(id)
        XCTAssertEqual(doc.world.scripts.map(\.name), ["main.absc"])
        guard case let .scriptsReplaced(files)? = doc.drainDeltas().last else {
            return XCTFail("co-editors must be sent the files")
        }
        XCTAssertEqual(files.map(\.name), ["main.absc"])

        XCTAssertTrue(doc.undo())
        XCTAssertTrue(doc.world.scripts.isEmpty)
        XCTAssertEqual(doc.drainDeltas(), [.scriptsReplaced([])], "an undo reaches co-editors too")
    }

    func testFileNamesStayUnique() {
        var doc = makeDocument()
        doc.addScript(named: "main")
        doc.addScript(named: "main")
        let third = doc.addScript(named: "ui")!
        doc.renameScript(third, to: "main.absc")
        XCTAssertEqual(doc.world.scripts.map(\.name), ["main.absc", "main 2.absc", "main 3.absc"])
    }

    func testEditingSwitchingAndRemovingFiles() {
        var doc = makeDocument()
        let id = doc.addScript(named: "main")!
        doc.updateScript(id, source: "print(1)")
        doc.setScriptEnabled(id, false)
        XCTAssertEqual(doc.world.scripts.first?.source, "print(1)")
        XCTAssertEqual(doc.world.scripts.first?.isEnabled, false)
        doc.removeScript(id)
        XCTAssertTrue(doc.world.scripts.isEmpty)
    }

    func testTypingIsOneUndoStep() {
        var doc = makeDocument()
        let id = doc.addScript(named: "main")!
        doc.beginGesture()
        for text in ["o", "on", "on s", "on start()"] {
            doc.updateScript(id, source: text)
        }
        doc.endGesture()
        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.world.scripts.first?.source, "", "one undo takes back the whole visit to the editor")
    }
}
