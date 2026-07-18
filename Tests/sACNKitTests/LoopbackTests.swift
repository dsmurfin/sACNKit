import Foundation
import Testing

@testable import sACNKit

/// End-to-end loopback tests: a real `sACNSource` transmitting to a real `sACNReceiver` / `sACNReceiverGroup`
/// over localhost multicast, observed on the merged `data`/`events` streams.
///
/// Multicast on shared CI runners is unreliable, so these only run when opted in with
/// `SACNKIT_NETWORK_TESTS=1` in the environment.
@Suite("Loopback", .enabled(if: ProcessInfo.processInfo.environment["SACNKIT_NETWORK_TESTS"] == "1"))
struct LoopbackTests {

    @Test("A source's levels arrive merged at a receiver", .timeLimit(.minutes(1)))
    func sourceToReceiver() async throws {
        let universe: UInt16 = 63999
        let levels: [UInt8] = (0..<512).map { UInt8($0 % 256) }

        let receiver = try #require(sACNReceiver(universe: universe))
        let merged = StreamCollector(receiver.data)
        try await receiver.start()

        let source = sACNSource(name: "Loopback Test Source")
        try await source.addUniverse(sACNSourceUniverse(number: universe, levels: levels))
        try await source.start()

        try await withStopped(source: source, receiver: receiver) {
            // sampling (1500 ms) must complete before merged data is notified
            #expect(await merged.waitFor { $0.universe == universe && $0.levels == levels }, "expected merged data from the loopback source")
            let frame = try #require(merged.all.last)
            #expect(frame.numberOfActiveSources == 1)

            // source information is available
            let cid = try #require(frame.activeSources.first)
            let information = try await receiver.information(for: cid)
            #expect(information.name == "Loopback Test Source")
        }
    }

    /// IPv6 end-to-end, exercising the `IPV6_MULTICAST_IF` egress path (the one untested-and-suspect area
    /// flagged in the Phase 3 completion note / risk R5). Requires working IPv6 multicast loopback, so it
    /// shares the `SACNKIT_NETWORK_TESTS` gate and is never a merge blocker.
    @Test("A source's levels arrive merged at a receiver over IPv6", .timeLimit(.minutes(1)))
    func sourceToReceiverIPv6() async throws {
        let universe: UInt16 = 63999
        let levels: [UInt8] = (0..<512).map { UInt8($0 % 256) }
        let interface = TestInterface.loopback

        let receiver = try #require(sACNReceiver(ipMode: .ipv6Only, interfaces: [interface], universe: universe))
        let merged = StreamCollector(receiver.data)
        try await receiver.start()

        let source = sACNSource(name: "Loopback Test Source v6", ipMode: .ipv6Only, interfaces: [interface])
        try await source.addUniverse(sACNSourceUniverse(number: universe, levels: levels))
        try await source.start()

        try await withStopped(source: source, receiver: receiver) {
            #expect(
                await merged.waitFor { $0.universe == universe && $0.levels == levels },
                "expected merged data from the loopback source over IPv6")
            let frame = try #require(merged.all.last)
            #expect(frame.numberOfActiveSources == 1)
        }
    }

    @Test("A source's levels arrive merged at a receiver group, and loss is reported", .timeLimit(.minutes(1)))
    func sourceToReceiverGroup() async throws {
        let universe: UInt16 = 63998
        let levels: [UInt8] = (0..<512).map { UInt8($0 % 256) }

        let group = sACNReceiverGroup()
        let merged = StreamCollector(group.data)
        let events = StreamCollector(group.events)
        try await group.add(universe: universe)

        let source = sACNSource(name: "Loopback Group Source")
        try await source.addUniverse(sACNSourceUniverse(number: universe, levels: levels))
        try await source.start()

        #expect(
            await merged.waitFor { $0.universe == universe && $0.levels == levels },
            "expected merged data from the loopback source at the group")

        // stopping the source terminates the stream; the group reports the loss (tagged with the universe)
        await source.stop()
        #expect(
            await events.waitFor(timeout: .seconds(8)) {
                if case .sourcesLost(_, let lostUniverse) = $0, lostUniverse == universe { return true } else { return false }
            }, "expected the group to report source loss for the universe")

        await group.remove(universe: universe)
    }

    @Test("Stopping a receiver while a source is transmitting completes cleanly and quiesces", .timeLimit(.minutes(1)))
    func stopDuringInboundQuiesces() async throws {
        let universe: UInt16 = 63997
        let levels: [UInt8] = (0..<512).map { UInt8($0 % 256) }

        let receiver = try #require(sACNReceiver(universe: universe))
        let merged = StreamCollector(receiver.data)
        try await receiver.start()

        let source = sACNSource(name: "Loopback Stop-Race Source")
        try await source.addUniverse(sACNSourceUniverse(number: universe, levels: levels))
        try await source.start()

        // receive at least one frame, so the source is actively transmitting into the receiver
        #expect(await merged.waitFor { $0.universe == universe })

        // stop the receiver while the source keeps transmitting: teardown nils every socket delegate before
        // awaiting the closes, so no socket delivers a packet (creating a source) during the close awaits -
        // the whole path is TSan-checked here. stop() must return and leave the receiver idle.
        await receiver.stop()
        #expect(await receiver.isListening == false)

        await source.stop()
    }

    /// Runs `body`, then stops `source` and `receiver` on **every** exit (success or throw), so a failed
    /// assertion never leaks an un-terminated source into the next network test on the shared universe.
    /// `stop()` is async, so a `defer` cannot do this.
    private func withStopped(source: sACNSource, receiver: sACNReceiver, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await source.stop()
            await receiver.stop()
            throw error
        }
        await source.stop()
        await receiver.stop()
    }

}
