import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: UsageStore
    var openPanel: () -> Void = {}
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.top, 17).padding(.bottom, 14)
            Group {
                if store.isLoading && store.usage == nil { loadingView }
                else if let usage = store.usage {
                    VStack(spacing: 10) {
                        UsageCard(title: L10n.text("5 小时"), symbol: "clock", window: usage.fiveHour)
                        UsageCard(title: L10n.text("每周"), symbol: "calendar", window: usage.weekly)
                    }
                } else { errorView }
            }.padding(.horizontal, 12)

            if store.usage != nil, let error = store.errorMessage {
                Label(L10n.format("刷新失败，当前为上次数据：%@", error), systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.top, 10)
            }
            Divider().padding(.top, 14)
            toolbar.padding(.horizontal, 10).padding(.vertical, 9)
        }
        .frame(width: 336)
        .background(.ultraThinMaterial)
        .environment(\.controlActiveState, .active)
        .task { await store.loadIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex 额度").font(.headline)
                Text(store.usage?.planDisplayName ?? "ChatGPT").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
            else if store.usage != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("已连接 Codex")
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在读取 Codex 额度…").font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 158)
    }

    private var errorView: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.icloud").font(.system(size: 25)).foregroundStyle(.orange)
            Text("暂时无法获取额度").font(.subheadline.weight(.semibold))
            Text(store.errorMessage ?? L10n.text("未知错误"))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if store.errorRequiresLogin {
                Text("请先在终端运行 codex login，然后重新刷新。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button { Task { await store.refresh() } } label: { Label("重新连接", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered).disabled(store.isLoading)
        }.frame(maxWidth: .infinity, minHeight: 158).padding(.horizontal, 20)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            MenuToolbarButton(title: L10n.text("打开面板"), symbol: "rectangle.on.rectangle", action: openPanel)
            MenuToolbarButton(title: L10n.text("设置"), symbol: "gearshape", action: openSettings)
            Spacer(minLength: 8)
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                    .animation(store.isLoading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: store.isLoading)
                    .frame(width: 26, height: 26)
            }.buttonStyle(.plain).help(updatedLabel).disabled(store.isLoading)
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").frame(width: 26, height: 26) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("退出")
        }
    }

    private var updatedLabel: String {
        guard let updatedAt = store.updatedAt else { return L10n.text("刷新") }
        return L10n.format("更新于 %@", updatedAt.formatted(date: .omitted, time: .shortened))
    }
}

private struct UsageCard: View {
    let title: String
    let symbol: String
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(tint.opacity(0.14), lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat((window.remainingPercent ?? 0) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            }.frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                if let resetAt = window.resetAt {
                    Text(L10n.format("重置时间：%@", resetAt.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption2).foregroundStyle(.secondary)
                } else { Text("未提供").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            if let percent = window.remainingPercent {
                (Text("\(Int(percent.rounded()))").font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                 + Text("%").font(.caption.weight(.semibold)).foregroundColor(.secondary))
            } else { Text("—").font(.title2).foregroundStyle(.tertiary) }
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.primary.opacity(0.07), lineWidth: 0.5) }
    }

    private var tint: Color {
        switch window.remainingPercent ?? 100 { case ...10: return .red; case ...25: return .orange; default: return .accentColor }
    }
}

private struct MenuToolbarButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.callout).padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

#Preview { ContentView(store: .preview) }
