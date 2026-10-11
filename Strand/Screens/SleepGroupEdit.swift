import Foundation
import WhoopStore
import StrandAnalytics

/// Applies a corrected bed/wake window to every stored fragment of one bridged main sleep night.
enum SleepGroupEdit {
    struct Plan {
        let clipped: [CachedSleepSession]
        let dropped: [CachedSleepSession]
    }

    /// Outer surviving fragments take the drawn bounds; interior fragments only narrow. Fragments with
    /// no overlap are dropped, otherwise they would continue defining the displayed night after a save.
    /// An empty plan means the edit is wholly disjoint and must not silently delete the night.
    static func plan(_ group: [CachedSleepSession], newStartTs: Int, newEndTs: Int) -> Plan {
        guard !group.isEmpty, newEndTs > newStartTs else { return Plan(clipped: [], dropped: []) }
        let ordered = group.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        let kept = ordered.filter {
            min($0.endTs, newEndTs) > max($0.effectiveStartTs, newStartTs)
        }
        guard !kept.isEmpty else { return Plan(clipped: [], dropped: []) }
        let dropped = ordered.filter {
            min($0.endTs, newEndTs) <= max($0.effectiveStartTs, newStartTs)
        }
        let clipped = kept.enumerated().map { index, fragment in
            let start = index == 0 ? newStartTs : max(fragment.effectiveStartTs, newStartTs)
            let end = index == kept.count - 1 ? newEndTs : min(fragment.endTs, newEndTs)
            let stages = SleepWindowReclip.reclip(
                stagesJSON: fragment.stagesJSON,
                sessionStart: fragment.effectiveStartTs,
                oldEnd: fragment.endTs,
                newStart: start,
                newEnd: end
            ) ?? fragment.stagesJSON
            return CachedSleepSession(
                startTs: fragment.startTs,
                endTs: end,
                efficiency: fragment.efficiency,
                restingHr: fragment.restingHr,
                avgHrv: fragment.avgHrv,
                stagesJSON: stages,
                userEdited: true,
                startTsAdjusted: start,
                stagingSparse: fragment.stagingSparse,
                deviceId: fragment.deviceId
            )
        }
        return Plan(clipped: clipped, dropped: dropped)
    }

    /// The whole group's first onset and latest wake, matching the displayed bridged span.
    static func groupWindow(_ group: [CachedSleepSession]) -> (start: Int, end: Int)? {
        guard let first = group.min(by: { $0.effectiveStartTs < $1.effectiveStartTs }),
              let last = group.max(by: { $0.endTs < $1.endTs }),
              last.endTs > first.effectiveStartTs else { return nil }
        return (first.effectiveStartTs, last.endTs)
    }
}
