import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var usage: CodexUsage?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorRequiresLogin = false
    @Published private(set) var updatedAt: Date?
    @Published private(set) var notificationAuthorization = L10n.text("正在检查…")
    @Published private(set) var tokenUsage: TokenUsageSummary?
    @Published private(set) var tokenUsageError: String?
    @Published private(set) var isLoadingTokenUsage = false
    @Published private(set) var isRefreshingExchangeRate = false
    @Published private(set) var exchangeRateError: String?
    @Published private(set) var exchangeRateUpdatedAt = UserDefaults.standard.object(forKey: "exchangeRateUpdatedAt") as? Date
    @Published private(set) var exchangeRateSourceDate = UserDefaults.standard.string(forKey: "exchangeRateSourceDate")

    private let service = CodexUsageService()
    private let tokenService = TokenUsageService()
    private let exchangeRateService = ExchangeRateService()
    private let notifications = ResetNotificationService()
    private var hasLoaded = false
    @Published var authPath = UserDefaults.standard.string(forKey: "authPath") ?? "~/.codex/auth.json" {
        didSet {
            UserDefaults.standard.set(authPath, forKey: "authPath")
            usage = nil
            updatedAt = nil
            errorMessage = nil
            errorRequiresLogin = false
        }
    }
    @Published var refreshMinutes = UserDefaults.standard.integer(forKey: "refreshMinutes") == 0 ? 5 : UserDefaults.standard.integer(forKey: "refreshMinutes") {
        didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes"); scheduleRefresh() }
    }
    @Published var showFiveHourInMenuBar = UsageStore.initialMenuBarSelection().fiveHour {
        didSet { UserDefaults.standard.set(showFiveHourInMenuBar, forKey: "showFiveHourInMenuBar") }
    }
    @Published var showWeeklyInMenuBar = UsageStore.initialMenuBarSelection().weekly {
        didSet { UserDefaults.standard.set(showWeeklyInMenuBar, forKey: "showWeeklyInMenuBar") }
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
    @Published var tokenUsagePeriod = TokenUsagePeriod(rawValue: UserDefaults.standard.string(forKey: "tokenUsagePeriod") ?? "") ?? .sevenDays {
        didSet {
            UserDefaults.standard.set(tokenUsagePeriod.rawValue, forKey: "tokenUsagePeriod")
            Task { await refreshTokenUsage() }
        }
    }
    @Published var usdToCNY = UserDefaults.standard.object(forKey: "usdToCNY") as? Double ?? 6.71 {
        didSet {
            let clamped = min(20, max(0.1, usdToCNY))
            if clamped != usdToCNY {
                usdToCNY = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: "usdToCNY")
        }
    }
    @Published var costDisplayCurrency = UsageStore.initialCostDisplayCurrency() {
        didSet { UserDefaults.standard.set(costDisplayCurrency.rawValue, forKey: "costDisplayCurrency") }
    }
    private var timer: Timer?
    private var exchangeRateTimer: Timer?
    private var lastFiveHourNotificationAt: Date? {
        get { UserDefaults.standard.object(forKey: "lastFiveHourResetNotificationAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastFiveHourResetNotificationAt") }
    }
    private var weeklyNotificationArmed: Bool {
        get { UserDefaults.standard.object(forKey: "weeklyResetNotificationArmed") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "weeklyResetNotificationArmed") }
    }

    func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(refreshMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    var menuBarTitle: String {
        Self.menuBarTitle(
            usage: usage,
            showFiveHour: showFiveHourInMenuBar,
            showWeekly: showWeeklyInMenuBar
        )
    }

    static func menuBarTitle(
        usage: CodexUsage?,
        showFiveHour: Bool,
        showWeekly: Bool
    ) -> String {
        var components: [String] = []
        if showFiveHour, let percent = usage?.fiveHour.remainingPercent {
            components.append(L10n.format("%d%%", Int(percent.rounded())))
        }
        if showWeekly, let percent = usage?.weekly.remainingPercent {
            components.append(L10n.format("W %d%%", Int(percent.rounded())))
        }
        return components.isEmpty ? "Codex" : components.joined(separator: " · ")
    }

    private static func initialMenuBarSelection() -> (fiveHour: Bool, weekly: Bool) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "showFiveHourInMenuBar") != nil ||
            defaults.object(forKey: "showWeeklyInMenuBar") != nil {
            let fiveHour = defaults.bool(forKey: "showFiveHourInMenuBar")
            let weekly = defaults.bool(forKey: "showWeeklyInMenuBar")
            return (fiveHour || !weekly, weekly)
        }

        let legacy = MenuBarQuotaWindow(
            rawValue: defaults.string(forKey: "menuBarQuotaWindow") ?? ""
        ) ?? .fiveHour
        return (legacy == .fiveHour, legacy == .weekly)
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        if notifyFiveHourReset || notifyWeeklyReset {
            await notifications.requestAuthorization()
        }
        notificationAuthorization = await notifications.authorizationDescription()
        scheduleExchangeRateRefresh()
        await refreshExchangeRateIfNeeded()
        await refresh()
    }

    private static func initialCostDisplayCurrency() -> CostDisplayCurrency {
        let defaults = UserDefaults.standard
        return defaultCostDisplayCurrency(
            savedValue: defaults.string(forKey: "costDisplayCurrency"),
            preferredLanguage: Locale.preferredLanguages.first ?? ""
        )
    }

    static func defaultCostDisplayCurrency(
        savedValue: String?,
        preferredLanguage: String
    ) -> CostDisplayCurrency {
        if let savedValue, let currency = CostDisplayCurrency(rawValue: savedValue) {
            return currency
        }
        return preferredLanguage.lowercased().hasPrefix("en") ? .usd : .cny
    }

    func formattedCost(usd: Double) -> String {
        let amount = costDisplayCurrency == .usd ? usd : usd * usdToCNY
        return amount.formatted(.currency(code: costDisplayCurrency.currencyCode).precision(.fractionLength(2)))
    }

    func refreshExchangeRate() async {
        guard !isRefreshingExchangeRate else { return }
        isRefreshingExchangeRate = true
        defer { isRefreshingExchangeRate = false }
        do {
            let result = try await exchangeRateService.fetchUSDtoCNY()
            usdToCNY = result.rate
            exchangeRateUpdatedAt = Date()
            exchangeRateSourceDate = result.sourceDate
            exchangeRateError = nil
            UserDefaults.standard.set(exchangeRateUpdatedAt, forKey: "exchangeRateUpdatedAt")
            UserDefaults.standard.set(exchangeRateSourceDate, forKey: "exchangeRateSourceDate")
        } catch {
            exchangeRateError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        scheduleExchangeRateRefresh()
    }

    private func refreshExchangeRateIfNeeded(now: Date = Date()) async {
        let calendar = Calendar.current
        let todayAtEight = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now
        guard now >= todayAtEight,
              exchangeRateUpdatedAt == nil || exchangeRateUpdatedAt! < todayAtEight else { return }
        await refreshExchangeRate()
    }

    private func scheduleExchangeRateRefresh(now: Date = Date()) {
        exchangeRateTimer?.invalidate()
        let next = Self.nextExchangeRateRefresh(after: now)
        exchangeRateTimer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refreshExchangeRate() }
        }
    }

    static func nextExchangeRateRefresh(
        after now: Date,
        calendar: Calendar = .current
    ) -> Date {
        let todayAtEight = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now
        if now < todayAtEight { return todayAtEight }
        return calendar.date(byAdding: .day, value: 1, to: todayAtEight)
            ?? now.addingTimeInterval(86_400)
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
        async let tokenRefresh: Void = refreshTokenUsage()
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
            errorRequiresLogin = false
            if let previous {
                await notifyForResets(previous: previous, current: result)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let usageError = error as? CodexUsageError {
                switch usageError {
                case .missingAuthentication, .expiredAuthentication:
                    errorRequiresLogin = true
                default:
                    errorRequiresLogin = false
                }
            } else {
                errorRequiresLogin = false
            }
        }
        await tokenRefresh
    }

    func refreshTokenUsage() async {
        guard !isLoadingTokenUsage else { return }
        isLoadingTokenUsage = true
        let requestedPeriod = tokenUsagePeriod
        let result = await tokenService.scan(period: requestedPeriod)
        guard requestedPeriod == tokenUsagePeriod else {
            isLoadingTokenUsage = false
            return
        }
        tokenUsage = result
        tokenUsageError = nil
        isLoadingTokenUsage = false
    }

    private func notifyForResets(previous: CodexUsage, current: CodexUsage) async {
        let now = Date()
        if let oldRemaining = previous.weekly.remainingPercent,
           let newRemaining = current.weekly.remainingPercent,
           newRemaining < oldRemaining {
            weeklyNotificationArmed = true
        }

        if notifyFiveHourReset,
           UsageResetNotificationPolicy.shouldNotify(
                previous: previous.fiveHour,
                current: current.fiveHour,
                period: .fiveHour,
                lastNotifiedAt: lastFiveHourNotificationAt,
                now: now
           ),
           let remaining = current.fiveHour.remainingPercent {
            if await notifications.send(period: L10n.text("5 小时"), remainingPercent: remaining) {
                lastFiveHourNotificationAt = now
            }
        }

        if notifyWeeklyReset,
           UsageResetNotificationPolicy.shouldNotify(
                previous: previous.weekly,
                current: current.weekly,
                period: .weekly,
                isArmed: weeklyNotificationArmed,
                lastNotifiedAt: nil,
                now: now
           ),
           let remaining = current.weekly.remainingPercent {
            if await notifications.send(period: L10n.text("每周"), remainingPercent: remaining) {
                weeklyNotificationArmed = false
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
        store.tokenUsage = TokenUsageSummary(
            period: .sevenDays,
            counts: TokenCounts(input: 1_840_000, cachedInput: 1_250_000, output: 126_000, reasoningOutput: 44_000),
            estimatedUSD: 3.82,
            unpricedTokens: 0,
            sessions: 18,
            models: [
                ModelTokenUsage(model: "gpt-5.6-terra", counts: TokenCounts(input: 1_300_000, cachedInput: 900_000, output: 91_000, reasoningOutput: 31_000), estimatedUSD: 2.07),
                ModelTokenUsage(model: "gpt-5.6-sol", counts: TokenCounts(input: 540_000, cachedInput: 350_000, output: 35_000, reasoningOutput: 13_000), estimatedUSD: 1.75)
            ],
            updatedAt: Date()
        )
        store.hasLoaded = true
        return store
    }
}
