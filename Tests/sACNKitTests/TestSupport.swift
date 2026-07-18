import Foundation

@testable import sACNKit

/// A tiny thread-safe box for values written from delegate callbacks.
///
/// Hoisted here so socket-facing suites share one implementation rather than each
/// carrying a private copy.
final class LockedBox<T> {

    private let lock = NSLock()
    private var _value: T?

    init(_ value: T? = nil) {
        _value = value
    }

    var value: T? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

}

/// A recording `ComponentSocketDelegate` for exercising socket implementations directly.
final class RecordingSocketDelegate: ComponentSocketDelegate {

    /// A received datagram, captured for assertions.
    struct Received {

        let data: Data
        let host: String
        let port: UInt16
        let family: ComponentSocketIPFamily

    }

    private let lock = NSLock()
    private var _received: [Received] = []
    private var _closeReason: SocketCloseReason?

    /// Signalled on each received datagram.
    let receivedSemaphore = DispatchSemaphore(value: 0)

    /// All datagrams received so far.
    var received: [Received] { lock.withLock { _received } }

    /// The reason reported by the last socket close, if any.
    var closeReason: SocketCloseReason? { lock.withLock { _closeReason } }

    func receivedMessage(
        for socket: ComponentSocket, withData data: Data, sourceHostname: String, sourcePort: UInt16, ipFamily: ComponentSocketIPFamily
    ) {
        lock.withLock { _received.append(Received(data: data, host: sourceHostname, port: sourcePort, family: ipFamily)) }
        receivedSemaphore.signal()
    }

    func socket(_ socket: ComponentSocket, socketDidCloseWith reason: SocketCloseReason) {
        lock.withLock { _closeReason = reason }
    }

    func debugLog(for socket: ComponentSocket, with logMessage: String) {}

}
