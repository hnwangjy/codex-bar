import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ObservableObject, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let store = UsageStore()
    @Published var menuEnabled = false
    @Published var settingsSelected = false
    private var panel: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var usageObservation: AnyCancellable?

    @discardableResult
    private func installMenu() -> Bool {
        if let statusItem { return statusItem.button != nil }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { NSStatusBar.system.removeStatusItem(item); return false }
        button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: L10n.text("Codex 额度"))
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover)
        statusItem = item
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 336, height: 330)
        popover.contentViewController = NSHostingController(rootView: ContentView(
            store: store,
            openPanel: { [weak self] in self?.showPanel() },
            openSettings: { [weak self] in self?.showPanel(settings: true) }
        ))
        usageObservation = Publishers.CombineLatest3(store.$usage, store.$showFiveHourInMenuBar, store.$showWeeklyInMenuBar)
            .sink { [weak self] usage, fiveHour, weekly in
                self?.statusItem?.button?.title = " \(UsageStore.menuBarTitle(usage: usage, showFiveHour: fiveHour, showWeekly: weekly))"
            }
        return true
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { NSApp.activate(ignoringOtherApps: true); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        showPanel()
        Task { await store.loadIfNeeded() }
        store.scheduleRefresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }

    func showPanel(settings: Bool = false) {
        popover.performClose(nil)
        settingsSelected = settings
        if panel == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Codex Bar"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: ControlPanel(controller: self, store: store))
            window.center()
            panel = window
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func startMenu() {
        guard installMenu() else { return }
        menuEnabled = true
        DispatchQueue.main.async { [weak self] in self?.panel?.orderOut(nil) }
    }

    func windowWillClose(_ notification: Notification) { guard installMenu() else { return }; menuEnabled = true }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) { showPanel(); completionHandler() }
}

