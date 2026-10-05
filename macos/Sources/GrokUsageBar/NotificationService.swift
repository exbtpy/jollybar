import Foundation
@preconcurrency import UserNotifications

struct ThresholdAlert: Equatable {
    let window: String
    let pct: Int
}

/// Fires when the weekly pool percent crosses `threshold` from below.
/// `previous` and `current` are percentages in the 0...100 range, not fractions.
func crossedWeeklyThreshold(
    threshold: Int,
    previous: Double,
    current: Double
) -> ThresholdAlert? {
    guard threshold > 0 else { return nil }
    let limit = Double(threshold)
    guard current >= limit, previous < limit else { return nil }
    return ThresholdAlert(window: "Weekly", pct: Int(round(current)))
}

private class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
class NotificationService: ObservableObject {
    /// 0 = off, 5–100 = alert when the weekly pool reaches this %.
    @Published private(set) var thresholdWeekly: Int

    private var previousPercent: Double?
    private let delegate = NotificationDelegate()

    /// False when this process cannot use notifications at all, so callers can
    /// say so instead of silently doing nothing.
    let isAvailable = supportsUserNotifications()

    init() {
        thresholdWeekly = Self.load("notificationThresholdWeekly")
        if isAvailable {
            UNUserNotificationCenter.current().delegate = delegate
        }
    }

    func setThresholdWeekly(_ value: Int) {
        thresholdWeekly = clamp(value)
        UserDefaults.standard.set(thresholdWeekly, forKey: "notificationThresholdWeekly")
        previousPercent = nil
        if thresholdWeekly > 0 { requestPermission() }
    }

    func requestPermission() {
        guard isAvailable else {
            print("[Notification] Permission not requested — no app bundle")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `weeklyFraction` is 0...1, matching the value stored in history.
    func checkAndNotify(weeklyFraction: Double) {
        let current = weeklyFraction * 100
        let previous = previousPercent ?? 0
        defer { previousPercent = current }

        guard let alert = crossedWeeklyThreshold(
            threshold: thresholdWeekly,
            previous: previous,
            current: current
        ) else {
            return
        }
        sendNotification(window: alert.window, pct: alert.pct)
    }

    private func sendNotification(window: String, pct: Int) {
        guard isAvailable else {
            print("[Notification] \(window) usage has reached \(pct)% (no bundle – skipped)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Grok Usage"
        content.body = "\(window) usage has reached \(pct)%"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage-\(window)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Notification] Failed to deliver: \(error)")
            } else {
                print("[Notification] Delivered: \(window) at \(pct)%")
            }
        }
    }

    private func clamp(_ value: Int) -> Int {
        max(0, min(100, value))
    }

    private static func load(_ key: String) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return max(0, min(100, value))
    }
}

/// Shown wherever notification controls are offered but cannot work. Only
/// reachable in development — a packaged build always declares APPL.
let notificationsUnavailableMessage =
    "Notifications require a packaged application build — run `make app` and launch the bundle."

/// Whether this process can use `UNUserNotificationCenter` at all.
///
/// `UNUserNotificationCenter.current()` aborts the process rather than
/// returning nil when it is unhappy, and Apple exposes no availability check,
/// so this is a deliberately conservative heuristic rather than a documented
/// test. The precise precondition it enforces is not public — a nil
/// `LSBundleProxy` alone does not trigger the abort — so this errs toward the
/// configurations known to work.
///
/// `CFBundlePackageType` is the key that declares a bundle's type.
/// `object(forInfoDictionaryKey:)` reads it strictly — a `.app` that omits the
/// key returns nil rather than falling back to the path extension — so this
/// depends on nothing but the declaration itself. That gets renamed, symlinked
/// and oddly-cased bundles right, and excludes app extensions (which declare
/// `XPC!`) for free. Under `swift test` and `swift run` there is no such key,
/// which is exactly the case that used to abort.
func supportsUserNotifications(bundle: Bundle = .main) -> Bool {
    bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
}
