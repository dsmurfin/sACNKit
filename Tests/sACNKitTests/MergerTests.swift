import Foundation
import Testing

@testable import sACNKit

/// Characterizes the HTP / per-address-priority merge engine (`sACNMerger`).
/// The merger is fully synchronous - no sockets, timers or clock.
@Suite("sACNMerger")
struct MergerTests {

    private func fullLevels(_ first: UInt8, rest: UInt8 = 0) -> [UInt8] {
        [first] + Array(repeating: rest, count: 511)
    }

    // MARK: Single source

    @Test("A single source with a universe priority merges all of its levels")
    func singleSourceMerges() throws {
        let merger = sACNMerger(id: 1)
        let source = UUID()
        try merger.addSource(identified: source)
        try merger.updateUniversePriorityForSource(identified: source, priority: 100)
        let levels = (0..<512).map { UInt8($0 % 256) }
        try merger.updateLevelsForSource(identified: source, newLevels: levels, newLevelsCount: 512)

        #expect(merger.levels == levels)
        #expect(merger.winners.allSatisfy { $0 == source })
    }

    @Test("A source with no priority does not appear in the output")
    func noPriorityNotSourced() throws {
        let merger = sACNMerger(id: 1)
        let source = UUID()
        try merger.addSource(identified: source)
        try merger.updateLevelsForSource(identified: source, newLevels: fullLevels(255), newLevelsCount: 512)

        #expect(merger.levels[0] == 0)
        #expect(merger.winners[0] == nil)
    }

    @Test("Universe priority 0 is treated as 1 (still sourced)")
    func universePriorityZeroIsOne() throws {
        let merger = sACNMerger(id: 1)
        let source = UUID()
        try merger.addSource(identified: source)
        try merger.updateUniversePriorityForSource(identified: source, priority: 0)
        try merger.updateLevelsForSource(identified: source, newLevels: fullLevels(123), newLevelsCount: 512)

        #expect(merger.levels[0] == 123)
        #expect(merger.winners[0] == source)
    }

    // MARK: Two sources

    @Test("At equal universe priority the higher level wins per slot (HTP)")
    func htpAtEqualPriority() throws {
        let merger = sACNMerger(id: 1)
        let a = UUID()
        let b = UUID()
        try merger.addSource(identified: a)
        try merger.addSource(identified: b)
        try merger.updateUniversePriorityForSource(identified: a, priority: 100)
        try merger.updateUniversePriorityForSource(identified: b, priority: 100)
        try merger.updateLevelsForSource(identified: a, newLevels: [200, 0] + Array(repeating: 0, count: 510), newLevelsCount: 512)
        try merger.updateLevelsForSource(identified: b, newLevels: [100, 255] + Array(repeating: 0, count: 510), newLevelsCount: 512)

        #expect(merger.levels[0] == 200)
        #expect(merger.winners[0] == a)
        #expect(merger.levels[1] == 255)
        #expect(merger.winners[1] == b)
    }

    @Test("A higher priority wins a slot regardless of level")
    func higherPriorityWins() throws {
        let merger = sACNMerger(id: 1)
        let a = UUID()
        let b = UUID()
        try merger.addSource(identified: a)
        try merger.addSource(identified: b)
        try merger.updateUniversePriorityForSource(identified: a, priority: 200)
        try merger.updateUniversePriorityForSource(identified: b, priority: 100)
        try merger.updateLevelsForSource(identified: a, newLevels: fullLevels(10), newLevelsCount: 512)
        try merger.updateLevelsForSource(identified: b, newLevels: fullLevels(255), newLevelsCount: 512)

        // a has the higher priority, so it wins even though its level is lower.
        #expect(merger.winners[0] == a)
        #expect(merger.levels[0] == 10)
    }

    // MARK: Per-address priority

    @Test("A per-address priority of 0 makes a slot unsourced")
    func papZeroUnsourced() throws {
        let merger = sACNMerger(id: 1)
        let source = UUID()
        try merger.addSource(identified: source)
        try merger.updateLevelsForSource(identified: source, newLevels: fullLevels(255, rest: 255), newLevelsCount: 512)
        // slot 0 priority 0 (unsourced), all others priority 100
        try merger.updatePAPForSource(identified: source, newPriorities: [0] + Array(repeating: 100, count: 511), newPrioritiesCount: 512)

        #expect(merger.levels[0] == 0)
        #expect(merger.winners[0] == nil)
        #expect(merger.levels[1] == 255)
        #expect(merger.winners[1] == source)
    }

    @Test("removePAP reverts a source to its universe priority")
    func removePAPReverts() throws {
        let merger = sACNMerger(id: 1)
        let source = UUID()
        try merger.addSource(identified: source)
        try merger.updateUniversePriorityForSource(identified: source, priority: 100)
        try merger.updateLevelsForSource(identified: source, newLevels: fullLevels(255, rest: 255), newLevelsCount: 512)
        try merger.updatePAPForSource(identified: source, newPriorities: [0] + Array(repeating: 100, count: 511), newPrioritiesCount: 512)
        #expect(merger.winners[0] == nil)  // slot 0 unsourced via PAP

        try merger.removePAP(forSourceIdentified: source)
        // reverted to universe priority 100 -> slot 0 sourced again
        #expect(merger.winners[0] == source)
        #expect(merger.levels[0] == 255)
    }

    // MARK: Remove source

    @Test("Removing the winning source recalculates the output")
    func removeSourceRecalculates() throws {
        let merger = sACNMerger(id: 1)
        let a = UUID()
        let b = UUID()
        try merger.addSource(identified: a)
        try merger.addSource(identified: b)
        try merger.updateUniversePriorityForSource(identified: a, priority: 200)
        try merger.updateUniversePriorityForSource(identified: b, priority: 100)
        try merger.updateLevelsForSource(identified: a, newLevels: fullLevels(10), newLevelsCount: 512)
        try merger.updateLevelsForSource(identified: b, newLevels: fullLevels(50), newLevelsCount: 512)
        #expect(merger.winners[0] == a)

        try merger.removeSource(identified: a)
        // b is now the only source
        #expect(merger.winners[0] == b)
        #expect(merger.levels[0] == 50)
    }

    // MARK: Errors

    @Test("Adding the same source twice throws")
    func duplicateSourceThrows() throws {
        let merger = sACNMerger(id: 1)
        let source = UUID()
        try merger.addSource(identified: source)
        #expect(throws: sACNMergerError.self) {
            try merger.addSource(identified: source)
        }
    }

    @Test("Updating an unknown source throws")
    func unknownSourceThrows() {
        let merger = sACNMerger(id: 1)
        #expect(throws: sACNMergerError.self) {
            try merger.updateLevelsForSource(identified: UUID(), newLevels: fullLevels(1), newLevelsCount: 512)
        }
    }

    @Test("An invalid level count throws")
    func invalidLevelCountThrows() throws {
        let merger = sACNMerger(id: 1)
        let source = UUID()
        try merger.addSource(identified: source)
        #expect(throws: sACNMergerError.self) {
            try merger.updateLevelsForSource(identified: source, newLevels: [], newLevelsCount: 0)
        }
    }

    @Test("The source limit is enforced")
    func sourceLimitEnforced() throws {
        let merger = sACNMerger(id: 1, config: sACNMergerConfig(transmitPerAddressPriorities: nil, universePriority: nil, sourceLimit: 1))
        try merger.addSource(identified: UUID())
        #expect(throws: sACNMergerError.self) {
            try merger.addSource(identified: UUID())
        }
    }

}
