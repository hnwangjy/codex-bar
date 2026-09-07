import Foundation

struct CodexUsageService {
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch(authPath: String) async throws -> CodexUsage {
        guard let token = try readAccessToken(path: authPath) else {
            throw CodexUsageError.missingAuthentication
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw CodexUsageError.expiredAuthentication }
        guard status == 200 else { throw CodexUsageError.server(status) }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any] else {
            throw CodexUsageError.invalidResponse
        }

        let routed = routeWindows(rateLimit)
        return CodexUsage(
            fiveHour: routed.fiveHour,
            weekly: routed.weekly,
            plan: root["plan_type"] as? String
        )
    }

    private func readAccessToken(path: String) throws -> String? {
        let authURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: authURL.path) else { return nil }
        let data = try Data(contentsOf: authURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              !token.isEmpty else { return nil }
        return token
    }

    private func routeWindows(_ rateLimit: [String: Any]) -> (fiveHour: UsageWindow, weekly: UsageWindow) {
        var fiveHour: UsageWindow?
        var weekly: UsageWindow?
        let slots: [(String, Bool)] = [("primary_window", false), ("secondary_window", true)]

        for (key, weeklyFallback) in slots {
            guard let object = rateLimit[key] as? [String: Any] else { continue }
            let seconds = number(object["limit_window_seconds"])
            let isWeekly = seconds.map { $0 >= 86_400 } ?? weeklyFallback
            let parsed = parseWindow(object)
            if isWeekly, weekly == nil { weekly = parsed }
            if !isWeekly, fiveHour == nil { fiveHour = parsed }
        }
        return (fiveHour ?? .unavailable, weekly ?? .unavailable)
    }

    private func parseWindow(_ object: [String: Any]) -> UsageWindow {
        UsageWindow(
            usedPercent: number(object["used_percent"]),
            resetAt: number(object["reset_at"]).map(Date.init(timeIntervalSince1970:))
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}
