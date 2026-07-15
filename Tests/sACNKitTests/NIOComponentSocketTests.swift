import Foundation
import Testing

@testable import sACNKit

/// Exercises `NIOComponentSocket` directly: binding, reuse-port, multicast join/leave, the typed
/// error surface, re-listen, deallocation, and datagram delivery.
///
/// These bind real sockets and send real datagrams, so they only run with `SACNKIT_NETWORK_TESTS=1`.
/// The suite is serialized and uses a dedicated port so it never races the 5568-based loopback and
/// receiver-group suites.
@Suite("NIO component socket", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SACNKIT_NETWORK_TESTS"] == "1"))
struct NIOComponentSocketTests {

    /// A dedicated port, away from sACN's 5568, so this suite never collides with the other socket suites.
    private static let testPort: UInt16 = 15568

    /// The timeout for waiting on an expected delivery.
    private static let timeout: DispatchTimeInterval = .seconds(10)

    private func makeQueue(_ label: String) -> DispatchQueue {
        DispatchQueue(label: "com.danielmurfin.sACNKitTests.\(label)")
    }

    // MARK: Binding

    @Test("A transmit socket binds an ephemeral port")
    func transmitBinds() throws {
        let socket = NIOComponentSocket(type: .transmit, ipMode: .ipv4Only, delegateQueue: makeQueue("nio.tx"))
        try socket.startListening(onInterface: nil)
        socket.stopListening()
    }

    @Test("A receive socket binds the wildcard port")
    func receiveBinds() throws {
        let socket = NIOComponentSocket(type: .receive, ipMode: .ipv4Only, port: Self.testPort, delegateQueue: makeQueue("nio.rx"))
        try socket.startListening(onInterface: nil)
        socket.stopListening()
    }

    @Test("Two receive sockets share the port via reuse-port")
    func twoReceiveSocketsShareThePort() throws {
        let first = NIOComponentSocket(type: .receive, ipMode: .ipv4Only, port: Self.testPort, delegateQueue: makeQueue("nio.rx1"))
        let second = NIOComponentSocket(type: .receive, ipMode: .ipv4Only, port: Self.testPort, delegateQueue: makeQueue("nio.rx2"))
        try first.startListening(onInterface: nil)
        try second.startListening(onInterface: nil)
        first.stopListening()
        second.stopListening()
    }

    @Test("A receive socket joins and leaves a multicast group")
    func joinAndLeaveMulticast() throws {
        let socket = NIOComponentSocket(type: .receive, ipMode: .ipv4Only, port: Self.testPort, delegateQueue: makeQueue("nio.join"))
        try socket.startListening(onInterface: nil)
        defer { socket.stopListening() }
        let group = IPv4.multicastHostname(for: 100)
        try socket.join(multicastGroup: group)
        try socket.leave(multicastGroup: group)
    }

    // MARK: Typed error surface

    @Test("A bogus interface throws couldNotJoin on a receive socket")
    func bogusInterfaceThrowsCouldNotJoinOnReceive() throws {
        // receive binds the wildcard without the interface, so startListening succeeds...
        let socket = NIOComponentSocket(type: .receive, ipMode: .ipv4Only, port: Self.testPort, delegateQueue: makeQueue("nio.badjoin"))
        try socket.startListening(onInterface: "sacnkit-no-such-interface")
        defer { socket.stopListening() }
        // ...and the interface only fails when it is used, at join, preserving today's error case.
        #expect(throws: sACNComponentSocketError.self) {
            try socket.join(multicastGroup: IPv4.multicastHostname(for: 100))
        }
    }

    @Test("A bogus interface throws couldNotBind on a transmit socket")
    func bogusInterfaceThrowsCouldNotBindOnTransmit() {
        // transmit binds to the interface's address, so an unresolvable interface fails at bind.
        let socket = NIOComponentSocket(type: .transmit, ipMode: .ipv4Only, delegateQueue: makeQueue("nio.badbind"))
        #expect(throws: sACNComponentSocketError.self) {
            try socket.startListening(onInterface: "sacnkit-no-such-interface")
        }
    }

    // MARK: Delivery

    @Test("A receive socket delivers a unicast datagram to its delegate")
    func unicastDeliveryReachesDelegate() throws {
        let receiver = NIOComponentSocket(type: .receive, ipMode: .ipv4Only, port: Self.testPort, delegateQueue: makeQueue("nio.rx.unicast"))
        let delegate = RecordingSocketDelegate()
        receiver.delegate = delegate
        try receiver.startListening(onInterface: nil)
        defer { receiver.stopListening() }

        let sender = NIOComponentSocket(type: .transmit, ipMode: .ipv4Only, delegateQueue: makeQueue("nio.tx.unicast"))
        try sender.startListening(onInterface: nil)
        defer { sender.stopListening() }
        sender.send(message: Data([0x10, 0x20, 0x30, 0x40]), host: "127.0.0.1", port: Self.testPort)

        #expect(delegate.receivedSemaphore.wait(timeout: .now() + Self.timeout) == .success, "expected a unicast datagram")
        let message = try #require(delegate.received.first)
        #expect(message.data == Data([0x10, 0x20, 0x30, 0x40]))
        #expect(message.family == .IPv4)
        #expect(message.host == "127.0.0.1")
    }

    @Test("A receive socket delivers a multicast datagram to its delegate")
    func multicastDeliveryReachesDelegate() throws {
        let group = IPv4.multicastHostname(for: 100)
        let receiver = NIOComponentSocket(type: .receive, ipMode: .ipv4Only, port: Self.testPort, delegateQueue: makeQueue("nio.rx.mcast"))
        let delegate = RecordingSocketDelegate()
        receiver.delegate = delegate
        try receiver.startListening(onInterface: nil)
        try receiver.join(multicastGroup: group)
        defer { receiver.stopListening() }

        let sender = NIOComponentSocket(type: .transmit, ipMode: .ipv4Only, delegateQueue: makeQueue("nio.tx.mcast"))
        try sender.startListening(onInterface: nil)
        defer { sender.stopListening() }
        sender.send(message: Data([0xDD, 0xEE]), host: group, port: Self.testPort)

        #expect(delegate.receivedSemaphore.wait(timeout: .now() + Self.timeout) == .success, "expected a multicast datagram")
        #expect(try #require(delegate.received.first).data == Data([0xDD, 0xEE]))
    }

    // MARK: Lifecycle

    @Test("A socket can be stopped and restarted on the same instance")
    func reListenAfterStop() throws {
        let receiver = NIOComponentSocket(type: .receive, ipMode: .ipv4Only, port: Self.testPort, delegateQueue: makeQueue("nio.relisten.rx"))
        let delegate = RecordingSocketDelegate()
        receiver.delegate = delegate
        let sender = NIOComponentSocket(type: .transmit, ipMode: .ipv4Only, delegateQueue: makeQueue("nio.relisten.tx"))
        try sender.startListening(onInterface: nil)
        defer { sender.stopListening() }

        for cycle in 0..<2 {
            try receiver.startListening(onInterface: nil)
            sender.send(message: Data([UInt8(cycle)]), host: "127.0.0.1", port: Self.testPort)
            #expect(
                delegate.receivedSemaphore.wait(timeout: .now() + Self.timeout) == .success,
                "expected delivery on listen cycle \(cycle)")
            receiver.stopListening()
        }
    }

    @Test("A released socket deallocates (no retain cycle)")
    func deallocationTearsDownSocket() throws {
        weak var weakSocket: NIOComponentSocket?
        do {
            let socket = NIOComponentSocket(type: .receive, ipMode: .ipv4Only, port: Self.testPort, delegateQueue: makeQueue("nio.dealloc"))
            socket.delegate = RecordingSocketDelegate()
            try socket.startListening(onInterface: nil)
            weakSocket = socket
        }
        #expect(weakSocket == nil, "the facade must deallocate once released, closing its channels on deinit")
    }

}
