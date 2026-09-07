import Foundation

struct UsageWindow: Sendable {
    let usedPercent: Double?
    let resetAt: Date?

    static let unavailable = UsageWindow(usedPercent: nil, resetAt: nil)
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
