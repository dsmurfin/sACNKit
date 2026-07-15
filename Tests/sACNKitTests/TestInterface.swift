import Foundation

/// Platform-appropriate interface names for tests that bind or resolve interfaces.
///
/// The loopback interface is named `lo0` on Darwin and `lo` on Linux; tests that
/// name it explicitly must pick the right one for the host they run on.
enum TestInterface {

    /// The loopback interface name for the current platform.
    static var loopback: String {
        #if os(Linux)
        "lo"
        #else
        "lo0"
        #endif
    }

}