struct ControlPanel: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            panelHeader.padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 18)
            Picker("页面", selection: $controller.settingsSelected) {
                Label("概览", systemImage: "chart.bar").tag(false)
                Label("设置", systemImage: "gearshape").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 26).padding(.bottom, 20)
            Group { if controller.settingsSelected { settingsView } else { overviewView } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .frame(width: 500, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var panelHeader: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Bar").font(.title2.weight(.semibold))
                Text("额度，一眼可见。").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(); connectionBadge
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            if store.isLoading { ProgressView().controlSize(.mini) }
            else { Circle().fill(store.usage != nil ? Color.green : Color.secondary).frame(width: 7, height: 7) }
            Text(store.isLoading ? L10n.text("正在刷新…") : (store.usage != nil ? L10n.text("已连接 Codex") : L10n.text("等待连接")))
                .font(.caption.weight(.medium))
        }.padding(.horizontal, 10).frame(height: 28).background(.quaternary.opacity(0.65), in: Capsule())
    }

    private var overviewView: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let usage = store.usage {
                    HStack(spacing: 12) {
                        PanelQuotaCard(title: L10n.text("5 小时额度"), symbol: "clock", window: usage.fiveHour)
                        PanelQuotaCard(title: L10n.text("每周额度"), symbol: "calendar", window: usage.weekly)
                    }
                } else if store.isLoading {
                    ProgressView("正在读取 Codex 额度…").frame(maxWidth: .infinity, minHeight: 180)
                } else { emptyState }
                statusCard
                Text("启动后，点击菜单栏图标查看额度。面板和设置始终可以从菜单栏打开。")
                    .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 26).padding(.bottom, 20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "network.slash").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text("暂时无法获取额度").font(.headline)
            Text(store.errorMessage ?? L10n.text("未知错误")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { Task { await store.refresh() } } label: { Label("重新连接", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderedProminent).disabled(store.isLoading)
        }
        .frame(maxWidth: .infinity, minHeight: 190).padding()
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var statusCard: some View {
        if let error = store.errorMessage, store.usage != nil {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动刷新失败，当前展示上次成功获取的数据。").font(.callout.weight(.medium))
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }; Spacer()
            }.padding(13).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let updatedAt = store.updatedAt {
            HStack {
                Label(L10n.format("最近连接：%@", updatedAt.formatted(date: .omitted, time: .standard)), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await store.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(store.isLoading)
            }
        }
    }

    private var settingsView: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsGroup(title: L10n.text("Codex 登录文件"), symbol: "key") {
                    TextField("~/.codex/auth.json", text: $store.authPath).textFieldStyle(.roundedBorder).disabled(store.isLoading)
                    HStack { Button("选择文件…") { chooseAuthFile() }.disabled(store.isLoading); Button("恢复默认") { store.authPath = "~/.codex/auth.json" }.disabled(store.isLoading); Spacer() }
                    Text("只读取已有登录信息，不保存或展示令牌。").font(.caption).foregroundStyle(.secondary)
                }
                SettingsGroup(title: L10n.text("自动刷新"), symbol: "arrow.triangle.2.circlepath") {
                    Picker("自动刷新", selection: $store.refreshMinutes) {
                        Text("每 5 分钟").tag(5); Text("每 15 分钟").tag(15); Text("每 30 分钟").tag(30)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                SettingsGroup(title: L10n.text("菜单栏显示"), symbol: "menubar.rectangle") {
                    Toggle("5 小时额度", isOn: $store.showFiveHourInMenuBar).disabled(store.showFiveHourInMenuBar && !store.showWeeklyInMenuBar)
                    Toggle("每周额度", isOn: $store.showWeeklyInMenuBar).disabled(store.showWeeklyInMenuBar && !store.showFiveHourInMenuBar)
                }
                SettingsGroup(title: L10n.text("额度重置提醒"), symbol: "bell") {
                    Toggle("5 小时额度重置", isOn: $store.notifyFiveHourReset)
                    Toggle("每周额度重置", isOn: $store.notifyWeeklyReset)
                    Divider()
                    HStack {
                        Text(L10n.format("系统通知：%@", store.notificationAuthorization)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("发送测试提醒") { Task { await store.sendTestNotification() } }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    Text("设置自动保存。网络连接使用 macOS 当前网络与系统代理配置。").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button(store.isLoading ? L10n.text("正在测试…") : L10n.text("测试连接")) { Task { await store.refresh() } }.disabled(store.isLoading)
                }
            }.padding(.horizontal, 26).padding(.bottom, 20)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button { NSApp.terminate(nil) } label: { Label("退出", systemImage: "power") }.buttonStyle(.borderless)
            Spacer()
            Button { controller.startMenu() } label: {
                Label(controller.menuEnabled ? L10n.text("返回菜单栏") : L10n.text("启动菜单栏"), systemImage: "menubar.rectangle")
            }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 26).padding(.vertical, 16).background(.bar).overlay(alignment: .top) { Divider() }
    }

    private func chooseAuthFile() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false; picker.showsHiddenFiles = true
        if picker.runModal() == .OK, let url = picker.url { store.authPath = url.path }
    }
}

private struct PanelQuotaCard: View {
    let title: String; let symbol: String; let window: UsageWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Image(systemName: symbol).foregroundStyle(.tint); Text(title).font(.subheadline.weight(.medium)); Spacer() }
            if let percent = window.remainingPercent {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(percent.rounded()))").font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("%").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
                ProgressView(value: percent, total: 100).tint(tint)
            } else { Text("—").font(.largeTitle).foregroundStyle(.tertiary) }
            Text(window.resetAt.map { L10n.format("重置时间：%@", $0.formatted(date: .abbreviated, time: .shortened)) } ?? L10n.text("未提供"))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.primary.opacity(0.06), lineWidth: 0.5) }
    }
    private var tint: Color { switch window.remainingPercent ?? 100 { case ...10: return .red; case ...25: return .orange; default: return .accentColor } }
}

private struct SettingsGroup<Content: View>: View {
    let title: String; let symbol: String; @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)); content
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
