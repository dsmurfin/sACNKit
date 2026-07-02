import XCTest

@testable import sACNKit

/// Characterizes the transmit-message builder (`sACNSource.buildDataMessages()`).
/// Driving the builder directly avoids the 44 fps GCD timer and any socket I/O.
final class SourceTransmitTests: XCTestCase {

    /// Absolute byte offsets within a full data packet: a 38-byte root layer followed by the
    /// data framing layer (sequence number at framing offset 73, options at framing offset 74).
    private static let sequenceOffset = 38 + 73
    private static let optionsOffset = 38 + 74
    private static let startCodeOffset =
        RootLayer.Offset.data.rawValue + DataFramingLayer.Offset.data.rawValue + DMPLayer.Offset.propertyValues.rawValue
    private static let terminatedBit: UInt8 = 1 << 6

    /// A source with a single active universe (no per-slot priorities, so no priority packets).
    private func activeSource(levels: [UInt8] = Array(repeating: 0, count: 512)) throws -> sACNSource {
        let source = sACNSource(delegateQueue: DispatchQueue(label: "test.source"))
        try source.addUniverse(sACNSourceUniverse(number: 1, levels: levels))
        source.shouldOutput(true)
        return source
    }

    /// A new universe emits a dirty burst of 3 level packets then suppresses.
    func testDirtyBurstOfThree() throws {
        let source = try activeSource()
        XCTAssertEqual(source.buildDataMessages().messages.count, 1)  // transmitCounter 0
        XCTAssertEqual(source.buildDataMessages().messages.count, 1)  // dirty 2
        XCTAssertEqual(source.buildDataMessages().messages.count, 1)  // dirty 1
        XCTAssertEqual(source.buildDataMessages().messages.count, 0)  // dirty 0, suppressed
    }

    /// Every active universe is processed on each build.
    func testAllActiveUniversesProcessed() throws {
        let source = sACNSource(delegateQueue: DispatchQueue(label: "test.source"))
        try source.addUniverse(sACNSourceUniverse(number: 1, levels: Array(repeating: 0, count: 512)))
        try source.addUniverse(sACNSourceUniverse(number: 7, levels: Array(repeating: 0, count: 512)))
        source.shouldOutput(true)

        let numbers = Set(source.buildDataMessages().messages.map { $0.universeNumber })
        XCTAssertEqual(numbers, Set<UInt16>([1, 7]))
    }

    /// Regression for the transmit indexing bug: `buildDataMessages()` indexed the full `universes`
    /// array with the filtered `activeUniverses` index, so once a terminated universe preceded an
    /// active one it processed (and emitted keep-alives for) the wrong universe and starved the rest.
    func testPresentButInactiveUniverseIsSkipped() throws {
        let source = sACNSource(delegateQueue: DispatchQueue(label: "test.source"))
        try source.addUniverse(sACNSourceUniverse(number: 1, levels: Array(repeating: 0, count: 512)))
        try source.addUniverse(sACNSourceUniverse(number: 9, levels: Array(repeating: 0, count: 512)))
        source.shouldOutput(true)
        for _ in 0..<3 { _ = source.buildDataMessages() }  // drain the initial bursts

        // terminate universe 1 in place (as shouldOutput(false) does for every universe); the
        // builder performs no removal, so after its 3 termination packets it stays present but inactive
        source.universes.first { $0.number == 1 }?.terminate(remove: false)
        for _ in 0..<3 {
            let numbers = source.buildDataMessages().messages.map { $0.universeNumber }
            XCTAssertEqual(numbers, [1])  // the termination burst, with universe 9 suppressed
        }

        // a full keep-alive cycle must emit only universe 9; the pre-fix builder emitted universe 1
        var emitted = [UInt16]()
        for _ in 0..<44 {
            emitted.append(contentsOf: source.buildDataMessages().messages.map { $0.universeNumber })
        }
        XCTAssertEqual(Set(emitted), Set<UInt16>([9]))
    }

    /// Suppressed levels are force-sent at transmit counters 0, 11, 22 and 33.
    func testKeepAliveCadence() throws {
        let source = try activeSource()
        for _ in 0..<3 { _ = source.buildDataMessages() }  // drain the burst (counters 0, 1, 2)

        var emittingFrames = [Int]()
        for frame in 0..<44 {
            if !source.buildDataMessages().messages.isEmpty {
                emittingFrames.append(frame)
            }
        }
        // the cycle covers counters 3...43 then 0...2; keep-alives fire at counters 11, 22, 33 and 0
        XCTAssertEqual(emittingFrames, [8, 19, 30, 41])
    }

    /// Suppressed per-address priority is re-sent only at transmit counter 0.
    func testPAPKeepAliveCadence() throws {
        let source = sACNSource(delegateQueue: DispatchQueue(label: "test.source"))
        try source.addUniverse(
            sACNSourceUniverse(
                number: 1, levels: Array(repeating: 0, count: 512), priorities: Array(repeating: 100, count: 512)))
        source.shouldOutput(true)
        for _ in 0..<3 { _ = source.buildDataMessages() }  // drain the burst (counters 0, 1, 2)

        var papFrames = [Int]()
        for frame in 0..<44 {
            for message in source.buildDataMessages().messages
            where Array(message.data)[Self.startCodeOffset] == DMX.STARTCode.perAddressPriority.rawValue {
                papFrames.append(frame)
            }
        }
        // one PAP keep-alive per cycle, at counter 0 (~once per second at 44 fps)
        XCTAssertEqual(papFrames, [41])
    }

    /// Emitted packets carry incrementing sequence numbers.
    func testSequenceIncrements() throws {
        let source = try activeSource()
        let sequences = (0..<3).map { _ -> UInt8 in
            Array(source.buildDataMessages().messages[0].data)[Self.sequenceOffset]
        }
        XCTAssertEqual(sequences, [0, 1, 2])
    }

    /// Termination emits exactly 3 packets carrying the terminated option.
    func testTerminationEmitsThreePackets() throws {
        let source = try activeSource()
        for _ in 0..<3 { _ = source.buildDataMessages() }  // drain the initial burst
        XCTAssertEqual(source.buildDataMessages().messages.count, 0)  // steady state

        source.shouldOutput(false)  // terminate all universes

        var terminationPackets = 0
        for _ in 0..<5 {
            for message in source.buildDataMessages().messages
            where Array(message.data)[Self.optionsOffset] & Self.terminatedBit != 0 {
                terminationPackets += 1
            }
        }
        XCTAssertEqual(terminationPackets, 3)
    }

}
