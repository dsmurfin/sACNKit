//
//  sACNReceiverGroupDelegate.swift
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

/// sACN Receiver Group Delegate
///
/// Required methods for objects implementing this delegate.
public protocol sACNReceiverGroupDelegate: AnyObject {
    /// Called when a socket was closed for this receiver.
    ///
    /// - Parameters:
    ///    - receiverGroup: The receiver group for which the socket was closed.
    ///    - interface: The optional interface associated with the socket.
    ///    - error: An optional error which occured when the socket was closed.
    ///    - universe: The universe.
    ///
    func receiverGroup(_ receiverGroup: sACNReceiverGroup, interface: String?, socketDidCloseWithError error: Error?, forUniverse universe: UInt16)
    
    /// Called when new data is received from a source for a universe.
    ///
    /// Note: This call is synchronous, so should be handled quickly.
    ///
    /// - Parameters:
    ///    - receiverGroup: The receiver group.
    ///    - universeData: The universe data received.
    ///
    func receiverGroupMergedData(_ receiverGroup: sACNReceiverGroup, mergedData: sACNReceiverMergedData)
    
    /// Called when the receiver group begins sampling.
    ///
    /// This may occur when it is started, or when interfaces are changed.
    ///
    /// - Parameters:
    ///    - receiverGroup: The receiver group.
    ///    - universe: The universe.
    ///
    func receiverGroupStartedSampling(_ receiverGroup: sACNReceiverGroup, forUniverse universe: UInt16)
    
    /// Called when the receiver group ends sampling.
    ///
    /// - Parameters:
    ///    - receiverGroup: The receiver group.
    ///    - universe: The universe.
    ///
    func receiverGroupEndedSampling(_ receiverGroup: sACNReceiverGroup, forUniverse universe: UInt16)

    /// Called when the receiver group loses one or more sources.
    ///
    /// Source loss is coalesced to reduce notifications.
    ///
    /// - Parameters:
    ///    - receiverGroup: The receiver group.
    ///    - sources: The source identifiers which were lost.
    ///    - universe: The universe.
    ///
    func receiverGroup(_ receiverGroup: sACNReceiverGroup, lostSources: [UUID], forUniverse universe: UInt16)

    /// Called when data from too many sources has been received.
    ///
    /// - Parameters:
    ///    - receiverGroup: The receiver group.
    ///    - universe: The universe.
    ///
    func receiverGroupExceededSources(_ receiverGroup: sACNReceiverGroup, forUniverse universe: UInt16)
}
