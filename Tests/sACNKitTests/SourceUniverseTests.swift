import Foundation
import Testing

@testable import sACNKit

/// Characterizes the transmit counter/flag state machine on `SourceUniverse`.
/// These are pure, synchronous primitives (no sockets or timers).
@Suite("SourceUniverse state machine")
struct SourceUniverseTests {

    private func makeUniverse(levels: [UInt8] = Array(repeating: 0, count: 512)) -> SourceUniverse {
        let universe = sACNSourceUniverse(number: 1, levels: levels)
        return SourceUniverse(with: universe, sourcePriority: 100, nameData: Source.buildNameData(from: "test"))
    }

    @Test("Initial state after construction")
    func initialState() {
        let universe = makeUniverse()
        #expect(universe.sequence == 0)
        #expect(universe.transmitCounter == 0)
        #expect(universe.dirtyCounter == 3)
        #expect(universe.dirtyPriority == true)
        #expect(universe.shouldTerminate == false)
        #expect(universe.removeAfterTerminate == false)
        #expect(universe.pendingSocketRemoval == false)
    }

    @Test("Sequence number wraps 255 -> 0")
    func sequenceWraps() {
        let universe = makeUniverse()
        for _ in 0..<255 { universe.incrementSequence() }
        #expect(universe.sequence == 255)
        universe.incrementSequence()
        #expect(universe.sequence == 0)
    }

    @Test("Transmit counter cycles 0...43 then wraps to 0")
    func counterCycles() {
        let universe = makeUniverse()
        for _ in 0..<43 { universe.incrementCounter() }
        #expect(universe.transmitCounter == 43)
        universe.incrementCounter()
        #expect(universe.transmitCounter == 0)
    }

    @Test("Dirty counter decrements to and floors at 0")
    func dirtyFloors() {
        let universe = makeUniverse()
        for _ in 0..<3 { universe.decrementDirty() }
        #expect(universe.dirtyCounter == 0)
        universe.decrementDirty()
        #expect(universe.dirtyCounter == 0)
    }

    @Test("A level change re-arms the dirty burst of 3 when the source is active")
    func levelChangeRearmsDirty() throws {
        let universe = makeUniverse()
        for _ in 0..<3 { universe.decrementDirty() }
        #expect(universe.dirtyCounter == 0)
        try universe.update(levels: [255] + Array(repeating: 0, count: 511), sourceActive: true)
        #expect(universe.dirtyCounter == 3)
    }

    @Test("Terminate sets termination flags and re-arms the dirty counter")
    func terminateSetsFlags() {
        let universe = makeUniverse()
        universe.decrementDirty()
        universe.terminate(remove: true)
        #expect(universe.shouldTerminate == true)
        #expect(universe.removeAfterTerminate == true)
        #expect(universe.dirtyCounter == 3)
    }

    @Test("Priority sent clears the dirty priority flag")
    func prioritySentClearsFlag() {
        let universe = makeUniverse()
        #expect(universe.dirtyPriority == true)
        universe.prioritySent()
        #expect(universe.dirtyPriority == false)
    }

    @Test("Reset restores the initial transmit state")
    func resetRestoresState() {
        let universe = makeUniverse()
        universe.terminate(remove: true)
        for _ in 0..<10 { universe.incrementCounter() }
        universe.reset()
        #expect(universe.transmitCounter == 0)
        #expect(universe.dirtyCounter == 3)
        #expect(universe.dirtyPriority == true)
        #expect(universe.shouldTerminate == false)
        #expect(universe.removeAfterTerminate == false)
        #expect(universe.pendingSocketRemoval == false)
    }

}
