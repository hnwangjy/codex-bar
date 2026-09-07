import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var usage: CodexUsage?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var updatedAt: Date?

    private let service = CodexUsageService()
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
    private var timer: Timer?

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
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let requestedPath = authPath
            let result = try await service.fetch(authPath: requestedPath)
            guard requestedPath == authPath else { return }
            usage = result
            updatedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
