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

    @Test("The emitted level packet is the pre-composed buffer, not a per-frame allocation")
    func levelPacketIsNotReallocated() async throws {
        let source = sACNSource()
        try await source.addUniverse(sACNSourceUniverse(number: 1, levels: Array(repeating: 0, count: 512)))
        await source.shouldOutput(true)
        #expect(await source.emittedPacketSharesStorage(perAddressPriority: false))
    }

    @Test("The emitted priority packet is the pre-composed buffer, not a per-frame allocation")
    func priorityPacketIsNotReallocated() async throws {
        let source = sACNSource()
        try await source.addUniverse(
            sACNSourceUniverse(
                number: 1, levels: Array(repeating: 0, count: 512), priorities: Array(repeating: 100, count: 512)))
        await source.shouldOutput(true)
        #expect(await source.emittedPacketSharesStorage(perAddressPriority: true))
    }

    /// Non-blocking wall-clock trend. Gated behind `SACNKIT_BENCH=1` because shared-runner timing is
    /// noisy; it asserts nothing, it just records numbers for comparison across commits.
    @Test(
        "Build throughput trend",
        .enabled(if: ProcessInfo.processInfo.environment["SACNKIT_BENCH"] == "1"))
    func buildThroughput() async throws {
        // `buildDataMessages` is family-independent (the dual-stack send loop lives in
        // `sendDataMessages`), so the meaningful axis is universe count.
        for universeCount in [1, 64, 256] {
            let source = sACNSource()
            for number in 1...universeCount {
                try await source.addUniverse(sACNSourceUniverse(number: UInt16(number), levels: Array(repeating: 0, count: 512)))
            }
            await source.shouldOutput(true)

            let iterations = 1000
            let clock = ContinuousClock()
            let start = clock.now
            for _ in 0..<iterations { _ = await source.buildDataMessages() }
            let perFrame = (clock.now - start) / iterations
            print("buildDataMessages @ \(universeCount) universes: \(perFrame) per frame over \(iterations) frames")
        }
    }

}
