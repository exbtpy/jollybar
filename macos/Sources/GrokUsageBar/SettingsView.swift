import SwiftUI
import ServiceManagement

struct SettingsWindowContent: View {
    @ObservedObject var service: UsageService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var appUpdater: AppUpdater
    @State private var teamID = ""
    @State private var managementKey = ""

    var body: some View {
        Form {
            Section("General") {
                LaunchAtLoginToggle()

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
                    label: "Weekly pool",
                    value: notificationService.thresholdWeekly,
                    onChange: { notificationService.setThresholdWeekly($0) }
                )
            }
            .disabled(!notificationService.isAvailable)

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
