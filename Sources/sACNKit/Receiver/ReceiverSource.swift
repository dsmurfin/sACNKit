//
//  ReceiverSource.swift
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
class ReceiverSource {
    
    /// The sACN CID of this source.
    var cid: UUID
    
    /// The hostname of the source.
    var hostname: String
    
    /// The name of the source.
    var name: String
    
    /// Whether only per-address priority data has been received (waiting for levels).
    var pending: Bool
    
    /// Whether this source is currently sampling.
    var sampling: Bool
    
    init(sourceData: sACNReceiverRawSourceData, pending: Bool) {
        self.cid = sourceData.cid
        self.hostname = sourceData.hostname
        self.name = sourceData.name
        self.pending = pending
        self.sampling = sourceData.isSampling
    }
    
}
