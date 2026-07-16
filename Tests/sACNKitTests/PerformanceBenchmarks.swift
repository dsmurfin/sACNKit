import Foundation
import Testing

@testable import sACNKit

/// Performance-regression guard for the transmit hot path (workstream J).
///
/// The purpose is to catch *performance* regressions - specifically a reintroduced per-frame packet
/// allocation - independently of the correctness net (`SourceTransmitTests`). The primary signal is
/// deterministic and cross-platform: the emitted packet must be the universe's pre-composed buffer
/// (handed over, mutated in place), not a freshly allocated one. Wall-clock throughput is an optional,
/// non-blocking trend gated behind `SACNKIT_BENCH=1`.
@Suite("Transmit performance")
struct PerformanceBenchmarks {

    /// Whether the emitted packet shares backing storage with the universe's stored packet.
    ///
    /// Same base address == the pre-composed buffer was handed over (no per-frame allocation); a
    /// distinct buffer would mean the packet was rebuilt (e.g. by re-concatenating the layers).
    private func sharesStorage(_ message: Data, with stored: Data) -> Bool {
        message.withUnsafeBytes { m in
            stored.withUnsafeBytes { s in m.baseAddress == s.baseAddress }
        }
    }

    @Test("The emitted level packet is the pre-composed buffer, not a per-frame allocation")
    func levelPacketIsNotReallocated() throws {
        let source = sACNSource(delegateQueue: DispatchQueue(label: "test.source"))
        try source.addUniverse(sACNSourceUniverse(number: 1, levels: Array(repeating: 0, count: 512)))
        source.shouldOutput(true)
        let universe = try #require(source.universes.first)

        let message = try #require(source.buildDataMessages().messages.first).data
        #expect(sharesStorage(message, with: universe.levelsPacket))
    }

    @Test("The emitted priority packet is the pre-composed buffer, not a per-frame allocation")
    func priorityPacketIsNotReallocated() throws {
        let source = sACNSource(delegateQueue: DispatchQueue(label: "test.source"))
        try source.addUniverse(
            sACNSourceUniverse(
                number: 1, levels: Array(repeating: 0, count: 512), priorities: Array(repeating: 100, count: 512)))
        source.shouldOutput(true)
        let universe = try #require(source.universes.first)

        let pap = try #require(
            source.buildDataMessages().messages.first {
                Array($0.data)[38 + DataFramingLayer.Offset.data.rawValue + DMPLayer.Offset.propertyValues.rawValue]
                    == DMX.STARTCode.perAddressPriority.rawValue
            }
        ).data
        #expect(sharesStorage(pap, with: universe.prioritiesPacket))
    }

    /// Non-blocking wall-clock trend. Gated behind `SACNKIT_BENCH=1` because shared-runner timing is
    /// noisy; it asserts nothing, it just records numbers for comparison across commits.
    @Test(
        "Build throughput trend",
        .enabled(if: ProcessInfo.processInfo.environment["SACNKIT_BENCH"] == "1"))
    func buildThroughput() throws {
        // `buildDataMessages` is family-independent (the dual-stack send loop lives in
        // `sendDataMessages`), so the meaningful axis is universe count.
        for universeCount in [1, 64, 256] {
            let source = sACNSource(delegateQueue: DispatchQueue(label: "test.source"))
            for number in 1...universeCount {
                try source.addUniverse(sACNSourceUniverse(number: UInt16(number), levels: Array(repeating: 0, count: 512)))
            }
            source.shouldOutput(true)

            let iterations = 1000
            let elapsed = ContinuousClock().measure {
                for _ in 0..<iterations { _ = source.buildDataMessages() }
            }
            let perFrame = elapsed / iterations
            print("buildDataMessages @ \(universeCount) universes: \(perFrame) per frame over \(iterations) frames")
        }
    }

}
