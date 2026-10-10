import SwiftUI
import ServiceManagement

/// Sizes the Settings window so it fits the visible screen and can still be resized.
enum SettingsLayout {
    static let windowWidth: CGFloat = 440
    static let minimumWindowWidth: CGFloat = 420
    static let maximumWindowWidth: CGFloat = 560
    /// Comfortable height on a tall display. Shorter screens use a smaller ideal.
    static let preferredContentHeight: CGFloat = 640
    static let minimumContentHeight: CGFloat = 320
    /// Title bar, plus a gap so the window does not sit flush against the Dock.
    /// `NSScreen.visibleFrame` already excludes the menu bar and Dock.
    static let titleBarAllowance: CGFloat = 48
    /// About the visible frame of a scaled 13-inch MacBook Air.
    static let fallbackVisibleHeight: CGFloat = 800

    struct ContentHeights: Equatable {
        let minimum: CGFloat
        let ideal: CGFloat
        let maximum: CGFloat
    }

    struct ContentSize: Equatable {
        let width: CGFloat
        let height: CGFloat
    }

    /// Content-area heights that stay inside `visibleHeight`, including the title bar.
    static func contentHeights(visibleHeight: CGFloat) -> ContentHeights {
        let screen = visibleHeight.isFinite ? visibleHeight : fallbackVisibleHeight
        let maximum = max(screen - titleBarAllowance, 1)
        let ideal = min(preferredContentHeight, maximum)
        let minimum = min(minimumContentHeight, ideal)
        return ContentHeights(minimum: minimum, ideal: ideal, maximum: maximum)
    }

    static var currentVisibleHeight: CGFloat {
        let height = NSScreen.main?.visibleFrame.height ?? 0
        return height > 1 ? height : fallbackVisibleHeight
    }

    static var openingContentHeight: CGFloat {
        contentHeights(visibleHeight: currentVisibleHeight).ideal
    }

    /// Keeps a size the user chose inside the visible frame. Sizes outside that
    /// frame snap back to the opening size.
    static func clampedContentSize(
        currentWidth: CGFloat,
        currentHeight: CGFloat,
        visibleHeight: CGFloat
    ) -> ContentSize {
        let heights = contentHeights(visibleHeight: visibleHeight)
        let width: CGFloat
        if currentWidth < minimumWindowWidth || currentWidth > maximumWindowWidth {
            width = windowWidth
        } else {
            width = currentWidth
        }
        let height: CGFloat
        if currentHeight < heights.minimum || currentHeight > heights.maximum {
            height = heights.ideal
        } else {
            height = currentHeight
        }
        return ContentSize(width: width, height: height)
    }

