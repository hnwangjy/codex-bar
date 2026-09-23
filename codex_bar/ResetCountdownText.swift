import SwiftUI

enum ResetCountdownFormatter {
    static func text(until resetAt: Date, now: Date = .now) -> String {
        let remaining = resetAt.timeIntervalSince(now)
        guard remaining > 0 else { return L10n.text("即将重置") }

        let totalMinutes = max(1, Int(ceil(remaining / 60)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        let duration: String
        if days > 0 {
            duration = L10n.format("%d天 %d小时", days, hours)
        } else if hours > 0 {
            duration = L10n.format("%d小时 %d分钟", hours, minutes)
        } else {
            duration = L10n.format("%d分钟", minutes)
        }
        return L10n.format("还有 %@", duration)
    }
}

struct ResetCountdownText: View {
    let resetAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 4) {
                Image(systemName: "timer")
                BasicValueText(ResetCountdownFormatter.text(until: resetAt, now: context.date))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .accessibilityElement(children: .combine)
        }
    }
}
