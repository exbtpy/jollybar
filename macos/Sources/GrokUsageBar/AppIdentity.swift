import Foundation

/// Names that move together when the app is renamed.
///
/// Keep these equal to `macos/identity.env`. `AppIdentityTests` fails when
/// they drift. The packaged bundle id, display name, and executable name are
/// stamped from that file by `macos/scripts/build.sh`.
enum AppIdentity {
    static let productName = "GrokUsageBar"
    static let executableName = "GrokUsageBar"
    static let displayName = "Grok Usage Bar"
    /// Short title already used in the menu and in notifications.
    static let menuTitle = "Grok Usage"
    static let bundleIdentifier = "com.exbtpy.GrokUsageBar"
    /// Directory under `~/.config`, and the string sent as `x-grok-client-version`.
    static let configDirectoryName = "grok-usage-bar"
    static let diskImageName = "GrokUsageBar"
}
