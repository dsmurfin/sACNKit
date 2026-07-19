import Foundation
import Testing

@testable import sACNKit

/// Exercises `NIOComponentSocket` directly: binding, reuse-port, multicast join/leave, the typed
/// error surface, re-listen, deallocation, and datagram delivery.
///
/// Sockets are created on the actor/event-loop path via `NIORuntime().makeSocket` and driven with the
/// `async` API (callbacks deliver on the event loop; `RecordingSocketDelegate` is lock-guarded). These bind
/// real sockets and send real datagrams, so they only run with `SACNKIT_NETWORK_TESTS=1`. The suite is
/// serialized and uses a dedicated port so it never races the 5568-based loopback and receiver-group suites.
@Suite("NIO component socket", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SACNKIT_NETWORK_TESTS"] == "1"))
struct NIOComponentSocketTests {

    /// A dedicated port, away from sACN's 5568, so this suite never collides with the other socket suites.
    private static let testPort: UInt16 = 15568

    /// Creates a socket on a fresh runtime's event loop (the actor path).
    private func makeSocket(_ type: ComponentSocketType, port: UInt16 = 0) -> ComponentSocket {
        NIORuntime().makeSocket(type: type, ipMode: .ipv4Only, port: port)
    }

    /// Async-polls a recording delegate until it has received at least `count` datagrams (delivery lands on
    /// the event loop; a blocking semaphore wait is not available from an async test).
    private func waitForReceived(_ delegate: RecordingSocketDelegate, count: Int = 1, timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if delegate.received.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return delegate.received.count >= count
    }

    // MARK: Binding

    @Test("A transmit socket binds an ephemeral port")
    func transmitBinds() async throws {
        let socket = makeSocket(.transmit)
        try await socket.startListening(onInterface: nil)
        await socket.stopListening()
    }

    @Test("An actor-path transmit socket binds and re-listens without blocking")
    func asyncTransmitBindsAndRelistens() async throws {
        let socket = makeSocket(.transmit)
        try await socket.startListening(onInterface: nil)
        await socket.stopListening()
        // re-listen on the same socket
        try await socket.startListening(onInterface: nil)
        await socket.stopListening()
    }

    @Test("An actor-path transmit socket surfaces couldNotBind for a bogus interface")
    func asyncTransmitBogusInterfaceThrows() async {
        let socket = makeSocket(.transmit)
        await #expect(throws: sACNComponentSocketError.self) {
            try await socket.startListening(onInterface: "sacnkit-no-such-interface")
        }
    }

    @Test("A receive socket binds the wildcard port")
    func receiveBinds() async throws {
        let socket = makeSocket(.receive, port: Self.testPort)
        try await socket.startListening(onInterface: nil)
        await socket.stopListening()
    }

    @Test("Two receive sockets share the port via reuse-port")
    func twoReceiveSocketsShareThePort() async throws {
        let first = makeSocket(.receive, port: Self.testPort)
        let second = makeSocket(.receive, port: Self.testPort)
        try await first.startListening(onInterface: nil)
        try await second.startListening(onInterface: nil)
        await first.stopListening()
        await second.stopListening()
    }

    @Test("A receive socket joins and leaves a multicast group")
    func joinAndLeaveMulticast() async throws {
        let socket = makeSocket(.receive, port: Self.testPort)
        try await socket.startListening(onInterface: nil)
        let group = IPv4.multicastHostname(for: 100)
        try await socket.join(multicastGroup: group)
        try await socket.leave(multicastGroup: group)
        await socket.stopListening()
    }

    // MARK: Typed error surface

    @Test("A bogus interface throws couldNotJoin on a receive socket")
    func bogusInterfaceThrowsCouldNotJoinOnReceive() async throws {
        // receive binds the wildcard without the interface, so startListening succeeds...
        let socket = makeSocket(.receive, port: Self.testPort)
        try await socket.startListening(onInterface: "sacnkit-no-such-interface")
        // ...and the interface only fails when it is used, at join, preserving today's error case.
        await #expect(throws: sACNComponentSocketError.self) {
            try await socket.join(multicastGroup: IPv4.multicastHostname(for: 100))
        }
        await socket.stopListening()
    }

    @Test("A bogus interface throws couldNotBind on a transmit socket")
    func bogusInterfaceThrowsCouldNotBindOnTransmit() async {
        // transmit binds to the interface's address, so an unresolvable interface fails at bind.
        let socket = makeSocket(.transmit)
        await #expect(throws: sACNComponentSocketError.self) {
            try await socket.startListening(onInterface: "sacnkit-no-such-interface")
        }
    }

    // MARK: Delivery

    @Test("A receive socket delivers a unicast datagram to its delegate")
    func unicastDeliveryReachesDelegate() async throws {
        let receiver = makeSocket(.receive, port: Self.testPort)
        let delegate = RecordingSocketDelegate()
        receiver.delegate = delegate
        try await receiver.startListening(onInterface: nil)

        let sender = makeSocket(.transmit)
        try await sender.startListening(onInterface: nil)
        sender.send(message: Data([0x10, 0x20, 0x30, 0x40]), host: "127.0.0.1", port: Self.testPort)

        #expect(await waitForReceived(delegate), "expected a unicast datagram")
        let message = try #require(delegate.received.first)
        #expect(message.data == Data([0x10, 0x20, 0x30, 0x40]))
        #expect(message.family == .IPv4)
        #expect(message.host == "127.0.0.1")

        await sender.stopListening()
        await receiver.stopListening()
    }

    @Test("A receive socket delivers a multicast datagram to its delegate")
    func multicastDeliveryReachesDelegate() async throws {
        let group = IPv4.multicastHostname(for: 100)
        let receiver = makeSocket(.receive, port: Self.testPort)
        let delegate = RecordingSocketDelegate()
        receiver.delegate = delegate
        try await receiver.startListening(onInterface: nil)
        try await receiver.join(multicastGroup: group)

        let sender = makeSocket(.transmit)
        try await sender.startListening(onInterface: nil)
        sender.send(message: Data([0xDD, 0xEE]), host: group, port: Self.testPort)

        #expect(await waitForReceived(delegate), "expected a multicast datagram")
        #expect(try #require(delegate.received.first).data == Data([0xDD, 0xEE]))

        await sender.stopListening()
        await receiver.stopListening()
    }

    // MARK: Lifecycle

    @Test("A socket can be stopped and restarted on the same instance")
    func reListenAfterStop() async throws {
        let receiver = makeSocket(.receive, port: Self.testPort)
        let delegate = RecordingSocketDelegate()
        receiver.delegate = delegate
        let sender = makeSocket(.transmit)
        try await sender.startListening(onInterface: nil)

        for cycle in 0..<2 {
            try await receiver.startListening(onInterface: nil)
            sender.send(message: Data([UInt8(cycle)]), host: "127.0.0.1", port: Self.testPort)
            // the delegate accumulates across cycles, so wait for the cumulative count to reach this cycle
            #expect(await waitForReceived(delegate, count: cycle + 1), "expected delivery on listen cycle \(cycle)")
            await receiver.stopListening()
        }

        await sender.stopListening()
    }

    @Test("A released socket deallocates (no retain cycle)")
    func deallocationTearsDownSocket() async throws {
        weak var weakSocket: (any ComponentSocket)?
        do {
            let socket = makeSocket(.receive, port: Self.testPort)
            socket.delegate = RecordingSocketDelegate()
            try await socket.startListening(onInterface: nil)
            weakSocket = socket
        }
        #expect(weakSocket == nil, "the facade must deallocate once released, closing its channels on deinit")
    }

}
