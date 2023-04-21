//
//  sACNReceiverDelegate.swift
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

/// sACN Receiver Delegate
///
/// Required methods for objects implementing this delegate.
public protocol sACNReceiverDelegate: AnyObject {
    /// Called when a socket was closed for this receiver.
    ///
    /// - Parameters:
    ///    - receiver: The receiver for which the socket was closed.
    ///    - interface: The optional interface associated with the socket.
    ///    - error: An optional error which occured when the socket was closed.
    ///
    func receiver(_ receiver: sACNReceiver, interface: String?, socketDidCloseWithError error: Error?)
    
    /// Called when new data is received from a source for a universe.
    ///
    /// Note: This call is synchronous, so should be handled quickly.
    ///
    /// - Parameters:
    ///    - receiver: The receiver.
    ///    - universeData: The universe data received.
    ///
    func receiverMergedData(_ receiver: sACNReceiver, mergedData: sACNReceiverMergedData)
    
    /// Called when the receiver begins sampling.
    ///
    /// This may occur when it is started, or when interfaces are changed.
    ///
    /// - Parameters:
    ///    - receiver: The receiver.
    ///
    func receiverStartedSampling(_ receiver: sACNReceiver)
    
    /// Called when the receiver ends sampling.
    ///
    /// - Parameters:
    ///    - receiver: The receiver.
    ///
    func receiverEndedSampling(_ receiver: sACNReceiver)

    /// Called when the receiver loses one or more sources.
    ///
    /// Source loss is coalesced to reduce notifications.
    ///
    /// - Parameters:
    ///    - receiver: The receiver.
    ///    - sources: The source identifiers which were lost.
    ///
    func receiver(_ receiver: sACNReceiver, lostSources: [UUID])

    /// Called when data from too many sources has been received.
    ///
    /// - Parameters:
    ///    - receiver: The receiver.
    ///
    func receiverExceededSources(_ receiver: sACNReceiver)
}
