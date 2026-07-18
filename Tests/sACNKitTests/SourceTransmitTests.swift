import Foundation
import Testing

@testable import sACNKit

/// Characterizes the transmit-message builder (`sACNSource.buildDataMessages()`).
/// Driving the builder directly avoids the 44 fps timer and any socket I/O.
@Suite("sACNSource transmit builder")
struct SourceTransmitTests {

    /// Absolute byte offsets within a full data packet: a 38-byte root layer followed by the
    /// data framing layer (sequence number at framing offset 73, options at framing offset 74).
    private static let sequenceOffset = 38 + 73
    private static let optionsOffset = 38 + 74
    private static let priorityOffset = 38 + 70
    private static let startCodeOffset =
        RootLayer.Offset.data.rawValue + DataFramingLayer.Offset.data.rawValue + DMPLayer.Offset.propertyValues.rawValue
    private static let terminatedBit: UInt8 = 1 << 6

    /// A source with a single active universe (no per-slot priorities, so no priority packets).
    private func activeSource(levels: [UInt8] = Array(repeating: 0, count: 512)) async throws -> sACNSource {
        let source = sACNSource()
        try await source.addUniverse(sACNSourceUniverse(number: 1, levels: levels))
        await source.shouldOutput(true)
        return source
    }

    @Test("A new universe emits a dirty burst of 3 level packets then suppresses")
    func dirtyBurstOfThree() async throws {
        let source = try await activeSource()
        #expect(await source.buildDataMessages().messages.count == 1)  // transmitCounter 0
        #expect(await source.buildDataMessages().messages.count == 1)  // dirty 2
        #expect(await source.buildDataMessages().messages.count == 1)  // dirty 1
        #expect(await source.buildDataMessages().messages.count == 0)  // dirty 0, suppressed
    }

    @Test("Every active universe is processed on each build")
    func allActiveUniversesProcessed() async throws {
        let source = sACNSource()
        try await source.addUniverse(sACNSourceUniverse(number: 1, levels: Array(repeating: 0, count: 512)))
        try await source.addUniverse(sACNSourceUniverse(number: 7, levels: Array(repeating: 0, count: 512)))
        await source.shouldOutput(true)

        let numbers = await Set(source.buildDataMessages().messages.map { $0.universeNumber })
        #expect(numbers == [1, 7])
    }

    /// Regression for the transmit indexing bug: `buildDataMessages()` indexed the full `universes`
    /// array with the filtered `activeUniverses` index, so once a terminated universe preceded an
    /// active one it processed (and emitted keep-alives for) the wrong universe and starved the rest.
    @Test("A present-but-inactive universe is skipped and active universes still transmit")
    func presentButInactiveUniverseIsSkipped() async throws {
        let source = sACNSource()
        try await source.addUniverse(sACNSourceUniverse(number: 1, levels: Array(repeating: 0, count: 512)))
        try await source.addUniverse(sACNSourceUniverse(number: 9, levels: Array(repeating: 0, count: 512)))
        await source.shouldOutput(true)
        for _ in 0..<3 { _ = await source.buildDataMessages() }  // drain the initial bursts

        // terminate universe 1 in place (as shouldOutput(false) does for every universe); the
        // builder performs no removal, so after its 3 termination packets it stays present but inactive
        await source.terminate(universe: 1, remove: false)
        for _ in 0..<3 {
            let numbers = await source.buildDataMessages().messages.map { $0.universeNumber }
            #expect(numbers == [1])  // the termination burst, with universe 9 suppressed
        }

        // a full keep-alive cycle must emit only universe 9; the pre-fix builder emitted universe 1
        var emitted = [UInt16]()
        for _ in 0..<44 {
            emitted.append(contentsOf: await source.buildDataMessages().messages.map { $0.universeNumber })
        }
        #expect(Set(emitted) == [9])
    }

    @Test("Suppressed levels are force-sent at transmit counters 0, 11, 22 and 33")
    func keepAliveCadence() async throws {
        let source = try await activeSource()
        for _ in 0..<3 { _ = await source.buildDataMessages() }  // drain the burst (counters 0, 1, 2)

        var emittingFrames = [Int]()
        for frame in 0..<44 {
            if await !source.buildDataMessages().messages.isEmpty {
                emittingFrames.append(frame)
            }
        }
        // the cycle covers counters 3...43 then 0...2; keep-alives fire at counters 11, 22, 33 and 0
        #expect(emittingFrames == [8, 19, 30, 41])
    }

    @Test("Suppressed per-address priority is re-sent only at transmit counter 0")
    func papKeepAliveCadence() async throws {
        let source = sACNSource()
        try await source.addUniverse(
            sACNSourceUniverse(
                number: 1, levels: Array(repeating: 0, count: 512), priorities: Array(repeating: 100, count: 512)))
        await source.shouldOutput(true)
        for _ in 0..<3 { _ = await source.buildDataMessages() }  // drain the burst (counters 0, 1, 2)

        var papFrames = [Int]()
        for frame in 0..<44 {
            for message in await source.buildDataMessages().messages
            where Array(message.data)[Self.startCodeOffset] == DMX.STARTCode.perAddressPriority.rawValue {
                papFrames.append(frame)
            }
        }
        // one PAP keep-alive per cycle, at counter 0 (~once per second at 44 fps)
        #expect(papFrames == [41])
    }

