import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var usage: CodexUsage?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var notificationAuthorization = "正在检查…"

    private let service = CodexUsageService()
    private let notifications = ResetNotificationService()
    private var hasLoaded = false
    @Published var authPath = UserDefaults.standard.string(forKey: "authPath") ?? "~/.codex/auth.json" {
        didSet {
            UserDefaults.standard.set(authPath, forKey: "authPath")
            usage = nil
            updatedAt = nil
            errorMessage = nil
        }
    }
    @Published var refreshMinutes = UserDefaults.standard.integer(forKey: "refreshMinutes") == 0 ? 5 : UserDefaults.standard.integer(forKey: "refreshMinutes") {
        didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes"); scheduleRefresh() }
    }
    @Published var notifyFiveHourReset = UserDefaults.standard.bool(forKey: "notifyFiveHourReset") {
        didSet {
            UserDefaults.standard.set(notifyFiveHourReset, forKey: "notifyFiveHourReset")
            Task { await updateNotificationAuthorization(requestIfNeeded: notifyFiveHourReset) }
        }
    }
    @Published var notifyWeeklyReset = UserDefaults.standard.object(forKey: "notifyWeeklyReset") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notifyWeeklyReset, forKey: "notifyWeeklyReset")
            Task { await updateNotificationAuthorization(requestIfNeeded: notifyWeeklyReset) }
        }
    }
    private var timer: Timer?
    private var lastFiveHourNotificationAt: Date? {
        get { UserDefaults.standard.object(forKey: "lastFiveHourResetNotificationAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastFiveHourResetNotificationAt") }
    }
    private var lastWeeklyNotificationAt: Date? {
        get { UserDefaults.standard.object(forKey: "lastWeeklyResetNotificationAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastWeeklyResetNotificationAt") }
    }

    func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(refreshMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    var menuBarTitle: String {
        guard let percent = usage?.fiveHour.remainingPercent ?? usage?.weekly.remainingPercent else { return "Codex" }
        return "\(Int(percent.rounded()))%"
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        if notifyFiveHourReset || notifyWeeklyReset {
            await notifications.requestAuthorization()
        }
        notificationAuthorization = await notifications.authorizationDescription()
        await refresh()
    }

    func sendTestNotification() async {
        await notifications.sendTest()
        notificationAuthorization = await notifications.authorizationDescription()
    }

    private func updateNotificationAuthorization(requestIfNeeded: Bool) async {
        if requestIfNeeded { await notifications.requestAuthorization() }
        notificationAuthorization = await notifications.authorizationDescription()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let requestedPath = authPath
            let result = try await service.fetch(authPath: requestedPath)
            guard requestedPath == authPath else { return }
            let previous = usage
            usage = result
            updatedAt = Date()
            errorMessage = nil
            if let previous {
                await notifyForResets(previous: previous, current: result)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func notifyForResets(previous: CodexUsage, current: CodexUsage) async {
        let now = Date()
        if notifyFiveHourReset,
           UsageResetNotificationPolicy.shouldNotify(
                previous: previous.fiveHour,
                current: current.fiveHour,
                period: .fiveHour,
                lastNotifiedAt: lastFiveHourNotificationAt,
                now: now
           ),
           let remaining = current.fiveHour.remainingPercent {
            if await notifications.send(period: "5 小时", remainingPercent: remaining) {
                lastFiveHourNotificationAt = now
            }
        }

        if notifyWeeklyReset,
           UsageResetNotificationPolicy.shouldNotify(
                previous: previous.weekly,
                current: current.weekly,
                period: .weekly,
                lastNotifiedAt: lastWeeklyNotificationAt,
                now: now
           ),
           let remaining = current.weekly.remainingPercent {
            if await notifications.send(period: "每周", remainingPercent: remaining) {
                lastWeeklyNotificationAt = now
            }
        }
    }

    static var preview: UsageStore {
        let store = UsageStore()
        store.usage = CodexUsage(
            fiveHour: UsageWindow(usedPercent: 38, resetAt: Date().addingTimeInterval(7_200)),
            weekly: UsageWindow(usedPercent: 61, resetAt: Date().addingTimeInterval(172_800)),
            plan: "plus"
        )
        store.updatedAt = Date()
        store.hasLoaded = true
        return store
    }
}
