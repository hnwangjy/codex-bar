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
        case .authorized, .provisional, .ephemeral: return "已允许"
        case .denied: return "已关闭，请在系统设置中允许"
        case .notDetermined: return "尚未授权"
        @unknown default: return "状态未知"
        }
    }

    func send(period: String, remainingPercent: Double) async -> Bool {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else { return false }

        let content = UNMutableNotificationContent()
        content.title = "\(period)额度已重置"
        content.body = "当前剩余额度 \(Int(remainingPercent.rounded()))%。"
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
        _ = await send(period: "测试", remainingPercent: 100)
    }
}
