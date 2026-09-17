import Foundation
import Darwin

nonisolated enum TokenUsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDays
    case thirtyDays

    var id: Self { self }

    @MainActor var title: String {
        switch self {
        case .today: return L10n.text("今天")
        case .sevenDays: return L10n.text("7 天")
        case .thirtyDays: return L10n.text("30 天")
        }
    }

    func startDate(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .sevenDays:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        }
    }
}

nonisolated struct TokenCounts: Sendable, Equatable {
    var input: Int64 = 0
    var cachedInput: Int64 = 0
    var output: Int64 = 0
    var reasoningOutput: Int64 = 0

    var total: Int64 { input + output }
    var uncachedInput: Int64 { max(0, input - cachedInput) }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            input: lhs.input + rhs.input,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            output: lhs.output + rhs.output,
            reasoningOutput: lhs.reasoningOutput + rhs.reasoningOutput
        )
    }

    func delta(from previous: Self) -> Self {
        Self(
            input: max(0, input - previous.input),
            cachedInput: max(0, cachedInput - previous.cachedInput),
            output: max(0, output - previous.output),
            reasoningOutput: max(0, reasoningOutput - previous.reasoningOutput)
        )
    }
}

nonisolated struct ModelTokenUsage: Identifiable, Sendable, Equatable {
    let model: String
    let counts: TokenCounts
    let estimatedUSD: Double?

    var id: String { model }
}

nonisolated struct TokenUsageSummary: Sendable, Equatable {
    let period: TokenUsagePeriod
    let counts: TokenCounts
    let estimatedUSD: Double
    let unpricedTokens: Int64
    let sessions: Int
    let models: [ModelTokenUsage]
    let updatedAt: Date
}

nonisolated struct ModelPricing: Sendable, Equatable {
    let inputPerMillion: Double
    let cachedInputPerMillion: Double
    let outputPerMillion: Double

    func estimate(_ counts: TokenCounts) -> Double {
        (Double(counts.uncachedInput) * inputPerMillion
         + Double(counts.cachedInput) * cachedInputPerMillion
         + Double(counts.output) * outputPerMillion) / 1_000_000
    }
}

nonisolated enum OpenAIPriceCatalog {
    // OpenAI ChatGPT Rate Card, checked 2026-09-17. Values are USD per 1M tokens.
    static func pricing(for rawModel: String) -> ModelPricing? {
        let model = rawModel.lowercased()
        if model.hasPrefix("gpt-6-astra") { return .init(inputPerMillion: 10, cachedInputPerMillion: 1, outputPerMillion: 50) }
        if model.hasPrefix("gpt-5.6-sol") { return .init(inputPerMillion: 4, cachedInputPerMillion: 0.4, outputPerMillion: 20) }
        if model.hasPrefix("gpt-5.6-terra") { return .init(inputPerMillion: 2, cachedInputPerMillion: 0.2, outputPerMillion: 12) }
        if model.hasPrefix("gpt-5.6-luna") { return .init(inputPerMillion: 0.2, cachedInputPerMillion: 0.02, outputPerMillion: 1.2) }
        if model.hasPrefix("gpt-5.5") { return .init(inputPerMillion: 5, cachedInputPerMillion: 0.5, outputPerMillion: 30) }
        if model.hasPrefix("gpt-5.4-mini") { return .init(inputPerMillion: 0.75, cachedInputPerMillion: 0.075, outputPerMillion: 4.5) }
        if model.hasPrefix("gpt-5.4") { return .init(inputPerMillion: 2.5, cachedInputPerMillion: 0.25, outputPerMillion: 15) }
        if model.hasPrefix("gpt-5.3-codex") { return .init(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14) }
        if model.hasPrefix("gpt-5.2") { return .init(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14) }
        return nil
    }
}

