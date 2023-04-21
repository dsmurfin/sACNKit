//
//  DiscoveryReceiverSource.swift
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

/// Discovery Receiver Source
/// 
class DiscoveryReceiverSource {
    
    /// The sACN universe discovery interval (10,000 ms).
    static let discoveryInterval: UInt64 = 10000

    /// The name of the source.
    var name: String
    
    /// The universes found for this source.
    var universes: [UInt16]
    
    /// The number of universes.
    var universeCount: Int
    
    /// Whether there are un-notified changes.
    var dirty: Bool
    
    /// The most recently notified number of universes.
    var lastNotifiedUniverseCount: Int

    /// The next expected universe index.
    var nextUniverseIndex: Int
    
    /// The next expected page.
    var nextPage: Int
    
    /// The timer use to detect source loss.
    var timer: MonotonicTimer
    
    init(name: String) {
        self.name = name
        self.universes = []
        self.universeCount = 0
        self.dirty = true
        self.lastNotifiedUniverseCount = 0
        self.nextUniverseIndex = 0
        self.nextPage = 0
        self.timer = MonotonicTimer()
    }
    
    /// Starts a timer to discover source loss.
    func startTimer() {
        timer.start(interval: Self.discoveryInterval*2)
    }
    
    /// Resets the timer.
    func resetTimer() {
        timer.reset()
    }
    
    /// Whether the timer has expired.
    var isTimerExpired: Bool {
        timer.isExpired()
    }
    
}
