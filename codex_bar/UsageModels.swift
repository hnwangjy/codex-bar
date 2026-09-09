import Foundation

enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}

enum MenuBarQuotaWindow: String, CaseIterable, Identifiable {
    case fiveHour
    case weekly

    var id: Self { self }

    var title: String {
        switch self {
        case .fiveHour: return L10n.text("5 小时额度")
        case .weekly: return L10n.text("每周额度")
        }
    }
}

struct UsageWindow: Sendable {
    let usedPercent: Double?
    let resetAt: Date?

    static let unavailable = UsageWindow(usedPercent: nil, resetAt: nil)

    var remainingPercent: Double? {
        usedPercent.map { min(100, max(0, 100 - $0)) }
    }
}

enum UsageResetDetector {
    static let minimumJump = 20.0

    static func didReset(previous: UsageWindow, current: UsageWindow, at now: Date = Date()) -> Bool {
        guard let oldRemaining = previous.remainingPercent,
              let newRemaining = current.remainingPercent,
              newRemaining > oldRemaining else { return false }

        let crossedResetBoundary: Bool
        if let oldReset = previous.resetAt, let newReset = current.resetAt {
            crossedResetBoundary = oldReset <= now && newReset.timeIntervalSince(oldReset) > 60
        } else {
            crossedResetBoundary = false
        }

        return crossedResetBoundary || newRemaining - oldRemaining >= minimumJump
    }
}

enum UsageResetPeriod {
    case fiveHour
    case weekly

    var notificationCooldown: TimeInterval? {
        switch self {
        case .fiveHour: return 4 * 60 * 60
        case .weekly: return nil
        }
    }
}

enum UsageResetNotificationPolicy {
    static func shouldNotify(
        previous: UsageWindow,
        current: UsageWindow,
        period: UsageResetPeriod,
        isArmed: Bool = true,
        lastNotifiedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard isArmed else { return false }
        guard UsageResetDetector.didReset(previous: previous, current: current, at: now) else {
            return false
        }
        guard let cooldown = period.notificationCooldown,
              let lastNotifiedAt else { return true }
        return now.timeIntervalSince(lastNotifiedAt) >= cooldown
    }
}

struct CodexUsage: Sendable {
    let fiveHour: UsageWindow
    let weekly: UsageWindow
    let plan: String?

    var planDisplayName: String {
        guard let plan, !plan.isEmpty else { return "ChatGPT" }
        return "ChatGPT \(plan.capitalized)"
    }
}

enum CodexUsageError: LocalizedError {
    case missingAuthentication
    case expiredAuthentication
    case server(Int)
    case invalidResponse
    case proxyTLSFailure(String)
    case secureConnectionFailed
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAuthentication: return L10n.text("没有找到 Codex 登录信息。")
        case .expiredAuthentication: return L10n.text("Codex 登录已过期。")
        case .server(let status): return L10n.format("额度服务返回 HTTP %d。", status)
        case .invalidResponse: return L10n.text("额度数据格式暂时无法识别。")
        case .proxyTLSFailure(let proxy):
            return L10n.format("本地代理 %@ 无法与 ChatGPT 建立安全连接，请切换代理节点后重试。", proxy)
        case .secureConnectionFailed:
            return L10n.text("无法与 ChatGPT 建立安全连接，请检查网络、代理和系统时间。")
        case .networkUnavailable:
            return L10n.text("当前网络不可用，恢复连接后会自动刷新。")
        }
    }
}
