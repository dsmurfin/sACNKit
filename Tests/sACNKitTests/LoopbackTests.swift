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
    func sourceToReceiver() throws {
        let universe: UInt16 = 63999
        let levels: [UInt8] = (0..<512).map { UInt8($0 % 256) }

        let receiverQueue = DispatchQueue(label: "com.danielmurfin.sACNKitTests.loopbackReceiver")
        let receiver = try #require(sACNReceiver(universe: universe, delegateQueue: receiverQueue))
        let delegate = DelegateMock()
        receiver.setDelegate(delegate)
        try receiver.start()

        let source = sACNSource(name: "Loopback Test Source", delegateQueue: DispatchQueue(label: "com.danielmurfin.sACNKitTests.loopbackSource"))
        try source.addUniverse(sACNSourceUniverse(number: universe, levels: levels))
        try source.start()
        defer {
            source.stop()
            receiver.stop()
        }

        // sampling (1500 ms) must complete before merged data is notified
        #expect(delegate.mergedSemaphore.wait(timeout: .now() + .seconds(10)) == .success, "expected merged data from the loopback source")
        let merged = try #require(delegate.merged.last)
        #expect(merged.universe == universe)
        #expect(merged.levels == levels)
        #expect(merged.numberOfActiveSources == 1)

        // source information is available from within and outside callbacks
        let cid = try #require(merged.activeSources.first)
        let information = try receiver.information(for: cid)
        #expect(information.name == "Loopback Test Source")
    }

}
