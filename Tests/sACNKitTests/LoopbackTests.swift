import Foundation
import Testing

@testable import sACNKit

/// End-to-end loopback tests: a real `sACNSource` transmitting to a real `sACNReceiver`
/// over localhost multicast.
///
/// Multicast on shared CI runners is unreliable, so these only run when opted in with
/// `SACNKIT_NETWORK_TESTS=1` in the environment.
@Suite("Loopback", .enabled(if: ProcessInfo.processInfo.environment["SACNKIT_NETWORK_TESTS"] == "1"))
struct LoopbackTests {

    /// A recording `sACNReceiverDelegate` which signals on merged data.
    private final class DelegateMock: sACNReceiverDelegate {

        private let lock = NSLock()
        let mergedSemaphore = DispatchSemaphore(value: 0)
        private var _merged: [sACNReceiverMergedData] = []
        var merged: [sACNReceiverMergedData] { lock.withLock { _merged } }
        var onMerged: ((sACNReceiverMergedData) -> Void)?

        func receiver(_ receiver: sACNReceiver, interface: String?, socketDidCloseWithError error: Error?) {}

        func receiverMergedData(_ receiver: sACNReceiver, mergedData: sACNReceiverMergedData) {
            lock.withLock { _merged.append(mergedData) }
            onMerged?(mergedData)
            mergedSemaphore.signal()
        }

        func receiverStartedSampling(_ receiver: sACNReceiver) {}

        func receiverEndedSampling(_ receiver: sACNReceiver) {}

        func receiver(_ receiver: sACNReceiver, lostSources: [UUID]) {}

        func receiverExceededSources(_ receiver: sACNReceiver) {}

    }

    @Test("A source's levels arrive merged at a receiver", .timeLimit(.minutes(1)))
    func sourceToReceiver() async throws {
        let universe: UInt16 = 63999
        let levels: [UInt8] = (0..<512).map { UInt8($0 % 256) }

        let receiverQueue = DispatchQueue(label: "com.danielmurfin.sACNKitTests.loopbackReceiver")
        let receiver = try #require(sACNReceiver(universe: universe, delegateQueue: receiverQueue))
        let delegate = DelegateMock()
        receiver.setDelegate(delegate)
        try receiver.start()
        defer { receiver.stop() }

        let source = sACNSource(name: "Loopback Test Source")
        try await source.addUniverse(sACNSourceUniverse(number: universe, levels: levels))
        try await source.start()

        try await withSourceStopped(source) {
            // sampling (1500 ms) must complete before merged data is notified
            let merged = try #require(try await Self.waitForMerged(delegate), "expected merged data from the loopback source")
            #expect(merged.universe == universe)
            #expect(merged.levels == levels)
            #expect(merged.numberOfActiveSources == 1)

            // source information is available from within and outside callbacks
            let cid = try #require(merged.activeSources.first)
            let information = try receiver.information(for: cid)
            #expect(information.name == "Loopback Test Source")
        }
    }

    /// IPv6 end-to-end, exercising the `IPV6_MULTICAST_IF` egress path (the one untested-and-suspect
    /// area flagged in the Phase 3 completion note / risk R5). Requires working IPv6 multicast
    /// loopback, so it shares the `SACNKIT_NETWORK_TESTS` gate and is never a merge blocker.
    @Test("A source's levels arrive merged at a receiver over IPv6", .timeLimit(.minutes(1)))
    func sourceToReceiverIPv6() async throws {
        let universe: UInt16 = 63999
        let levels: [UInt8] = (0..<512).map { UInt8($0 % 256) }
        let interface = TestInterface.loopback

        let receiverQueue = DispatchQueue(label: "com.danielmurfin.sACNKitTests.loopbackReceiverV6")
        let receiver = try #require(
            sACNReceiver(ipMode: .ipv6Only, interfaces: [interface], universe: universe, delegateQueue: receiverQueue))
        let delegate = DelegateMock()
        receiver.setDelegate(delegate)
        try receiver.start()
        defer { receiver.stop() }

        let source = sACNSource(name: "Loopback Test Source v6", ipMode: .ipv6Only, interfaces: [interface])
        try await source.addUniverse(sACNSourceUniverse(number: universe, levels: levels))
        try await source.start()

        try await withSourceStopped(source) {
            let merged = try #require(try await Self.waitForMerged(delegate), "expected merged data from the loopback source over IPv6")
            #expect(merged.universe == universe)
            #expect(merged.levels == levels)
            #expect(merged.numberOfActiveSources == 1)
        }
    }

    /// Polls a delegate for merged data up to a timeout, in an async-friendly way (no blocking semaphore).
    /// The sleep propagates cancellation (rather than `try?`-swallowing it), so a cancelled/timed-out run
    /// unwinds immediately instead of busy-spinning the poll to the deadline.
    private static func waitForMerged(_ delegate: DelegateMock, timeout: Duration = .seconds(10)) async throws -> sACNReceiverMergedData? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let merged = delegate.merged.last { return merged }
            try await Task.sleep(for: .milliseconds(50))
        }
        return delegate.merged.last
    }

    /// Runs `body`, then stops `source` on **every** exit (success or throw), so a failed assertion never
    /// leaks an un-terminated source into the next network test on the shared universe. `stop()` is async,
    /// so a `defer` cannot do this.
    private func withSourceStopped(_ source: sACNSource, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await source.stop()
            throw error
        }
        await source.stop()
    }

}
