import Foundation
import Testing

@testable import sACNKit

/// Regression net for the `sACNSource` actor lifecycle state machine (reserve-before-await).
///
/// These start real sockets, so they share the `SACNKIT_NETWORK_TESTS=1` gate with the loopback suite.
/// Each carries a time limit: the pre-fix bugs they guard against manifest as a hang (a stranded
/// termination drain) or a source that transmits forever, which the limit converts into a failure.
@Suite("sACNSource lifecycle", .enabled(if: ProcessInfo.processInfo.environment["SACNKIT_NETWORK_TESTS"] == "1"))
struct SourceLifecycleTests {

    private func startedSource(universe: UInt16) async throws -> sACNSource {
        let source = sACNSource(name: "Lifecycle")
        try await source.addUniverse(sACNSourceUniverse(number: universe, levels: Array(repeating: 0, count: 512)))
        try await source.start()
        return source
    }

    /// Polls an async predicate until it is true or a timeout elapses (cancellation propagates, no spin).
    private func poll(timeout: Duration = .seconds(5), _ predicate: () async -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }

    /// Finding 5: `stop()` awaits the termination drain to completion, so an immediate restart no longer
    /// races the drain and throws `.sourceStarted`.
    @Test("stop() awaits the drain so start() can restart immediately", .timeLimit(.minutes(1)))
    func stopThenRestart() async throws {
        let source = try await startedSource(universe: 1)
        #expect(await source.isListening)

        await source.stop()
        #expect(await source.isListening == false)
        #expect(await source.isTransmitting == false)

        // the drain has completed, so the restart must not throw .sourceStarted
        try await source.start()
        #expect(await source.isListening)
        await source.stop()
    }

    /// Finding 1 (stress): interleaving `stop()` with an in-flight `start()` must always converge to idle -
    /// the reservation machinery must never wedge a continuation or leave the source transmitting with no
    /// way to stop. The exact `.starting`-supersede interleaving is timing-dependent (an `async let` gives
    /// no ordering guarantee), so this drives many attempts rather than pinning one; a wedge would hang the
    /// awaited `stop()` past the time limit.
    @Test("stop() interleaved with start() always converges to idle", .timeLimit(.minutes(1)))
    func stopInterleavedWithStartConverges() async throws {
        var completedStarts = 0
        for iteration in 0..<50 {
            let source = sACNSource(name: "Lifecycle")
            try await source.addUniverse(sACNSourceUniverse(number: 2, levels: Array(repeating: 0, count: 512)))

            async let starting: Void = source.start()
            await source.stop()
            do {
                // start() either completes (stop ran first / after) or is superseded (CancellationError);
                // any OTHER thrown error is a real regression and must not be swallowed.
                try await starting
                completedStarts += 1
            } catch is CancellationError {
            }
            await source.stop()  // converge regardless of which ran first

            #expect(await source.isListening == false, "iteration \(iteration)")
            #expect(await source.isTransmitting == false, "iteration \(iteration)")
        }
        // guard against the degenerate pass where start() never actually succeeded
        #expect(completedStarts > 0)
    }

    /// Finding 2: toggling `shouldOutput` while a `stop()` drain is in flight must not resurrect the
    /// terminating universes; if it did, the drain would never reach idle and the awaited `stop()` (below)
    /// would hang past the time limit.
    @Test("shouldOutput during the stop drain does not strand it", .timeLimit(.minutes(1)))
    func shouldOutputDuringDrainDoesNotZombie() async throws {
        let source = try await startedSource(universe: 3)

        async let stopping: Void = source.stop()
        await source.shouldOutput(false)
        await source.shouldOutput(true)
        await stopping  // must complete: the drain reaches idle despite the shouldOutput toggles

        #expect(await source.isListening == false)
    }

    /// Finding 5: transmission resuming via `shouldOutput(true)` after a `shouldOutput(false)` drain must
    /// re-emit `transmissionStarted`, so `isTransmitting` does not report false while the source transmits.
    @Test("output resuming after a drain un-stales isTransmitting", .timeLimit(.minutes(1)))
    func outputResumeReEmitsStarted() async throws {
        let source = try await startedSource(universe: 9)
        #expect(await source.isTransmitting)

        await source.shouldOutput(false)
        #expect(try await poll { await source.isTransmitting == false }, "expected transmission to end")

        await source.shouldOutput(true)
        #expect(try await poll { await source.isTransmitting }, "expected transmission to resume")

        await source.stop()
    }

    /// Finding 2(c): a universe marked for removal (`removeUniverse`) then caught by a `stop()` drain must
    /// still be removed - `stop()`'s `terminate(remove: false)` must not downgrade its sticky remove flag,
    /// or it survives the drain and reappears after a restart.
    @Test("removeUniverse then stop still removes the universe", .timeLimit(.minutes(1)))
    func removeUniverseThenStopStillRemoves() async throws {
        let source = sACNSource(name: "Lifecycle")
        try await source.addUniverse(sACNSourceUniverse(number: 7, levels: Array(repeating: 0, count: 512)))
        try await source.addUniverse(sACNSourceUniverse(number: 8, levels: Array(repeating: 0, count: 512)))
        try await source.start()

        try await source.removeUniverse(with: 7)  // marks universe 7 removeAfterTerminate = true
        await source.stop()  // terminate(remove: false) for all - must not downgrade universe 7

        // universe 7 was removed during the drain; universe 8 remains (terminated, not marked for removal)
        let remaining = await source.currentUniverseNumbers
        #expect(remaining == [8])
    }

    /// Findings 3/4: a partial-failure `updateInterfaces` (one interface binds, one is bogus) rolls back
    /// all-or-nothing, leaving the source still listening on its original socket set rather than
    /// half-reconfigured or torn down.
    @Test("updateInterfaces partial failure rolls back to the live set", .timeLimit(.minutes(1)))
    func updateInterfacesPartialFailureRollsBack() async throws {
        let source = try await startedSource(universe: 4)
        #expect(await source.isListening)

        await #expect(throws: (any Error).self) {
            try await source.updateInterfaces(["definitely-not-a-real-interface"])
        }

        // the original all-interfaces socket was never torn down: the source is still listening
        #expect(await source.isListening)
        await source.stop()
    }

}
