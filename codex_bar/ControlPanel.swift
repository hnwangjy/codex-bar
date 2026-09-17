import AppKit
import Combine
import ServiceManagement
import Sparkle
import SwiftUI
import UserNotifications

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ObservableObject, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let store = UsageStore()
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @Published var menuEnabled = false
    @Published var settingsSelected = false
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published var launchAtLoginError: String?
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
        popover.contentSize = NSSize(width: 336, height: 365)
        popover.contentViewController = NSHostingController(rootView: ContentView(
            store: store,
            openPanel: { [weak self] in self?.showPanel() },
            openSettings: { [weak self] in self?.showPanel(settings: true) },
            checkForUpdates: { [weak self] in self?.checkForUpdates() }
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
        refreshLaunchAtLoginStatus()
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

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginError = error.localizedDescription
        }
    }

    func refreshLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginRequiresApproval = false
        case .requiresApproval:
            launchAtLoginEnabled = true
            launchAtLoginRequiresApproval = true
        case .notRegistered, .notFound:
            launchAtLoginEnabled = false
            launchAtLoginRequiresApproval = false
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginRequiresApproval = false
        }
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
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
        .onAppear { controller.refreshLaunchAtLoginStatus() }
        .alert("无法修改登录项", isPresented: Binding(
            get: { controller.launchAtLoginError != nil },
            set: { if !$0 { controller.launchAtLoginError = nil } }
        )) {
            Button("好", role: .cancel) { controller.launchAtLoginError = nil }
        } message: {
            Text(controller.launchAtLoginError ?? L10n.text("未知错误"))
        }
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
                TokenUsageCard(store: store)
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
                SettingsGroup(title: L10n.text("Token 费用估算"), symbol: "banknote") {
                    Picker(L10n.text("金额显示"), selection: $store.costDisplayCurrency) {
                        ForEach(CostDisplayCurrency.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    HStack {
                        Text(L10n.text("美元兑人民币"))
                        Spacer()
                        TextField("6.71", value: $store.usdToCNY, format: .number.precision(.fractionLength(2...4)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 86)
                        Button { Task { await store.refreshExchangeRate() } } label: {
                            Image(systemName: "arrow.clockwise")
                                .rotationEffect(.degrees(store.isRefreshingExchangeRate ? 360 : 0))
                                .animation(store.isRefreshingExchangeRate ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: store.isRefreshingExchangeRate)
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.isRefreshingExchangeRate)
                        .help(L10n.text("刷新当前汇率"))
                    }
                    if let error = store.exchangeRateError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    } else if let updatedAt = store.exchangeRateUpdatedAt {
                        Text(L10n.format("汇率更新于 %@ · 数据日期 %@", updatedAt.formatted(date: .omitted, time: .shortened), store.exchangeRateSourceDate ?? "—"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("汇率用于把官方美元 Token 单价换算为人民币，可按当天汇率自行调整。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("费用是 API 等价估算，不是 ChatGPT Plus 的实际账单。所有统计仅在本机读取 Codex 会话日志。")
                        .font(.caption).foregroundStyle(.secondary)
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
                SettingsGroup(title: L10n.text("软件更新"), symbol: "arrow.triangle.2.circlepath.circle") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.format("当前版本：%@", appVersion))
                            Text("应用会自动检查新版本，也可以立即手动检查。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { controller.checkForUpdates() } label: {
                            Label("检查更新…", systemImage: "arrow.clockwise")
                        }
                    }
                }
                SettingsGroup(title: L10n.text("登录时启动"), symbol: "power") {
                    Toggle(L10n.text("登录 Mac 时自动打开 Codex Bar"), isOn: Binding(
                        get: { controller.launchAtLoginEnabled },
                        set: { controller.setLaunchAtLogin($0) }
                    ))
                    if controller.launchAtLoginRequiresApproval {
                        HStack(alignment: .firstTextBaseline) {
                            Text("需要在系统设置的“登录项”中允许 Codex Bar。")
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("打开系统设置") { controller.openLoginItemsSettings() }
                                .buttonStyle(.borderless)
                        }
                    } else {
                        Text("开启后，Codex Bar 会在你登录 Mac 时自动运行。")
                            .font(.caption).foregroundStyle(.secondary)
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

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

private struct TokenUsageCard: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.text("Token 用量"), systemImage: "number.square").font(.headline)
                Spacer()
                if store.isLoadingTokenUsage { ProgressView().controlSize(.mini) }
                Button { Task { await store.refreshTokenUsage() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(store.isLoadingTokenUsage).help(L10n.text("刷新 Token 用量"))
            }

            Picker(L10n.text("统计周期"), selection: $store.tokenUsagePeriod) {
                ForEach(TokenUsagePeriod.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()

            if let summary = store.tokenUsage {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(formatTokens(summary.counts.total)).font(.system(size: 27, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(L10n.format("%d 个会话", summary.sessions)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(store.formattedCost(usd: summary.estimatedUSD)).font(.system(size: 27, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(L10n.text("API 等价估算")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    tokenMetric(L10n.text("输入"), summary.counts.input)
                    tokenMetric(L10n.text("缓存输入"), summary.counts.cachedInput)
                    tokenMetric(L10n.text("输出"), summary.counts.output)
                    tokenMetric(L10n.text("推理"), summary.counts.reasoningOutput)
                }
                if !summary.models.isEmpty {
                    Divider()
                    ForEach(summary.models.prefix(6)) { model in
                        HStack(spacing: 8) {
                            Image(systemName: "cpu").foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.model).font(.callout.weight(.medium)).lineLimit(1)
                                Text(formatTokens(model.counts.total)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let usd = model.estimatedUSD {
                                Text(store.formattedCost(usd: usd)).font(.callout.monospacedDigit())
                            } else {
                                Text(L10n.text("未计价")).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if summary.unpricedTokens > 0 {
                    Label(L10n.format("%@ Token 暂无官方匹配单价，未计入费用。", formatTokens(summary.unpricedTokens)), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(L10n.text("本地日志统计 · 费用不是实际扣款")).font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(L10n.text("正在扫描本机 Codex 会话日志…"))
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.primary.opacity(0.06), lineWidth: 0.5) }
    }

    private func tokenMetric(_ title: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(formatTokens(value)).font(.caption.weight(.medium).monospacedDigit()).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func formatTokens(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return value.formatted()
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
