import XCTest
import WhoopStore
@testable import Strand

/// A main sleep night is displayed as one bridged group, so correcting its displayed window must update
/// every fragment and retire outlying rows instead of editing only the winning fragment.
final class SleepGroupEditTests: XCTestCase {
    private func lightStage(_ start: Int, _ end: Int) -> String {
        #"[{"start":\#(start),"end":\#(end),"stage":"light"}]"#
    }
    private let source = "my-whoop"

    @MainActor
    func testEditingBridgedNightMakesPersistedGroupMatchDrawnWindow() async throws {
        let dismissedKey = Repository.dismissedSleepDefaultsKey
        let previousDismissals = UserDefaults.standard.stringArray(forKey: dismissedKey)
        defer {
            if let previousDismissals { UserDefaults.standard.set(previousDismissals, forKey: dismissedKey) }
            else { UserDefaults.standard.removeObject(forKey: dismissedKey) }
        }
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: source, mac: nil, name: "WHOOP")
        let now = Int(Date().timeIntervalSince1970)
        let t0 = now - 12 * 3_600
        let fragments = [
            CachedSleepSession(startTs: t0, endTs: t0 + 2 * 3_600,
                               efficiency: nil, restingHr: nil, avgHrv: nil,
                               stagesJSON: lightStage(t0, t0 + 2 * 3_600)),
            CachedSleepSession(startTs: t0 + 3 * 3_600, endTs: t0 + 6 * 3_600,
                               efficiency: nil, restingHr: nil, avgHrv: nil,
                               stagesJSON: lightStage(t0 + 3 * 3_600, t0 + 6 * 3_600)),
            CachedSleepSession(startTs: t0 + 6 * 3_600, endTs: t0 + 10 * 3_600,
                               efficiency: nil, restingHr: nil, avgHrv: nil,
                               stagesJSON: lightStage(t0 + 6 * 3_600, t0 + 10 * 3_600)),
        ]
        _ = try await store.upsertSleepSessions(fragments, deviceId: source)
        let group = try await store.sleepSessions(deviceId: source, from: t0, to: now, limit: 10)
        let newStart = t0 + 3 * 3_600
        let newEnd = t0 + 9 * 3_600
        let repository = Repository(deviceId: source)
        repository.setStoreForTesting(store)

        await repository.editSleepGroupTimes(sessions: group, newStartTs: newStart, newEndTs: newEnd)

