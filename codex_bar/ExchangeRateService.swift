import Foundation

nonisolated enum CostDisplayCurrency: String, CaseIterable, Identifiable, Sendable {
    case cny
    case usd

    var id: Self { self }

    @MainActor var title: String {
        switch self {
        case .cny: return L10n.text("人民币")
        case .usd: return L10n.text("美元")
        }
    }

    var currencyCode: String { rawValue.uppercased() }
}

struct ExchangeRateService: Sendable {
    private struct Response: Decodable {
        let date: String
        let rates: [String: Double]
    }

    func fetchUSDtoCNY() async throws -> (rate: Double, sourceDate: String) {
        var components = URLComponents(string: "https://api.frankfurter.dev/v1/latest")!
        components.queryItems = [
            URLQueryItem(name: "base", value: "USD"),
            URLQueryItem(name: "symbols", value: "CNY")
        ]
        guard let url = components.url else { throw ExchangeRateError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let result = try? JSONDecoder().decode(Response.self, from: data),
              let rate = result.rates["CNY"], rate > 0 else {
            throw ExchangeRateError.invalidResponse
        }
        return (rate, result.date)
    }
}

enum ExchangeRateError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        L10n.text("暂时无法获取最新汇率，请稍后重试。")
    }
}