    @Test("Emitted packets carry incrementing sequence numbers")
    func sequenceIncrements() async throws {
        let source = try await activeSource()
        var sequences: [UInt8] = []
        for _ in 0..<3 {
            sequences.append(Array(await source.buildDataMessages().messages[0].data)[Self.sequenceOffset])
        }
        #expect(sequences == [0, 1, 2])
    }

    // MARK: Byte-identical output

    /// The pre-composed transmit packets must be byte-for-byte identical to a packet built the long way
    /// (root + framing + DMP) by `sACNTestDataPacket`. This locks the wire output against the
    /// pre-composed/in-place-mutation refactor - the other tests only check individual bytes.

    @Test("A level packet is byte-identical to a freshly composed packet")
    func levelPacketByteIdentical() async throws {
        let cid = UUID()
        let levels = (0..<512).map { UInt8($0 % 256) }
        let source = sACNSource(name: "Golden", cid: cid)
        try await source.addUniverse(sACNSourceUniverse(number: 3, levels: levels))
        await source.shouldOutput(true)

        let packet = try #require(await source.buildDataMessages().messages.first).data
        let expected = sACNTestDataPacket(cid: cid, name: "Golden", universe: 3, sequence: 0, values: levels)
        #expect(packet == expected)
    }

    @Test("A per-address-priority packet is byte-identical to a freshly composed packet")
    func priorityPacketByteIdentical() async throws {
        let cid = UUID()
        let priorities = (0..<512).map { _ in UInt8(200) }
        let source = sACNSource(name: "Golden", cid: cid)
        try await source.addUniverse(
            sACNSourceUniverse(number: 1, levels: Array(repeating: 0, count: 512), priorities: priorities))
        await source.shouldOutput(true)

        let pap = try #require(
            await source.buildDataMessages().messages.first {
                Array($0.data)[Self.startCodeOffset] == DMX.STARTCode.perAddressPriority.rawValue
            }
        ).data
        // the PAP packet carries whatever sequence it was stamped with; feed it back so the comparison
        // validates every other byte
        let sequence = Array(pap)[Self.sequenceOffset]
        let expected = sACNTestDataPacket(
            cid: cid, name: "Golden", universe: 1, sequence: sequence, startCode: .perAddressPriority, values: priorities)
        #expect(pap == expected)
    }

    @Test("A termination packet is byte-identical to a freshly composed terminated packet")
    func terminationPacketByteIdentical() async throws {
        let cid = UUID()
        let source = sACNSource(name: "Golden", cid: cid)
        try await source.addUniverse(sACNSourceUniverse(number: 5, levels: Array(repeating: 0, count: 512)))
        await source.shouldOutput(true)
        for _ in 0..<3 { _ = await source.buildDataMessages() }  // drain the initial burst

        await source.shouldOutput(false)  // terminate
        let packet = try #require(await source.buildDataMessages().messages.first).data
        let sequence = Array(packet)[Self.sequenceOffset]
        let expected = sACNTestDataPacket(cid: cid, name: "Golden", universe: 5, sequence: sequence, options: .terminated)
        #expect(packet == expected)
        #expect(Array(packet)[Self.optionsOffset] & Self.terminatedBit != 0)
    }

    @Test("Clearing a per-packet priority reverts the wire priority to the source priority on both packets")
    func clearingPriorityRevertsToSourcePriority() async throws {
        let hundreds = Array(repeating: UInt8(100), count: 512)
        let source = sACNSource(name: "Golden", cid: UUID(), priority: 100)
        try await source.addUniverse(
            sACNSourceUniverse(number: 1, priority: 150, levels: Array(repeating: 0, count: 512), priorities: hundreds))

        // clear the per-packet priority override; the wire priority must revert to the source priority
        try await source.updateLevels(
            with: sACNSourceUniverse(number: 1, priority: nil, levels: Array(repeating: 0, count: 512), priorities: hundreds))
        await source.shouldOutput(true)

        let messages = await source.buildDataMessages().messages
        let levels = try #require(messages.first { Array($0.data)[Self.startCodeOffset] == DMX.STARTCode.null.rawValue }).data
        let pap = try #require(
            messages.first { Array($0.data)[Self.startCodeOffset] == DMX.STARTCode.perAddressPriority.rawValue }
        ).data
        #expect(Array(levels)[Self.priorityOffset] == 100)
        #expect(Array(pap)[Self.priorityOffset] == 100)
    }

    @Test("Termination emits exactly 3 packets carrying the terminated option")
    func terminationEmitsThreePackets() async throws {
        let source = try await activeSource()
        for _ in 0..<3 { _ = await source.buildDataMessages() }  // drain the initial burst
        #expect(await source.buildDataMessages().messages.count == 0)  // steady state

        await source.shouldOutput(false)  // terminate all universes

        var terminationPackets = 0
        for _ in 0..<5 {
            for message in await source.buildDataMessages().messages
            where Array(message.data)[Self.optionsOffset] & Self.terminatedBit != 0 {
                terminationPackets += 1
            }
        }
        #expect(terminationPackets == 3)
    }

}
