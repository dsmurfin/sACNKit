//
//  NetworkDefinitions.swift
//
//  Copyright (c) 2022 Daniel Murfin
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

/// UDP
///
/// UDP related constants and definitions.
///
struct UDP {
    /// The UDP port used by sACN for multicast transmission.
    static let sdtPort: UInt16 = 5568
}

/// IP Mode
///
/// The Internet Protocol version used by a component.
///
/// - ipv4Only: Only use IPv4
/// - ipv6Only: Only use IPv6
/// - ipv4And6: Use IPv4 and IPv6
///
public enum sACNIPMode: String, CaseIterable {
    /// The  component should only use IPv4.
    case ipv4Only = "IPv4"
    /// The component should only use IPv6.
    case ipv6Only = "IPv6"
    /// The component should use IPv4 and IPv6.
    case ipv4And6 = "IPv4/IPv6"
    
    /// An array of titles for all cases.
    public static var titles: [String] {
        Self.allCases.map (\.rawValue)
    }
    
    /// The title for this case.
    public var title: String {
        self.rawValue
    }
    
    /// Does this IP Mode use IPv4?
    ///
    /// - Returns: Whether this case includes IPv4.
    ///
    internal func usesIPv4() -> Bool { self != .ipv6Only }
    
    /// Does this IP Mode use IPv6?
    ///
    /// - Returns: Whether this case includes IPv4.
    ///
    internal func usesIPv6() -> Bool { self != .ipv4Only }
}

/// IPv4
///
/// Contains IPv4 related constants and definitions.
///
struct IPv4 {
    /// The prefix of the multicast address used by sACN for multicast messages.
    private static var multicastMessagePrefix: String = "239.255."
    
    /// The hostname of the multicast address used by sACN for universe discovery messages.
    static var universeDiscoveryHostname: String = "239.255.250.214"
    
    /// Attempts to calculate an IPv4 hostname for a multicast message with a certain universe number.
    ///
    /// - Parameters:
    ///    - universe: The universe for which to calculate the hostname.
    ///
    /// - Returns: A multicast hostname.
    ///
    static func multicastHostname(for universe: UInt16) -> String {
        "\(Self.multicastMessagePrefix)\(universe/256).\(universe%256)"
    }
}

/// IPv6
///
/// Contains IPv6 related constants and definitions.
///
struct IPv6 {
    /// The prefix of the multicast address used by sACN for multicast messages.
    private static var multicastMessagePrefix: String = "ff18::83:00:"
    
    /// The hostname of the multicast address used by sACN for universe discovery messages.
    static var universeDiscoveryHostname: String = "ff18::83:00:fa:d6"

    /// Attempts to calculate an IPv6 hostname for a multicast message with a certain universe number.
    ///
    /// - Parameters:
    ///    - universe: The universe for which to calculate the hostname.
    ///
    /// - Returns: A multicast hostname.
    ///
    static func multicastHostname(for universe: UInt16) -> String {
        "\(Self.multicastMessagePrefix)\(String(format: "%02X", universe/256)):\(String(format: "%02X", universe%256))"
    }
}