    /// Open the Teams and Enterprise fields when a key is already saved or the
    /// last attempt failed, so Save and Remove stay reachable.
    static func expandsAdvancedCursorSettings(configured: Bool, hasError: Bool) -> Bool {
        configured || hasError
    }
}

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
    @State private var advancedExpanded = false
    @State private var didApplyAdvancedDefault = false
    @AppStorage(MenuTheme.defaultsKey) private var menuThemeRaw = MenuTheme.defaultTheme.rawValue
    @AppStorage(UsagePercentStyle.defaultsKey) private var percentStyleRaw = UsagePercentStyle.used.rawValue

    var body: some View {
        let heights = SettingsLayout.contentHeights(visibleHeight: SettingsLayout.currentVisibleHeight)

        ScrollView(.vertical) {
            settingsForm
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollContentBackground(.hidden)
        .frame(
            minWidth: SettingsLayout.minimumWindowWidth,
            idealWidth: SettingsLayout.windowWidth,
            maxWidth: SettingsLayout.maximumWindowWidth,
            minHeight: heights.minimum,
            idealHeight: heights.ideal,
            maxHeight: heights.maximum
        )
        .background(SettingsWindowClamp())
        .onAppear {
            teamID = service.managementTeamID
            cursorEmail = service.cursorMemberEmail
            cursorOrganizationID = service.cursorOrganizationID
            if let budget = service.cursorBudgetDollars, budget > 0 {
                cursorBudget = String(budget)
            }
            if !didApplyAdvancedDefault {
                advancedExpanded = SettingsLayout.expandsAdvancedCursorSettings(
                    configured: service.cursorConfigured,
                    hasError: service.cursorError != nil
                )
                didApplyAdvancedDefault = true
            }
            focusSettingsWindow()
        }
    }

    private var settingsForm: some View {
        Form {
            Section(L10n.text("settings.general", "General")) {
                LaunchAtLoginToggle()

                Picker(L10n.text("settings.polling", "Polling Interval"), selection: Binding(
                    get: { service.pollingMinutes },
                    set: { service.updatePollingInterval($0) }
                )) {
                    ForEach(UsageService.pollingOptions, id: \.self) { mins in
                        Text(pollingOptionLabel(for: mins))
                            .tag(mins)
                    }
                }
            }

            Section(L10n.text("settings.appearance", "Appearance")) {
                Picker(L10n.text("settings.menuBar", "Menu bar"), selection: Binding(
                    get: { MenuTheme.resolve(menuThemeRaw).rawValue },
                    set: { menuThemeRaw = $0 }
                )) {
                    Text(L10n.text("settings.menuPercent", "Percent")).tag(MenuTheme.percent.rawValue)
                    Text(L10n.text("settings.menuBars", "Usage bars")).tag(MenuTheme.bars.rawValue)
                    Text(L10n.text("settings.menuCompanion", "Companion")).tag(MenuTheme.companion.rawValue)
                }
                Text(L10n.text(
                    "settings.menuBarHelp",
                    "Percent shows the face and how much of the week is used. Usage bars shows the face and the two meters. Companion shows a small Bud and a tiny bar. Bud blinks and breathes, and stays still when Reduce Motion or Low Power Mode is on."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L10n.text("settings.number", "Big number"), selection: Binding(
                    get: { percentStyleRaw },
                    set: { percentStyleRaw = $0 }
                )) {
                    Text(UsagePercentStyle.used.settingsTitle).tag(UsagePercentStyle.used.rawValue)
                    Text(UsagePercentStyle.left.settingsTitle).tag(UsagePercentStyle.left.rawValue)
                }
                Text(L10n.text(
                    "settings.numberHelp",
                    "The big number shows how much of the week is used, or how much is left. The menu bar always shows used, so the color still means the same thing."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.text("settings.notifications", "Notifications")) {
                if !notificationService.isAvailable {
                    Text(notificationsUnavailableMessage())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ThresholdSlider(
                    label: L10n.text("meter.grokBot", "Grok Bot"),
                    value: notificationService.thresholdBot,
                    onChange: { notificationService.setThresholdBot($0) }
                )
                ThresholdSlider(
                    label: L10n.text("settings.weeklyPool", "Weekly pool"),
                    value: notificationService.thresholdWeekly,
                    onChange: { notificationService.setThresholdWeekly($0) }
                )
            }
            .disabled(!notificationService.isAvailable)

            Section(L10n.text("settings.grokBotSection", "Grok Bot (Cursor)")) {
                Text(L10n.text(
                    "settings.grokBotBody",
                    "Grok Bot weekly usage is read from the Grok Bot app on this Mac. The access token stays in Grok Bot’s files. This app does not read the refresh token and does not sign you in again. If the session expires, open Grok Bot."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup(isExpanded: $advancedExpanded) {
                    Text(L10n.text(
                        "settings.cursorFallback",
                        "Optional fallback for Teams and Enterprise: a Cursor API key reads Grok Bot spend when Grok Bot is not signed in on this Mac. It is stored in the Keychain. That source is polled at most once an hour and is labeled spend, not the weekly meter."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField(
                        service.cursorConfigured
                            ? L10n.text("settings.cursorKeySaved", "Cursor API key (saved)")
                            : L10n.text("settings.cursorKey", "Cursor API key"),
                        text: $cursorKey
                    )
                    TextField(L10n.text("settings.memberEmail", "Member email (optional)"), text: $cursorEmail)
                    TextField(L10n.text("settings.budget", "Monthly budget in USD (optional)"), text: $cursorBudget)
                    TextField(L10n.text("settings.orgId", "Organization id (optional)"), text: $cursorOrganizationID)
                    Text(L10n.text(
                        "settings.orgHelp",
                        "Leave the organization id blank to use the team spend API. The percent uses your per-user spend limit when the email matches a member. Otherwise it uses the monthly budget. The organization pool limit is not used as this bar."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(L10n.text("settings.save", "Save")) {
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
                        Button(L10n.text("settings.remove", "Remove")) {
                            service.clearCursorSettings()
                            cursorKey = ""
                            cursorEmail = ""
                            cursorOrganizationID = ""
                            cursorBudget = ""
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("settings.advanced", "Advanced"))
                        Text(L10n.text("settings.advancedSubtitle", "Teams and Enterprise API fallback"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if service.cursorConfigured {
                    Text(L10n.text("settings.cursorSaved", "A Cursor API key is saved."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = service.cursorError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(L10n.text("settings.cliSection", "Grok CLI session")) {
                Text(L10n.text(
                    "settings.cliBody",
                    "Usage comes from the grok CLI login in ~/.grok/auth.json. This app does not collect a password or start its own sign-in."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let email = service.accountEmail {
                    LabeledContent(L10n.text("settings.account", "Account")) {
                        Text(email)
                            .textSelection(.enabled)
                    }
                }
                Text(L10n.text("settings.cliHint", "To sign in or switch accounts, run grok login in Terminal."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section(L10n.text("settings.apiSection", "Developer API")) {
                Text(L10n.text(
                    "settings.apiBody",
                    "Optional. A management key and team ID read console prepaid balance and recent API spend. They do not replace the weekly pool. The key is stored in the Keychain and is not written to the config file."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.text("settings.teamId", "Team ID"), text: $teamID)
                SecureField(
                    service.managementConfigured
                        ? L10n.text("settings.managementKeySaved", "Management key (saved)")
                        : L10n.text("settings.managementKey", "Management key"),
                    text: $managementKey
                )
                HStack {
                    Button(L10n.text("settings.save", "Save")) {
                        service.saveManagementSettings(teamID: teamID, key: managementKey)
                        managementKey = ""
                    }
                    Button(L10n.text("settings.remove", "Remove")) {
                        service.clearManagementSettings()
                        teamID = ""
                        managementKey = ""
                    }
                }
                if service.managementConfigured {
                    Text(L10n.text("settings.managementSaved", "A management key is saved for this team."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = service.managementError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(L10n.text("settings.updates", "Updates")) {
                LabeledContent(L10n.text("settings.version", "Version")) {
                    Text(Self.appVersion)
                        .textSelection(.enabled)
                }

                if appUpdater.isConfigured {
                    Toggle(L10n.text("settings.checkDaily", "Check daily for updates"), isOn: $appUpdater.automaticallyChecksForUpdates)

                    Button(L10n.text("settings.checkNow", "Check for Updates…")) {
                        appUpdater.checkForUpdates()
                    }
                    .disabled(!appUpdater.canCheckForUpdates)

                    if let error = appUpdater.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text(L10n.text(
                        "settings.noFeed",
                        "This build has no update feed, so it cannot check for updates."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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

private struct SettingsWindowClamp: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.observeScreenChanges(of: window)
            Self.apply(to: window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private var screenObserver: NSObjectProtocol?

        func observeScreenChanges(of window: NSWindow) {
            guard screenObserver == nil else { return }
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                SettingsWindowClamp.apply(to: window)
            }
        }

        func stop() {
            if let screenObserver {
                NotificationCenter.default.removeObserver(screenObserver)
                self.screenObserver = nil
            }
        }
    }

    static func apply(to window: NSWindow) {
        let visible = window.screen?.visibleFrame.height ?? SettingsLayout.currentVisibleHeight
        let heights = SettingsLayout.contentHeights(visibleHeight: visible)
        let contentMin = NSSize(width: SettingsLayout.minimumWindowWidth, height: heights.minimum)
        let contentMax = NSSize(width: SettingsLayout.maximumWindowWidth, height: heights.maximum)
        window.contentMinSize = contentMin
        window.contentMaxSize = contentMax

        let contentRect = window.contentRect(forFrameRect: window.frame)
        let chromeHeight = max(0, window.frame.height - contentRect.height)
        window.minSize = NSSize(width: contentMin.width, height: contentMin.height + chromeHeight)
        window.maxSize = NSSize(width: contentMax.width, height: contentMax.height + chromeHeight)
        window.styleMask.insert(.resizable)

        let fitted = SettingsLayout.clampedContentSize(
            currentWidth: contentRect.width,
            currentHeight: contentRect.height,
            visibleHeight: visible
        )
        if abs(fitted.width - contentRect.width) > 0.5 || abs(fitted.height - contentRect.height) > 0.5 {
            window.setContentSize(NSSize(width: fitted.width, height: fitted.height))
        }
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
        let baseToggle = Toggle(L10n.text("settings.launch", "Launch at Login"), isOn: Binding(
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
            message = L10n.text(
                "settings.launchInstall",
                "Install the app in Applications to manage launch at login."
            )
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
            message = L10n.text("settings.launchFailed", "Could not update launch at login.")
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
            Text(value > 0 ? "\(value)%" : L10n.text("settings.off", "Off"))
                .foregroundStyle(.secondary)
        }
        .alignmentGuide(.firstTextBaseline) { d in
            d[VerticalAlignment.center]
        }
    }
}
