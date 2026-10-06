import SwiftUI
import ServiceManagement

struct SettingsWindowContent: View {
    @ObservedObject var service: UsageService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var appUpdater: AppUpdater
    @State private var teamID = ""
    @State private var managementKey = ""
    @State private var cursorKey = ""
    @State private var cursorEmail = ""
    @State private var cursorOrganizationID = ""
    @State private var cursorBudget = ""
    @AppStorage(MenuTheme.defaultsKey) private var menuThemeRaw = MenuTheme.classic.rawValue

    var body: some View {
        Form {
            Section("General") {
                LaunchAtLoginToggle()

                Picker("Menu bar", selection: Binding(
                    get: { menuThemeRaw },
                    set: { menuThemeRaw = $0 }
                )) {
                    Text("Classic").tag(MenuTheme.classic.rawValue)
                    Text("Companion").tag(MenuTheme.companion.rawValue)
                }
                Text("Classic keeps the two bars and a chart glyph. Companion adds a pet that follows Grok Bot weekly usage. The pet animation runs only while the menu is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Polling Interval", selection: Binding(
                    get: { service.pollingMinutes },
                    set: { service.updatePollingInterval($0) }
                )) {
                    ForEach(UsageService.pollingOptions, id: \.self) { mins in
                        Text(pollingOptionLabel(for: mins))
                            .tag(mins)
                    }
                }
            }

            Section("Notifications") {
                if !notificationService.isAvailable {
                    Text(notificationsUnavailableMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ThresholdSlider(
                    label: "Grok Bot",
                    value: notificationService.thresholdBot,
                    onChange: { notificationService.setThresholdBot($0) }
                )
                ThresholdSlider(
                    label: "Weekly pool",
                    value: notificationService.thresholdWeekly,
                    onChange: { notificationService.setThresholdWeekly($0) }
                )
            }
            .disabled(!notificationService.isAvailable)

            Section("Grok Bot (Cursor)") {
                Text("Grok Bot weekly usage is read from the Grok Bot app on this Mac. The access token stays in Grok Bot’s files. This app does not read the refresh token and does not sign you in again. If the session expires, open Grok Bot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Optional fallback for Teams and Enterprise: a Cursor API key reads Grok Bot spend when Grok Bot is not signed in on this Mac. It is stored in the Keychain. That source is polled at most once an hour and is labeled spend, not the weekly meter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField(service.cursorConfigured ? "Cursor API key (saved)" : "Cursor API key", text: $cursorKey)
                TextField("Member email (optional)", text: $cursorEmail)
                TextField("Monthly budget in USD (optional)", text: $cursorBudget)
                TextField("Organization id (optional)", text: $cursorOrganizationID)
                Text("Leave the organization id blank to use the team spend API. The percent uses your per-user spend limit when the email matches a member. Otherwise it uses the monthly budget. The organization pool limit is not used as this bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Save") {
                        service.saveCursorSettings(
                            apiKey: cursorKey,
                            email: cursorEmail,
                            organizationID: cursorOrganizationID,
                            budget: cursorBudget
                        )
                        cursorKey = ""
                        if service.cursorConfigured && service.cursorError == nil {
                            Task { await service.fetchUsage(refreshCursor: true) }
                        }
                    }
                    Button("Remove") {
                        service.clearCursorSettings()
                        cursorKey = ""
                        cursorEmail = ""
                        cursorOrganizationID = ""
                        cursorBudget = ""
                    }
                }
                if service.cursorConfigured {
                    Text("A Cursor API key is saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = service.cursorError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Grok CLI session") {
                Text("Usage comes from the grok CLI login in ~/.grok/auth.json. This app does not collect a password or start its own sign-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let email = service.accountEmail {
                    LabeledContent("Account") {
                        Text(email)
                            .textSelection(.enabled)
                    }
                }
                Text("To sign in or switch accounts, run grok login in Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Developer API") {
                Text("Optional. A management key and team ID read console prepaid balance and recent API spend. They do not replace the weekly pool. The key is stored in the Keychain and is not written to the config file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Team ID", text: $teamID)
                SecureField(service.managementConfigured ? "Management key (saved)" : "Management key", text: $managementKey)
                HStack {
                    Button("Save") {
                        service.saveManagementSettings(teamID: teamID, key: managementKey)
                        managementKey = ""
                    }
                    Button("Remove") {
                        service.clearManagementSettings()
                        teamID = ""
                        managementKey = ""
                    }
                }
                if service.managementConfigured {
                    Text("A management key is saved for this team.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = service.managementError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Updates") {
                LabeledContent("Version") {
                    Text(Self.appVersion)
                        .textSelection(.enabled)
                }

                if appUpdater.isConfigured {
                    Toggle("Check daily for updates", isOn: $appUpdater.automaticallyChecksForUpdates)

                    Button("Check for Updates…") {
                        appUpdater.checkForUpdates()
                    }
                    .disabled(!appUpdater.canCheckForUpdates)

                    if let error = appUpdater.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("This build has no update feed, so it cannot check for updates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            teamID = service.managementTeamID
            cursorEmail = service.cursorMemberEmail
            cursorOrganizationID = service.cursorOrganizationID
            if let budget = service.cursorBudgetDollars, budget > 0 {
                cursorBudget = String(budget)
            }
            focusSettingsWindow()
        }
    }
}

extension SettingsWindowContent {
    static var appVersion: String {
        displayVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    /// `CFBundleVersion` is derived from the version string by build.sh
    /// (0.0.10 -> 10), so appending it would only restate the number beside it.
    /// The marketing version stands alone.
    static func displayVersion(_ shortVersion: String?) -> String {
        let trimmed = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "unknown" }
        return trimmed
    }
}

@MainActor
private func focusSettingsWindow() {
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.last(where: { $0.isVisible && $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

struct LaunchAtLoginToggle: View {
    @StateObject private var model: LaunchAtLoginModel
    private let controlSize: ControlSize?
    private let useSwitchStyle: Bool

    init(
        controlSize: ControlSize? = nil,
        useSwitchStyle: Bool = false,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        _model = StateObject(
            wrappedValue: LaunchAtLoginModel(bundleURL: bundleURL)
        )
        self.controlSize = controlSize
        self.useSwitchStyle = useSwitchStyle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            toggle

            if let message = model.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var toggle: some View {
        let baseToggle = Toggle("Launch at Login", isOn: Binding(
            get: { model.isEnabled },
            set: { model.setEnabled($0) }
        ))
        .disabled(!model.isSupported)

        let sized = baseToggle.modifier(OptionalControlSize(controlSize: controlSize))

        if useSwitchStyle {
            sized.toggleStyle(.switch)
        } else {
            sized
        }
    }
}

private struct OptionalControlSize: ViewModifier {
    let controlSize: ControlSize?

    func body(content: Content) -> some View {
        if let controlSize {
            content.controlSize(controlSize)
        } else {
            content
        }
    }
}

@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isSupported: Bool
    @Published private(set) var message: String?

    init(bundleURL: URL = Bundle.main.bundleURL) {
        isSupported = supportsLaunchAtLoginManagement(appURL: bundleURL)

        guard isSupported else {
            message = "Install the app in Applications to manage launch at login."
            return
        }

        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        guard isSupported else { return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = enabled
            message = nil
        } catch {
            isEnabled = SMAppService.mainApp.status == .enabled
            message = "Could not update launch at login."
        }
    }
}

func supportsLaunchAtLoginManagement(
    appURL: URL = Bundle.main.bundleURL,
    installDirectories: [URL] = launchAtLoginInstallDirectories()
) -> Bool {
    let normalizedAppURL = appURL.resolvingSymlinksInPath().standardizedFileURL

    return installDirectories.contains { directory in
        let normalizedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let directoryPath = normalizedDirectory.path
        let appPath = normalizedAppURL.path

        return appPath == directoryPath || appPath.hasPrefix(directoryPath + "/")
    }
}

func launchAtLoginInstallDirectories(fileManager: FileManager = .default) -> [URL] {
    [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        fileManager.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
    ]
}

private struct ThresholdSlider: View {
    let label: String
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        LabeledContent {
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(Int($0)) }
                ),
                in: 0...100,
                step: 5
            )
        } label: {
            Text(label)
            Text(value > 0 ? "\(value)%" : "Off")
                .foregroundStyle(.secondary)
        }
        .alignmentGuide(.firstTextBaseline) { d in
            d[VerticalAlignment.center]
        }
    }
}