actor TokenUsageService {
    private let roots: [URL]
    private struct CachedSession {
        let fileSize: Int
        let modifiedAt: Date
        let periodStart: Date
        let byModel: [String: TokenCounts]
        let hadUsage: Bool
    }
    private var sessionCache: [String: CachedSession] = [:]

    init(roots: [URL]? = nil) {
        if let roots {
            self.roots = roots
        } else {
            let codex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
            self.roots = [
                codex.appendingPathComponent("sessions", isDirectory: true),
                codex.appendingPathComponent("archived_sessions", isDirectory: true)
            ]
        }
    }

    func scan(period: TokenUsagePeriod, now: Date = Date()) -> TokenUsageSummary {
        let start = period.startDate(now: now)
        let urls = deduplicatedSessionFiles()
        var byModel: [String: TokenCounts] = [:]
        var matchingSessions = 0

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate else { continue }
            if modified < start { continue }
            let cacheKey = url.path
            let result: (byModel: [String: TokenCounts], hadUsage: Bool)
            if let cached = sessionCache[cacheKey],
               cached.fileSize == values.fileSize,
               cached.modifiedAt == modified,
               cached.periodStart == start {
                result = (cached.byModel, cached.hadUsage)
            } else {
                result = parseSession(url: url, start: start, end: now)
                sessionCache[cacheKey] = CachedSession(
                    fileSize: values.fileSize ?? 0,
                    modifiedAt: modified,
                    periodStart: start,
                    byModel: result.byModel,
                    hadUsage: result.hadUsage
                )
            }
            guard result.hadUsage else { continue }
            matchingSessions += 1
            for (model, counts) in result.byModel {
                byModel[model, default: TokenCounts()] = byModel[model, default: TokenCounts()] + counts
            }
        }

        var total = TokenCounts()
        var estimatedUSD = 0.0
        var unpricedTokens: Int64 = 0
        let models = byModel.map { model, counts -> ModelTokenUsage in
            total = total + counts
            let cost = OpenAIPriceCatalog.pricing(for: model)?.estimate(counts)
            if let cost { estimatedUSD += cost } else { unpricedTokens += counts.total }
            return ModelTokenUsage(model: model, counts: counts, estimatedUSD: cost)
        }.sorted { lhs, rhs in
            if lhs.estimatedUSD != rhs.estimatedUSD { return (lhs.estimatedUSD ?? -1) > (rhs.estimatedUSD ?? -1) }
            return lhs.counts.total > rhs.counts.total
        }

        return TokenUsageSummary(
            period: period,
            counts: total,
            estimatedUSD: estimatedUSD,
            unpricedTokens: unpricedTokens,
            sessions: matchingSessions,
            models: models,
            updatedAt: now
        )
    }

    private func deduplicatedSessionFiles() -> [URL] {
        var selected: [String: (url: URL, size: Int64, modified: Date)] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true else { continue }
                let key = sessionKey(for: url)
                let candidate = (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
                if let existing = selected[key], existing.size > candidate.1 || (existing.size == candidate.1 && existing.modified >= candidate.2) { continue }
                selected[key] = candidate
            }
        }
        return selected.values.map(\.url)
    }

    private func sessionKey(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return name }
        return String(name[range]).lowercased()
    }

    private func parseSession(url: URL, start: Date, end: Date) -> (byModel: [String: TokenCounts], hadUsage: Bool) {
        guard let mapped = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return ([:], false) }
        var currentModel: String?
        var previous = TokenCounts()
        var result: [String: TokenCounts] = [:]
        var hadUsage = false
        let maximumRelevantLineSize = 2 * 1024 * 1024
        mapped.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let remaining = raw.count - offset
                let startPointer = base.advanced(by: offset)
                let newlinePointer = memchr(startPointer, Int32(0x0A), remaining)
                let lineLength = newlinePointer.map { startPointer.distance(to: $0) } ?? remaining
                if lineLength <= maximumRelevantLineSize, lineHasRelevantMarker(startPointer, length: lineLength) {
                    let line = Data(bytes: startPointer, count: lineLength)
                    process(line: line, currentModel: &currentModel, previous: &previous, start: start, end: end, result: &result, hadUsage: &hadUsage)
                }
                offset += lineLength + (newlinePointer == nil ? 0 : 1)
            }
        }
        return (result, hadUsage)
    }

    private func process(
        line: Data,
        currentModel: inout String?,
        previous: inout TokenCounts,
        start: Date,
        end: Date,
        result: inout [String: TokenCounts],
        hadUsage: inout Bool
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return }

        if type == "turn_context" {
            currentModel = payload["model"] as? String ?? (payload["collaboration_mode"] as? [String: Any])?["model"] as? String
            return
        }
        guard type == "event_msg", payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return }

        let snapshot = TokenCounts(
            input: int64(total["input_tokens"]),
            cachedInput: int64(total["cached_input_tokens"]),
            output: int64(total["output_tokens"]),
            reasoningOutput: int64(total["reasoning_output_tokens"])
        )
        let delta = snapshot.delta(from: previous)
        previous = snapshot
        guard delta.total > 0,
              let timestamp = parseDate(object["timestamp"]),
              timestamp >= start, timestamp <= end else { return }

        let model = currentModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (model?.isEmpty == false ? model! : "Unknown Model")
        result[key, default: TokenCounts()] = result[key, default: TokenCounts()] + delta
        hadUsage = true
    }

    private func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) ?? 0 }
        return 0
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        guard let string = value as? String else { return nil }
        return Self.iso8601WithFractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func lineHasRelevantMarker(_ dataBase: UnsafeRawPointer, length: Int) -> Bool {
        func contains(_ marker: [UInt8]) -> Bool {
            guard length >= marker.count else { return false }
            return marker.withUnsafeBytes { markerBytes in
                guard let markerBase = markerBytes.baseAddress else { return false }
                return memmem(dataBase, length, markerBase, markerBytes.count) != nil
            }
        }
        return contains(Self.tokenCountMarker) || contains(Self.turnContextMarker)
    }

    private static let tokenCountMarker = Array("\"token_count\"".utf8)
    private static let turnContextMarker = Array("\"turn_context\"".utf8)

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
