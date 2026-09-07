import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: UsageStore
    var openPanel: () -> Void = {}
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if store.isLoading && store.usage == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在读取 Codex 额度…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 112)
            } else if let usage = store.usage {
                VStack(spacing: 12) {
                    UsageRow(title: "5 小时", window: usage.fiveHour)
                    UsageRow(title: "每周", window: usage.weekly)
                }
            } else {
                errorView
            }

            Divider()
            if store.usage != nil, let error = store.errorMessage {
                Text("刷新失败，当前为上次数据：\(error)")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("打开面板", action: openPanel)
                Spacer()
                Button { openSettings() } label: { Label("设置", systemImage: "gearshape") }
            }
            .buttonStyle(.plain)

            HStack {
                if let updatedAt = store.updatedAt {
                    Text("更新于 \(updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新")
                .disabled(store.isLoading)
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 320)
        .task { await store.loadIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex 额度").font(.headline)
                Text(store.usage?.planDisplayName ?? "ChatGPT")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
        }
    }

    private var errorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("暂时无法获取额度", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text(store.errorMessage ?? "未知错误")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.errorMessage?.contains("登录") == true {
                Text("请先在终端运行 codex login，然后重新刷新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }
}

private struct UsageRow: View {
    let title: String
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                if let percent = window.usedPercent {
                    Text("已用 \(Int(percent.rounded()))%")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                } else {
                    Text("未提供").font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: window.usedPercent ?? 0, total: 100)
                .tint(tintColor)
            if let resetAt = window.resetAt {
                Text("重置时间：\(resetAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var tintColor: Color {
        switch window.usedPercent ?? 0 {
        case 90...: return .red
        case 75...: return .orange
        default: return .accentColor
        }
    }
}

#Preview {
    ContentView(store: .preview)
}
