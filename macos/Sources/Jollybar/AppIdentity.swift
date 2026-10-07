import Foundation

/// Names that move together when the app is renamed.
///
/// Keep these equal to `macos/identity.env`. `AppIdentityTests` fails when
/// they drift. The packaged bundle id, display name, and executable name are
/// stamped from that file by `macos/scripts/build.sh`.
enum AppIdentity {
    static let productName = "Jollybar"
    static let executableName = "Jollybar"
    static let displayName = "Jollybar"
    /// Short title used in the menu and in notifications.
    static let menuTitle = "Jollybar"
    static let bundleIdentifier = "com.exbtpy.Jollybar"
    /// Directory under `~/.config`, the Homebrew cask token, and the string
    /// sent as `x-grok-client-version`.
    static let configDirectoryName = "jollybar"
    static let diskImageName = "Jollybar"
    /// Companion pet. The menu-bar theme value stored in preferences stays
    /// `companion` so an existing choice still applies.
    static let companionName = "Bud"
}
