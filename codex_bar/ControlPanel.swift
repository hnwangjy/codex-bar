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
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return false
        }
        button.image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.67percent",
            accessibilityDescription: "Codex 额度"
        )
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover)
        statusItem = item
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 360)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                store: store,
                openPanel: { [weak self] in self?.showPanel() },
                openSettings: { [weak self] in self?.showPanel(settings: true) }
            )
        )
        usageObservation = store.$usage.sink { [weak self] usage in
            let percent = usage?.fiveHour.remainingPercent ?? usage?.weekly.remainingPercent
            self?.statusItem?.button?.title = percent.map { " \(Int($0.rounded()))%" } ?? " Codex"
        }
        return true
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        showPanel()
        Task { await store.loadIfNeeded() }
        store.scheduleRefresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func showPanel(settings: Bool = false) {
        popover.performClose(nil)
        settingsSelected = settings
        if panel == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 550), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
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
        // Let AppKit place the status item before hiding the only window.
        DispatchQueue.main.async { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard installMenu() else { return }
        // Closing the setup window always leaves a way back to settings.
        menuEnabled = true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        showPanel()
        completionHandler()
    }
}

struct ControlPanel: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex Bar").font(.title2.bold())
                    Text("额度，一眼可见。") .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Picker("页面", selection: $controller.settingsSelected) {
                Text("概览").tag(false)
                Text("设置").tag(true)
            }.pickerStyle(.segmented)

            if controller.settingsSelected {
                ScrollView {
                    settings.padding(.trailing, 6)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Label(store.isLoading ? "正在连接…" : (store.errorMessage == nil && store.usage != nil ? "已连接 Codex" : "等待连接"), systemImage: store.usage != nil && store.errorMessage == nil ? "checkmark.circle.fill" : "network")
                        .foregroundStyle(store.usage != nil && store.errorMessage == nil ? Color.green : Color.secondary)
                    if let usage = store.usage {
                        quota("5 小时额度", value: usage.fiveHour.remainingPercent)
                        quota("每周额度", value: usage.weekly.remainingPercent)
                    }
                    status
                    Button("重新连接") { Task { await store.refresh() } }
                        .disabled(store.isLoading)
                    Text("启动后，点击菜单栏图标查看额度。面板和设置始终可以从菜单栏打开。")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button("退出") { NSApp.terminate(nil) }
                Spacer()
                Button(controller.menuEnabled ? "返回菜单栏" : "启动菜单栏") { controller.startMenu() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480, height: 550)
    }

    private func quota(_ title: String, value: Double?) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value.map { "剩余 \(Int($0.rounded()))%" } ?? "未提供").monospacedDigit()
            }
            if let value { ProgressView(value: min(100, max(0, value)), total: 100).tint(.mint) }
        }
    }

    @ViewBuilder private var status: some View {
        if let error = store.errorMessage {
            Text(error).font(.callout).foregroundStyle(.orange)
            Text("检查网络和登录文件；登录过期时，在终端运行 codex login 后重试。")
                .font(.caption).foregroundStyle(.secondary)
        } else if let updatedAt = store.updatedAt {
            Text("最近连接：\(updatedAt.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Codex 登录文件").font(.headline)
            TextField("~/.codex/auth.json", text: $store.authPath).textFieldStyle(.roundedBorder)
                .disabled(store.isLoading)
            HStack {
                Button("选择文件…") {
                    let picker = NSOpenPanel()
                    picker.canChooseDirectories = false
                    picker.allowsMultipleSelection = false
                    picker.showsHiddenFiles = true
                    if picker.runModal() == .OK, let url = picker.url { store.authPath = url.path }
                }.disabled(store.isLoading)
                Button("恢复默认") { store.authPath = "~/.codex/auth.json" }.disabled(store.isLoading)
            }
            Text("只读取已有登录信息，不保存或展示令牌。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("自动刷新", selection: $store.refreshMinutes) {
                Text("每 5 分钟").tag(5)
                Text("每 15 分钟").tag(15)
                Text("每 30 分钟").tag(30)
            }
            Divider()
            Text("额度重置提醒").font(.headline)
            Toggle("5 小时额度重置", isOn: $store.notifyFiveHourReset)
            Toggle("每周额度重置", isOn: $store.notifyWeeklyReset)
            Text("自动刷新检测到剩余额度明显上涨时发送系统通知。首次启用需要允许通知权限。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("系统通知：\(store.notificationAuthorization)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("发送测试提醒") { Task { await store.sendTestNotification() } }
            }
            Button(store.isLoading ? "正在测试…" : "测试连接") { Task { await store.refresh() } }
                .disabled(store.isLoading)
            status
            Text("设置自动保存。网络连接使用 macOS 当前网络与系统代理配置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
