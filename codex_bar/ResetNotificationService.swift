import Foundation
import UserNotifications

@MainActor
final class ResetNotificationService {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func authorizationDescription() async -> String {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return L10n.text("已允许")
        case .denied: return L10n.text("已关闭，请在系统设置中允许")
        case .notDetermined: return L10n.text("尚未授权")
        @unknown default: return L10n.text("状态未知")
        }
    }

    func send(period: String, remainingPercent: Double) async -> Bool {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else { return false }

        let content = UNMutableNotificationContent()
        content.title = L10n.format("%@额度已重置", period)
        content.body = L10n.format("当前剩余额度 %d%%。", Int(remainingPercent.rounded()))
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "quota-reset-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    func sendTest() async {
        await requestAuthorization()
        _ = await send(period: L10n.text("测试"), remainingPercent: 100)
    }
}
