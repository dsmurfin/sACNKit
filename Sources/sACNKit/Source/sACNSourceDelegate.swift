//
//  sACNSourceDelegate.swift
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

/// sACN Source Delegate
///
/// Required methods for objects implementing this delegate.
public protocol sACNSourceDelegate: AnyObject {
    /// Called when a socket was closed for this source.
    ///
    /// - Parameters:
    ///    - source: The source for which the socket was closed.
    ///    - interface: The optional interface associated with the socket.
    ///    - error: An optional error which occured when the socket was closed.
    ///
    func source(_ source: sACNSource, interface: String?, socketDidCloseWithError error: Error?)
    
    /// Notifies the delegate that the source is actively transmitting universe data messages.
    func transmissionStarted()
    
    /// Notifies the delegate that the source has stopped transmitting universe data messages.
    /// Note: This does not indicate that the source is stopped, it could simply be no universes have been added.
    func transmissionEnded()
}
