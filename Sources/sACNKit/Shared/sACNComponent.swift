//
//  sACNComponent.swift
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

/// sACN Component Protocol Error Delegate
///
/// Required methods for objects implementing this delegate.
///
public protocol sACNComponentProtocolErrorDelegate: AnyObject {
    /// Notifies the delegate of errors in parsing layers.
    ///
    /// - Parameters:
    ///    - errorDescription: A human-readable description of the error.
    ///
    func layerError(_ errorDescription: String)
    
    /// Notifies the delegate of sequence errors.
    ///
    /// - Parameters:
    ///    - errorDescription: A human-readable description of the error.
    ///
    func sequenceError(_ errorDescription: String)
    
    /// Notifies the delegate of unknown errors.
    ///
    /// - Parameters:
    ///    - errorDescription: A human-readable description of the error.
    ///
    func unknownError(_ errorDescription: String)
}

// MARK: -
// MARK: -

/// sACN Component Debug Delegate
///
/// Required methods for objects implementing this delegate.
///
public protocol sACNComponentDebugDelegate: AnyObject {
    /// Notifies the delegate of a new debug log entry.
    ///
    /// - Parameters:
    ///    - logMessage: A human-readable log message.
    ///
    func debugLog(_ logMessage: String)
    
    /// Notifies the delegate of a new socket debug log entry.
    ///
    /// - Parameters:
    ///    - logMessage: A human-readable log message.
    ///
    func debugSocketLog(_ logMessage: String)
}
