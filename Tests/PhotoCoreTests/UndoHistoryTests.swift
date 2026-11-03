import XCTest
@testable import PhotoCore

final class UndoHistoryTests: XCTestCase {
    // A fixed clock keeps the 0.5 s merge window deterministic.
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeHistory(capacity: Int = 50) -> UndoHistory {
        let start = self.start
        return UndoHistory(capacity: capacity, mergeInterval: 0.5, clock: { start })
    }

    private func snapshot(_ exposure: Double, lut: String = "none",
                          colorSpace: LUTColorSpace = .sRGB) -> UndoSnapshot {
        var adjustments = AdjustmentSettings()
        adjustments.exposureEV = exposure
        return UndoSnapshot(adjustments: adjustments, lutID: lut, lutColorSpace: colorSpace)
    }

    // MARK: - push / undo / redo

    func testUndoRedoWalkIsContinuous() {
        var history = makeHistory()
        let s0 = snapshot(0), s1 = snapshot(1), s2 = snapshot(2)
        XCTAssertTrue(history.push(s0, key: UndoHistory.initialKey, at: start))
        XCTAssertTrue(history.push(s1, key: "basic.exposureEV", at: start + 1))
        XCTAssertTrue(history.push(s2, key: "basic.exposureEV", at: start + 2))
        XCTAssertEqual(history.count, 3)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.current, s2)

        XCTAssertEqual(history.undo(), s1)
        XCTAssertEqual(history.undo(), s0)
        XCTAssertNil(history.undo(), "oldest state has nothing below it")
        XCTAssertFalse(history.canUndo)

