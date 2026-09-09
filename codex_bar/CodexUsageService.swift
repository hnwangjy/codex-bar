import CFNetwork
import Foundation

struct CodexUsageService {
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch(authPath: String) async throws -> CodexUsage {
        var lastError: Error?
        let retryDelays: [UInt64] = [700_000_000, 1_500_000_000]

        for attempt in 0...retryDelays.count {
            do {
                return try await fetchOnce(authPath: authPath)
            } catch {
                lastError = error
                guard attempt < retryDelays.count, shouldRetry(error) else {
                    throw userFacingError(error)
                }
                try await Task.sleep(nanoseconds: retryDelays[attempt])
            }
        }

        throw userFacingError(lastError ?? CodexUsageError.invalidResponse)
    }

    private func fetchOnce(authPath: String) async throws -> CodexUsage {
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

    private func shouldRetry(_ error: Error) -> Bool {
        if let usageError = error as? CodexUsageError {
            switch usageError {
            case .missingAuthentication, .expiredAuthentication:
                return false
            case .server(let status):
                return status == 408 || status == 429 || status >= 500
            case .invalidResponse, .proxyTLSFailure, .secureConnectionFailed, .networkUnavailable:
                return true
            }
        }

        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }

        // The auth file can briefly be unavailable while Codex replaces it.
        return true
    }

    private func userFacingError(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            if let proxy = systemHTTPSProxy() {
                return CodexUsageError.proxyTLSFailure(proxy)
            }
            return CodexUsageError.secureConnectionFailed
        case .notConnectedToInternet, .networkConnectionLost:
            return CodexUsageError.networkUnavailable
        default:
            return error
        }
    }

    private func systemHTTPSProxy() -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              (settings[kCFNetworkProxiesHTTPSEnable as String] as? NSNumber)?.boolValue == true,
              let host = settings[kCFNetworkProxiesHTTPSProxy as String] as? String,
              !host.isEmpty else { return nil }
        let port = (settings[kCFNetworkProxiesHTTPSPort as String] as? NSNumber)?.intValue
        return port.map { "\(host):\($0)" } ?? host
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
