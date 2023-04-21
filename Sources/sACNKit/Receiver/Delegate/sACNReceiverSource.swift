//
//  sACNReceiverSource.swift
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

/// sACN Receiver Source
///
/// Useful information about a source discovered by a receiver such as
/// CID, IP address (hostname) and name.
public struct sACNReceiverSource {
    
    /// The sACN CID of this source.
    public var cid: UUID
    
    /// The hostname of the source.
    public var hostname: String
    
    /// The name of the source.
    public var name: String
    
    /// Whether this source is currently sampling.
    public var isSampling: Bool
    
    init(receiverSource: ReceiverSource) {
        cid = receiverSource.cid
        hostname = receiverSource.hostname
        name = receiverSource.name
        isSampling = receiverSource.sampling
    }
    
}

/// sACN Receiver Extension
///
/// Hashable Conformance.
extension sACNReceiverSource: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(cid)
    }
}
