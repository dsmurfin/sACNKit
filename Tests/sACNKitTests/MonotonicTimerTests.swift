import Foundation
import Testing

@testable import sACNKit

/// Characterizes `MonotonicTimer` expiry semantics.
@Suite("Monotonic timer")
struct MonotonicTimerTests {

    @Test("A timer initializes in an expired state")
    func initiallyExpired() {
        let timer = MonotonicTimer()
        #expect(timer.isExpired())
        #expect(timer.timeRemaining() == 0)
    }

    @Test("Starting with an interval of zero means instantly expired")
    func zeroIntervalExpired() {
        let timer = MonotonicTimer()
        timer.start(interval: 0)
        #expect(timer.isExpired())
    }

    @Test("A started timer is not expired before its interval elapses")
    func startedNotExpired() {
        let timer = MonotonicTimer()
        timer.start(interval: 10_000)
        #expect(!timer.isExpired())
        #expect(timer.timeRemaining() > 0)
        #expect(timer.timeRemaining() <= 10_000)
        #expect(timer.timeElapsed() < 10_000)
    }

    @Test("A timer expires after its interval elapses")
    func expiresAfterInterval() {
        let timer = MonotonicTimer()
        timer.start(interval: 20)
        usleep(60_000)
        #expect(timer.isExpired())
        #expect(timer.timeRemaining() == 0)
    }

    @Test("Resetting restarts the previously defined interval")
    func resetRestartsInterval() {
        let timer = MonotonicTimer()
        timer.start(interval: 10_000)
        timer.reset()
        #expect(!timer.isExpired())
        #expect(timer.timeRemaining() > 0)
    }

}
