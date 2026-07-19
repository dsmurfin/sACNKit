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

    // MARK: Phase 5 correctness (ETC parity)

    @Test("Merge output is independent of the order levels and priorities are entered")
    func outputIndependentOfInputOrder() throws {
        let a = UUID()
        let b = UUID()
        let aLevels = fullLevels(100, rest: 100)
        let bLevels = fullLevels(200, rest: 50)
        let pap = Array(repeating: UInt8(150), count: 512)  // equal PAP for both -> HTP by level

        func build(_ ops: [(sACNMerger) throws -> Void]) throws -> (levels: [UInt8], winners: [UUID?]) {
            let merger = sACNMerger(id: 1)
            try merger.addSource(identified: a)
            try merger.addSource(identified: b)
            for op in ops { try op(merger) }
            return (merger.levels, merger.winners)
        }

        let order1 = try build([
            { try $0.updateLevelsForSource(identified: a, newLevels: aLevels, newLevelsCount: 512) },
            { try $0.updatePAPForSource(identified: a, newPriorities: pap, newPrioritiesCount: 512) },
            { try $0.updateLevelsForSource(identified: b, newLevels: bLevels, newLevelsCount: 512) },
            { try $0.updatePAPForSource(identified: b, newPriorities: pap, newPrioritiesCount: 512) },
        ])
        let order2 = try build([
            { try $0.updatePAPForSource(identified: b, newPriorities: pap, newPrioritiesCount: 512) },
            { try $0.updateLevelsForSource(identified: b, newLevels: bLevels, newLevelsCount: 512) },
            { try $0.updatePAPForSource(identified: a, newPriorities: pap, newPrioritiesCount: 512) },
            { try $0.updateLevelsForSource(identified: a, newLevels: aLevels, newLevelsCount: 512) },
        ])

        #expect(order1.levels == order2.levels, "merged levels must not depend on input order")
        #expect(order1.winners == order2.winners, "merged winners must not depend on input order")
        // sanity: HTP picks the higher level per slot (b at slot 0, a from slot 1)
        #expect(order1.winners[0] == b)
        #expect(order1.winners[1] == a)
    }

    @Test("Re-adding a shorter per-address priority after removePAP clears the trailing slots (SACN-403)")
    func removeThenAddShorterPAPClearsTrailingSlots() throws {
        let merger = sACNMerger(id: 1)
        let source = UUID()
        try merger.addSource(identified: source)
        try merger.updateLevelsForSource(identified: source, newLevels: fullLevels(255, rest: 255), newLevelsCount: 512)
        // a 100-slot PAP: slots 0..<100 sourced, everything beyond unsourced
        try merger.updatePAPForSource(identified: source, newPriorities: Array(repeating: 150, count: 100), newPrioritiesCount: 100)
        #expect(merger.winners[300] == nil)

        // revert to universe priority (fills every slot), then a SHORTER 50-slot PAP arrives
        try merger.removePAP(forSourceIdentified: source)
        #expect(merger.winners[300] == source, "removePAP reverts every slot to universe priority")
        try merger.updatePAPForSource(identified: source, newPriorities: Array(repeating: 150, count: 50), newPrioritiesCount: 50)

        // slots within the new PAP length are sourced...
        #expect(merger.winners[10] == source)
        #expect(merger.levels[10] == 255)
        // ...and slots beyond it must be cleared (the bug left them sourced at the reverted universe priority)
        #expect(merger.winners[300] == nil)
        #expect(merger.levels[300] == 0)
    }

    @Test("A short first per-address priority after universe priority clears the trailing slots (SACN-403 sibling)")
    func shortFirstPAPAfterUniversePriorityClearsTrailingSlots() throws {
        let merger = sACNMerger(id: 1)
        let source = UUID()
        try merger.addSource(identified: source)
        // universe priority fills every slot (all 512 sourced), then the source's FIRST PAP is short
        try merger.updateUniversePriorityForSource(identified: source, priority: 100)
        try merger.updateLevelsForSource(identified: source, newLevels: fullLevels(255, rest: 255), newLevelsCount: 512)
        #expect(merger.winners[300] == source, "universe priority sources every slot")

        try merger.updatePAPForSource(identified: source, newPriorities: Array(repeating: 150, count: 50), newPrioritiesCount: 50)

        // slots within the PAP length are sourced; slots beyond it must be cleared (not left on universe priority)
        #expect(merger.winners[10] == source)
        #expect(merger.winners[300] == nil)
        #expect(merger.levels[300] == 0)
    }

    @Test("A per-address priority resuming after removePAP re-applies even when unchanged (revert-state transition)")
    func papResumingAfterRemoveReAppliesWhenUnchanged() throws {
        let merger = sACNMerger(id: 1)
        let source = UUID()
        try merger.addSource(identified: source)
        try merger.updateUniversePriorityForSource(identified: source, priority: 100)
        try merger.updateLevelsForSource(identified: source, newLevels: fullLevels(255, rest: 255), newLevelsCount: 512)
        // a 100-slot PAP whose values equal the universe priority (the legitimate SACN-364 revert-equal state)
        let pap = Array(repeating: UInt8(100), count: 100)
        try merger.updatePAPForSource(identified: source, newPriorities: pap, newPrioritiesCount: 100)
        #expect(merger.winners[300] == nil, "beyond the 100-slot PAP")

        // revert to universe priority (fills every slot), then the SAME per-address priority resumes
        try merger.removePAP(forSourceIdentified: source)
        #expect(merger.winners[300] == source, "universe priority sources every slot")
        try merger.updatePAPForSource(identified: source, newPriorities: pap, newPrioritiesCount: 100)

        // the resumed PAP must re-apply (its arrival is a transition off universe priority), so slots beyond
        // its length become unsourced again - not left on the reverted universe priority
        #expect(merger.winners[10] == source)
        #expect(merger.winners[300] == nil)
        #expect(merger.levels[300] == 0)
    }

    @Test("perAddressPrioritiesActive is set when PAP values equal the universe priority (SACN-364)")
    func papActiveWhenEqualToUniversePriority() throws {
        let merger = sACNMerger(id: 1, config: sACNMergerConfig(transmitPerAddressPriorities: false, universePriority: nil, sourceLimit: nil))
        let source = UUID()
        try merger.addSource(identified: source)
        try merger.updateUniversePriorityForSource(identified: source, priority: 100)
        try merger.updateLevelsForSource(identified: source, newLevels: fullLevels(255, rest: 255), newLevelsCount: 512)
        // PAP values identical to the universe priority - per-address priority is still active
        try merger.updatePAPForSource(identified: source, newPriorities: Array(repeating: 100, count: 512), newPrioritiesCount: 512)

        #expect(merger.perAddressPrioritiesActive == true)
    }

    @Test("With per-address priorities, the higher priority wins per slot across sources")
    func multiSourcePerAddressPriorityWinner() throws {
        let merger = sACNMerger(id: 1)
        let a = UUID()
        let b = UUID()
        try merger.addSource(identified: a)
        try merger.addSource(identified: b)
        try merger.updateLevelsForSource(identified: a, newLevels: fullLevels(10, rest: 10), newLevelsCount: 512)
        try merger.updateLevelsForSource(identified: b, newLevels: fullLevels(20, rest: 20), newLevelsCount: 512)
        try merger.updatePAPForSource(identified: a, newPriorities: [200, 50] + Array(repeating: UInt8(100), count: 510), newPrioritiesCount: 512)
        try merger.updatePAPForSource(identified: b, newPriorities: [50, 200] + Array(repeating: UInt8(100), count: 510), newPrioritiesCount: 512)

        #expect(merger.winners[0] == a)  // a's PAP 200 > b's 50
        #expect(merger.levels[0] == 10)
        #expect(merger.winners[1] == b)  // b's PAP 200 > a's 50
        #expect(merger.levels[1] == 20)
        // slot 2: equal PAP (100) -> HTP -> b has the higher level
        #expect(merger.winners[2] == b)
        #expect(merger.levels[2] == 20)
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
