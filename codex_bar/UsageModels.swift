import Foundation

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

    var errorDescription: String? {
        switch self {
        case .missingAuthentication: return "没有找到 Codex 登录信息。"
        case .expiredAuthentication: return "Codex 登录已过期。"
        case .server(let status): return "额度服务返回 HTTP \(status)。"
        case .invalidResponse: return "额度数据格式暂时无法识别。"
        }
    }
}
