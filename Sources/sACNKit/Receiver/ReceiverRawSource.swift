//
//  ReceiverRawSource.swift
//
//  Copyright (c) 2023 Daniel Murfin
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

/// Receiver Source
///
class ReceiverRawSource {
    
    /// The unique identifier of this source.
    let cid: UUID
    
    /// The hostname being used for this source.
    /// Packets are ignored that originate from the same source (CID) from a different hostname (or IP family).
    let hostname: String
    
    /// The `ComponentSocketIPFamily` being used for this source.
    /// Packets are ignored that originate from the same source (CID) over another family (or interface).
    let ipFamily: ComponentSocketIPFamily
    
    /// The name of this source.
    var name: String
    
    /// The current last received sequence number.
    var sequence: UInt8
    
    /// Whether the source is terminated.
    var terminated: Bool
    
    /// Enumerates the possible states of this source.
    enum State {
        case waitingForLevels
        case waitingForPAP
        case hasLevelsOnly
        case hasLevelsAndPAP
    }
    
    /// The state of this source.
    var state: State
    
    /// Enumerates the possible availability states of this source.
    enum Available {
        case unknown
        case offline
        case online
    }
    
    /// Whether DMX has been received since the last sources check.
    var dmxReceivedSinceLastTick: Bool
    
    // MARK: Timers
    
    /// The timer use to detect source loss.
    private var packetTimer: MonotonicTimer
    
    /// The timer use to detect source loss.
    private var papTimer: MonotonicTimer
    
    // MARK: Notification
    
    /// Whether this source has been notified as lost.
    private (set) var notifiedLost: Bool
    
    /// Whether this source has been notified as per-address lost.
    private (set) var notifiedPerAddressLost: Bool
    
    init(cid: UUID, hostname: String, ipFamily: ComponentSocketIPFamily, name: String, sequence: UInt8, state: State) {
        self.cid = cid
        self.hostname = hostname
        self.ipFamily = ipFamily
        self.name = name
        self.sequence = sequence
        self.terminated = false
        self.state = state
        self.dmxReceivedSinceLastTick = true
        self.packetTimer = MonotonicTimer()
        self.papTimer = MonotonicTimer()
        notifiedLost = false
        notifiedPerAddressLost = false
    }
    
    // MARK: Per-address priority
    
    /// Starts a per-address priority timer to wait for per-address priorities, or discover per-address priority loss.
    ///
    /// - Parameters:
    ///    - interval: The interval after which the timer expires.
    ///
    func startPAPTimer(withInterval interval: UInt64) {
        papTimer.start(interval: UInt64(interval))
    }
    
    /// Resets the per-address priority timer.
    func resetPAPTimer() {
        papTimer.reset()
    }
    
    /// Whether the per-address priority timer has expired.
    var isPAPTimerExpired: Bool {
        papTimer.isExpired()
    }
    
    // MARK: Data loss
    
    /// Marks this source as terminated.
    func markTerminated() {
        terminated = true
        startPacketTimer(instant: true)
    }
    
    /// Starts a packet timer to discover data loss.
    ///
    /// - Parameters:
    ///    - instant: Whether this timer should occur instantly.
    ///
    func startPacketTimer(instant: Bool = false) {
        packetTimer.start(interval: instant ? 0 : sACNReceiverRaw.sourceLossTimeout)
    }
    
    /// Resets the packet priority timer.
    func resetPacketTimer() {
        packetTimer.reset()
    }
    
    /// Whether the packet timer has expired.
    var isPacketTimerExpired: Bool {
        packetTimer.isExpired()
    }
    
    /// The available status of this source.
    ///
    /// Queying this state also marks the source as not having received
    func available() -> Available {
        if isPacketTimerExpired {
            return .offline
        } else if dmxReceivedSinceLastTick {
            dmxReceivedSinceLastTick = false
            return .online
        } else {
            return .unknown
        }
    }
    
    /// Notifies this source as having lost per-address priority if it has not already been notified.
    ///
    /// - Parameters:
    ///    - delegate: The optional `sACNReceiverDelegate` to notify.
    ///    - receiver: The receiver which this call is associated with.
    ///
    func notifyPerAddressLost(using delegate: sACNReceiverRawDelegate?, from receiver: sACNReceiverRaw) {
        guard !notifiedPerAddressLost else { return }
        notifiedPerAddressLost = true
        delegate?.receiver(receiver, lostPerAddressPriorityFor: cid)
    }
    
}