        XCTAssertEqual(history.redo(), s1)
        XCTAssertEqual(history.redo(), s2)
        XCTAssertNil(history.redo(), "no redo branch above the newest state")
        XCTAssertEqual(history.current, s2)
    }

    func testEmptyHistoryCannotUndoOrRedo() {
        var history = makeHistory()
        XCTAssertNil(history.undo())
        XCTAssertNil(history.redo())
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.current)
        XCTAssertTrue(history.isEmpty)
    }

    func testDuplicateSnapshotIsIgnoredAndKeepsRedo() {
        var history = makeHistory()
        let s0 = snapshot(0), s1 = snapshot(1), s2 = snapshot(2)
        history.push(s0, key: UndoHistory.initialKey, at: start)
        history.push(s1, key: "basic.exposureEV", at: start + 1)
        history.push(s2, key: "basic.saturation", at: start + 2)
        _ = history.undo()
        XCTAssertTrue(history.canRedo)
        XCTAssertFalse(history.push(s1, key: "basic.exposureEV", at: start + 3),
                       "pushing the current state must not add a step")
        XCTAssertEqual(history.count, 3)
        XCTAssertTrue(history.canRedo, "a no-op edit must not clear the redo branch")
    }

    // MARK: - merge window

    func testSameKeyEditsMergeWithinMergeInterval() {
        var history = makeHistory()
        let s0 = snapshot(0), s1 = snapshot(0.1), s2 = snapshot(0.2)
        history.push(s0, key: UndoHistory.initialKey, at: start)
        history.push(s1, key: "basic.exposureEV", at: start + 0.01)
        history.push(s2, key: "basic.exposureEV", at: start + 0.4)
        XCTAssertEqual(history.count, 2, "one initial state plus one merged drag")
        XCTAssertEqual(history.current, s2)
        XCTAssertEqual(history.undo(), s0, "one undo reverts the whole merged drag")
    }

    func testSameKeyEditsAfterIntervalBecomeSeparateSteps() {
        var history = makeHistory()
        let s0 = snapshot(0), s1 = snapshot(0.1), s2 = snapshot(0.2)
        history.push(s0, key: UndoHistory.initialKey, at: start)
        history.push(s1, key: "basic.exposureEV", at: start + 0.01)
        history.push(s2, key: "basic.exposureEV", at: start + 0.6)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.undo(), s1)
    }

    func testRollingWindowKeepsOneStepDuringContinuousDrag() {
        var history = makeHistory()
        let s0 = snapshot(0), s1 = snapshot(0.1), s2 = snapshot(0.2), s3 = snapshot(0.3)
        history.push(s0, key: UndoHistory.initialKey, at: start)
        history.push(s1, key: "basic.exposureEV", at: start + 0.01)
        history.push(s2, key: "basic.exposureEV", at: start + 0.41)
        history.push(s3, key: "basic.exposureEV", at: start + 0.81)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.current, s3)
    }

    func testDifferentKeysDoNotMerge() {
        var history = makeHistory()
        let s0 = snapshot(0), s1 = snapshot(0.1), s2 = snapshot(0.2)
        history.push(s0, key: UndoHistory.initialKey, at: start)
        history.push(s1, key: "basic.exposureEV", at: start + 0.01)
        history.push(s2, key: "basic.contrast", at: start + 0.02)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.currentKey, "basic.contrast")
    }

    func testUndoThenPushDoesNotMergeIntoOlderEntry() {
        var history = makeHistory()
        let s0 = snapshot(0), s1 = snapshot(0.1), s2 = snapshot(0.2), s3 = snapshot(0.3)
        history.push(s0, key: UndoHistory.initialKey, at: start)
        history.push(s1, key: "basic.exposureEV", at: start + 0.01)
        history.push(s2, key: "basic.exposureEV", at: start + 0.4)
        XCTAssertEqual(history.undo(), s0)
        XCTAssertTrue(history.push(s3, key: "basic.exposureEV", at: start + 0.45))
        XCTAssertEqual(history.count, 2)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.current, s3)
    }

    // MARK: - capacity and redo invalidation

    func testCapacityDropsOldestEntries() {
        var history = makeHistory(capacity: 3)
        let states = (0..<5).map { snapshot(Double($0)) }
        for (index, state) in states.enumerated() {
            history.push(state, key: "basic.exposureEV.\(index)", at: start + Double(index))
        }
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.entries.map(\.snapshot), [states[2], states[3], states[4]])
        XCTAssertEqual(history.undo(), states[3])
        XCTAssertEqual(history.undo(), states[2])
        XCTAssertNil(history.undo())
    }

    func testNewEditClearsRedoBranch() {
        var history = makeHistory()
        let s0 = snapshot(0), s1 = snapshot(1), s2 = snapshot(2), s3 = snapshot(3)
        history.push(s0, key: UndoHistory.initialKey, at: start)
        history.push(s1, key: "basic.exposureEV", at: start + 1)
        history.push(s2, key: "basic.saturation", at: start + 2)
        XCTAssertEqual(history.undo(), s1)
        XCTAssertTrue(history.canRedo)
        history.push(s3, key: "basic.contrast", at: start + 3)
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.redo())
        XCTAssertEqual(history.entries.map(\.snapshot), [s0, s1, s3])
    }

    func testResetClearsAllEntries() {
        var history = makeHistory()
        history.push(snapshot(0), key: UndoHistory.initialKey, at: start)
        history.push(snapshot(1), key: "basic.exposureEV", at: start + 1)
        history.reset()
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(history.current)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    // MARK: - snapshot contents

    func testSnapshotCodableRoundTripPreservesMasksAndBaseline() throws {
        var adjustments = AdjustmentSettings()
        adjustments.exposureEV = -0.75
        adjustments.masks = [LocalMask(name: "天空", kind: .linear, exposureEV: 0.4)]
        adjustments.adaptiveLUT = AdaptiveLUTSettings()
        let baseline = AutomaticBatchRecipe(styleID: "balanced",
                                            baseline: adjustments,
                                            referenceSettings: .init(),
                                            sceneIntent: .portrait)
        let snapshot = UndoSnapshot(adjustments: adjustments, lutID: "film.portra-400",
                                    lutColorSpace: .rec709, automaticRecipe: baseline,
                                    sceneIntent: .portrait)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UndoSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testSnapshotEqualityCoversLookAndBaseline() {
        let base = UndoSnapshot(adjustments: .init(), lutID: "none")
        XCTAssertNotEqual(base, UndoSnapshot(adjustments: .init(), lutID: "film.portra-400"))
        XCTAssertNotEqual(base, UndoSnapshot(adjustments: .init(), lutID: "none", lutColorSpace: .rec709))
        XCTAssertNotEqual(base, UndoSnapshot(adjustments: .init(), lutID: "none", sceneIntent: .portrait))
        var adjusted = AdjustmentSettings()
        adjusted.contrast = 1.2
        XCTAssertNotEqual(base, UndoSnapshot(adjustments: adjusted, lutID: "none"))
    }

    // MARK: - coalescing keys derived from adjustments

    func testUndoEditKeyIdentifiesChangedField() {
        let base = AdjustmentSettings()
        XCTAssertNil(base.undoEditKey(comparedTo: base))
        var exposure = base
        exposure.exposureEV = 0.5
        XCTAssertEqual(exposure.undoEditKey(comparedTo: base), "basic.exposureEV")
        var look = base
        look.lutIntensity = 0.9
        XCTAssertEqual(look.undoEditKey(comparedTo: base), "look.lutIntensity")
        var curve = base
        curve.tonalCurve = TonalCurveSettings(blacksEV: -0.2)
        XCTAssertEqual(curve.undoEditKey(comparedTo: base), "curve.tonalCurve")
    }

    func testUndoEditKeySeparatesMaskStructureAndParameterDrags() {
        var withMask = AdjustmentSettings()
        withMask.masks = [LocalMask(name: "局部", kind: .radial)]
        XCTAssertEqual(withMask.undoEditKey(comparedTo: .init()), "mask.structure")

        var moved = withMask
        moved.masks[0].exposureEV = 0.9
        let maskID = withMask.masks[0].id.uuidString
        XCTAssertEqual(moved.undoEditKey(comparedTo: withMask), "mask.\(maskID)")

        var secondMask = withMask
        secondMask.masks.append(LocalMask(name: "第二个"))
        XCTAssertEqual(secondMask.undoEditKey(comparedTo: withMask), "mask.structure")
    }

    func testDefaultCapacityIsBounded() {
        let history = UndoHistory()
        XCTAssertEqual(history.capacity, 50)
        XCTAssertEqual(history.mergeInterval, 0.5, accuracy: 0.0001)
    }
}
