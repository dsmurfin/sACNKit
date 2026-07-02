import Foundation
import Testing

@testable import sACNKit

/// Characterizes the transmit-message builder (`sACNSource.buildDataMessages()`).
/// Driving the builder directly avoids the 44 fps GCD timer and any socket I/O.
@Suite("sACNSource transmit builder")
struct SourceTransmitTests {

    /// Absolute byte offsets within a full data packet: a 38-byte root layer followed by the
    /// data framing layer (sequence number at framing offset 73, options at framing offset 74).
    private static let sequenceOffset = 38 + 73
    private static let optionsOffset = 38 + 74
    private static let terminatedBit: UInt8 = 1 << 6

    /// A source with a single active universe (no per-slot priorities, so no priority packets).
    private func activeSource(levels: [UInt8] = Array(repeating: 0, count: 512)) throws -> sACNSource {
        let source = sACNSource(delegateQueue: DispatchQueue(label: "test.source"))
        try source.addUniverse(sACNSourceUniverse(number: 1, levels: levels))
        source.shouldOutput(true)
        return source
    }

    @Test("A new universe emits a dirty burst of 3 level packets then suppresses")
    func dirtyBurstOfThree() throws {
        let source = try activeSource()
        #expect(source.buildDataMessages().messages.count == 1)  // transmitCounter 0
        #expect(source.buildDataMessages().messages.count == 1)  // dirty 2
        #expect(source.buildDataMessages().messages.count == 1)  // dirty 1
        #expect(source.buildDataMessages().messages.count == 0)  // dirty 0, suppressed
    }

    @Test("Emitted packets carry incrementing sequence numbers")
    func sequenceIncrements() throws {
        let source = try activeSource()
        let sequences = (0..<3).map { _ -> UInt8 in
            Array(source.buildDataMessages().messages[0].data)[Self.sequenceOffset]
        }
        #expect(sequences == [0, 1, 2])
    }

    @Test("Termination emits exactly 3 packets carrying the terminated option")
    func terminationEmitsThreePackets() throws {
        let source = try activeSource()
        for _ in 0..<3 { _ = source.buildDataMessages() }  // drain the initial burst
        #expect(source.buildDataMessages().messages.count == 0)  // steady state

        source.shouldOutput(false)  // terminate all universes

        var terminationPackets = 0
        for _ in 0..<5 {
            for message in source.buildDataMessages().messages
            where Array(message.data)[Self.optionsOffset] & Self.terminatedBit != 0 {
                terminationPackets += 1
            }
        }
        #expect(terminationPackets == 3)
    }

}