        let saved = try await store.sleepSessions(deviceId: source, from: t0, to: now, limit: 10)
        XCTAssertEqual(saved.count, 2, "the earlier block outside the correction must be retired")
        XCTAssertEqual(saved.map(\.effectiveStartTs).min(), newStart,
                       "the displayed onset must move to the drawn start")
        XCTAssertEqual(saved.map(\.endTs).max(), newEnd,
                       "the displayed wake must move to the drawn end")
        let displayed = try XCTUnwrap(SleepGroupEdit.groupWindow(saved))
        XCTAssertEqual(displayed.start, newStart)
        XCTAssertEqual(displayed.end, newEnd)
        let asleepMinutes = saved.reduce(0.0) {
            $0 + SleepView.decodedAsleepMinutes($1.stagesJSON, effectiveStartTs: $1.effectiveStartTs)
        }
        XCTAssertEqual(asleepMinutes, 6 * 60, accuracy: 0.001,
                       "the removed early fragment must no longer inflate the displayed asleep total")
        XCTAssertTrue(saved.allSatisfy(\.userEdited))
        XCTAssertTrue(repository.dismissedSleepWindows().contains {
            $0.start == t0 && $0.end == t0 + 2 * 3_600
        }, "retiring a detected fragment must prevent it being re-detected into the bridged night")
    }

    func testMergedNightKeepsExplicitOnsetWhenEditLeavesOnlyTenMinutes() throws {
        let calendar = Calendar.current
        let priorDay = calendar.startOfDay(for: Date()).addingTimeInterval(-2 * 24 * 3_600)
        let bedtime = try XCTUnwrap(calendar.date(bySettingHour: 22, minute: 0, second: 0, of: priorDay))
        let t0 = Int(bedtime.timeIntervalSince1970)
        let firstEnd = t0 + 30 * 60
        let mainStart = firstEnd + 5 * 60
        let wake = mainStart + 8 * 3_600
        let original = [
            CachedSleepSession(startTs: t0, endTs: firstEnd,
                               efficiency: nil, restingHr: nil, avgHrv: nil,
                               stagesJSON: lightStage(t0, firstEnd)),
            CachedSleepSession(startTs: mainStart, endTs: wake,
                               efficiency: nil, restingHr: nil, avgHrv: nil,
                               stagesJSON: lightStage(mainStart, wake)),
        ]
        let correctedBedtime = t0 + 20 * 60
        let plan = SleepGroupEdit.plan(original, newStartTs: correctedBedtime, newEndTs: wake)
        XCTAssertEqual(plan.clipped.first?.effectiveStartTs, correctedBedtime)
        XCTAssertEqual(plan.clipped.first?.endTs, t0 + 30 * 60,
                       "the edit keeps the ten minutes of the first fragment still inside its window")

        let night = try XCTUnwrap(SleepModel.mergeDay(
            plan.clipped, habitualMidsleepSec: nil, motionByStart: [:]))
        XCTAssertEqual(night.session.effectiveStartTs, correctedBedtime,
                       "the hero onset must retain the explicitly edited bound despite the short fragment")
        XCTAssertEqual(night.stages.light, 8 * 60 + 10, accuracy: 0.001,
                       "the ten remaining sleep minutes must remain in the merged hero total")
    }

    @MainActor
    func testRepeatedGroupEditTombstonesPreviouslyEditedDroppedDetection() async throws {
        let dismissedKey = Repository.dismissedSleepDefaultsKey
        let previousDismissals = UserDefaults.standard.stringArray(forKey: dismissedKey)
        defer {
            if let previousDismissals { UserDefaults.standard.set(previousDismissals, forKey: dismissedKey) }
            else { UserDefaults.standard.removeObject(forKey: dismissedKey) }
        }
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: source, mac: nil, name: "WHOOP")
        let now = Int(Date().timeIntervalSince1970)
        let t0 = now - 12 * 3_600
        let detected = [
            CachedSleepSession(startTs: t0, endTs: t0 + 2 * 3_600,
                               efficiency: nil, restingHr: nil, avgHrv: nil,
                               stagesJSON: lightStage(t0, t0 + 2 * 3_600)),
            CachedSleepSession(startTs: t0 + 3 * 3_600, endTs: t0 + 10 * 3_600,
                               efficiency: nil, restingHr: nil, avgHrv: nil,
                               stagesJSON: lightStage(t0 + 3 * 3_600, t0 + 10 * 3_600)),
        ]
        _ = try await store.upsertSleepSessions(detected, deviceId: source)
        let repository = Repository(deviceId: source)
        repository.setStoreForTesting(store)

        var group = try await store.sleepSessions(deviceId: source, from: t0, to: now, limit: 10)
        await repository.editSleepGroupTimes(
            sessions: group, newStartTs: t0 + 30 * 60, newEndTs: t0 + 8 * 3_600)
        group = try await store.sleepSessions(deviceId: source, from: t0, to: now, limit: 10)
        XCTAssertEqual(group.count, 2)
        XCTAssertTrue(group.allSatisfy { $0.userEdited && $0.startTsAdjusted != nil })

        await repository.editSleepGroupTimes(
            sessions: group, newStartTs: t0 + 3 * 3_600, newEndTs: t0 + 7 * 3_600)

        let saved = try await store.sleepSessions(deviceId: source, from: t0, to: now, limit: 10)
        XCTAssertEqual(saved.map(\.startTs), [t0 + 3 * 3_600])
        let windows = repository.dismissedSleepWindows()
        XCTAssertTrue(windows.contains { $0.start == t0 && $0.end == t0 + 2 * 3_600 },
                      "retiring an already-edited detected fragment must still write its tombstone")
        XCTAssertTrue(DismissedSleepSpans.isSuppressed(
            sessionStart: t0, sessionEnd: t0 + 2 * 3_600, windows: windows),
            "the next detected copy of the retired fragment must be filtered")
    }


    @MainActor
    func testUndoDeleteOfMiddleSleepFragmentRemovesItsExactTombstone() async throws {
        let dismissedKey = Repository.dismissedSleepDefaultsKey
        let previousDismissals = UserDefaults.standard.stringArray(forKey: dismissedKey)
        defer {
            if let previousDismissals { UserDefaults.standard.set(previousDismissals, forKey: dismissedKey) }
            else { UserDefaults.standard.removeObject(forKey: dismissedKey) }
        }
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: source, mac: nil, name: "WHOOP")
        let now = Int(Date().timeIntervalSince1970)
        let t0 = now - 12 * 3_600
        let fragments = [
            CachedSleepSession(startTs: t0, endTs: t0 + 2 * 3_600,
                               efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
            CachedSleepSession(startTs: t0 + 3 * 3_600, endTs: t0 + 6 * 3_600,
                               efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
            CachedSleepSession(startTs: t0 + 6 * 3_600, endTs: t0 + 10 * 3_600,
                               efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
        ]
        _ = try await store.upsertSleepSessions(fragments, deviceId: source)
        let visible = try await store.sleepSessions(deviceId: source, from: t0, to: now, limit: 10)
        let target = try XCTUnwrap(visible.first { $0.startTs == t0 + 3 * 3_600 })
        let displayedWake = try XCTUnwrap(visible.map(\.endTs).max())
        XCTAssertNotEqual(target.endTs, displayedWake,
                          "the deleted row is not the fragment defining the displayed group wake")

        let repository = Repository(deviceId: source)
        repository.setStoreForTesting(store)
        let deletion = await repository.deleteSleepSession(
            detectedStartTs: target.startTs, endTs: target.endTs)
        let snapshot = try XCTUnwrap(deletion)
        XCTAssertTrue(repository.dismissedSleepWindows().contains {
            $0.start == target.startTs && $0.end == target.endTs
        })
        XCTAssertFalse(repository.dismissedSleepWindows().contains {
            $0.start == target.startTs && $0.end == displayedWake
        }, "the group's display wake must not be stored as the target row's tombstone end")

        await repository.undoDeleteSleepSession(snapshot)

        XCTAssertFalse(repository.dismissedSleepWindows().contains {
            $0.start == target.startTs && $0.end == target.endTs
        }, "undo must lift the exact tombstone written for the deleted row")
        let restored = try await store.sleepSessions(deviceId: source, from: t0, to: now, limit: 10)
        XCTAssertEqual(restored.count, 3)
    }

    func testPlannerNarrowsInteriorFragmentsAndRefusesDisjointWindow() {
        let t0 = 1_780_000_000
        let group = [
            CachedSleepSession(startTs: t0, endTs: t0 + 2 * 3_600,
                               efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
            CachedSleepSession(startTs: t0 + 3 * 3_600, endTs: t0 + 5 * 3_600,
                               efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
            CachedSleepSession(startTs: t0 + 6 * 3_600, endTs: t0 + 8 * 3_600,
                               efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
        ]
        let newStart = t0 + 2 * 3_600 + 1_800
        let newEnd = t0 + 7 * 3_600
        let plan = SleepGroupEdit.plan(group, newStartTs: newStart, newEndTs: newEnd)
        XCTAssertEqual(plan.clipped.map(\.effectiveStartTs), [newStart, t0 + 6 * 3_600])
        XCTAssertEqual(plan.clipped.map(\.endTs), [t0 + 5 * 3_600, newEnd])
        XCTAssertEqual(plan.dropped.map(\.startTs), [t0])

        let disjoint = SleepGroupEdit.plan(group, newStartTs: t0 + 10 * 3_600, newEndTs: t0 + 11 * 3_600)
        XCTAssertTrue(disjoint.clipped.isEmpty, "a disjoint correction must never turn into deleting the whole night")
        XCTAssertTrue(disjoint.dropped.isEmpty)
    }
}
