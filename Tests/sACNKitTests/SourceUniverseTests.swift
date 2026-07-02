import XCTest

@testable import sACNKit

/// Characterizes the transmit counter/flag state machine on `SourceUniverse`.
/// These are pure, synchronous primitives (no sockets or timers).
final class SourceUniverseTests: XCTestCase {

    private func makeUniverse(levels: [UInt8] = Array(repeating: 0, count: 512)) -> SourceUniverse {
        let universe = sACNSourceUniverse(number: 1, levels: levels)
        return SourceUniverse(with: universe, sourcePriority: 100, nameData: Source.buildNameData(from: "test"))
    }

    /// Initial state after construction.
    func testInitialState() {
        let universe = makeUniverse()
        XCTAssertEqual(universe.sequence, 0)
        XCTAssertEqual(universe.transmitCounter, 0)
        XCTAssertEqual(universe.dirtyCounter, 3)
        XCTAssertTrue(universe.dirtyPriority)
        XCTAssertFalse(universe.shouldTerminate)
        XCTAssertFalse(universe.removeAfterTerminate)
        XCTAssertFalse(universe.pendingSocketRemoval)
    }

    /// Sequence number wraps 255 -> 0.
    func testSequenceWraps() {
        let universe = makeUniverse()
        for _ in 0..<255 { universe.incrementSequence() }
        XCTAssertEqual(universe.sequence, 255)
        universe.incrementSequence()
        XCTAssertEqual(universe.sequence, 0)
    }

    /// Transmit counter cycles 0...43 then wraps to 0.
    func testCounterCycles() {
        let universe = makeUniverse()
        for _ in 0..<43 { universe.incrementCounter() }
        XCTAssertEqual(universe.transmitCounter, 43)
        universe.incrementCounter()
        XCTAssertEqual(universe.transmitCounter, 0)
    }

    /// Dirty counter decrements to and floors at 0.
    func testDirtyFloors() {
        let universe = makeUniverse()
        for _ in 0..<3 { universe.decrementDirty() }
        XCTAssertEqual(universe.dirtyCounter, 0)
        universe.decrementDirty()
        XCTAssertEqual(universe.dirtyCounter, 0)
    }

    /// A level change re-arms the dirty burst of 3 when the source is active.
    func testLevelChangeRearmsDirty() throws {
        let universe = makeUniverse()
        for _ in 0..<3 { universe.decrementDirty() }
        XCTAssertEqual(universe.dirtyCounter, 0)
        try universe.update(levels: [255] + Array(repeating: 0, count: 511), sourceActive: true)
        XCTAssertEqual(universe.dirtyCounter, 3)
    }

    /// Terminate sets termination flags and re-arms the dirty counter.
    func testTerminateSetsFlags() {
        let universe = makeUniverse()
        universe.decrementDirty()
        universe.terminate(remove: true)
        XCTAssertTrue(universe.shouldTerminate)
        XCTAssertTrue(universe.removeAfterTerminate)
        XCTAssertEqual(universe.dirtyCounter, 3)
    }

    /// Priority sent clears the dirty priority flag.
    func testPrioritySentClearsFlag() {
        let universe = makeUniverse()
        XCTAssertTrue(universe.dirtyPriority)
        universe.prioritySent()
        XCTAssertFalse(universe.dirtyPriority)
    }

    /// Reset restores the initial transmit state.
    func testResetRestoresState() {
        let universe = makeUniverse()
        universe.terminate(remove: true)
        for _ in 0..<10 { universe.incrementCounter() }
        universe.reset()
        XCTAssertEqual(universe.transmitCounter, 0)
        XCTAssertEqual(universe.dirtyCounter, 3)
        XCTAssertTrue(universe.dirtyPriority)
        XCTAssertFalse(universe.shouldTerminate)
        XCTAssertFalse(universe.removeAfterTerminate)
        XCTAssertFalse(universe.pendingSocketRemoval)
    }

}
