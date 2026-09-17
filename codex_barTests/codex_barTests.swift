//
//  codex_barTests.swift
//  codex_barTests
//
//  Created by wjy on 2026/9/5.
//

import Foundation
import Testing
@testable import codex_bar

struct codex_barTests {

    @Test @MainActor func englishDefaultsToUSDUnlessUserSavedAChoice() {
        #expect(UsageStore.defaultCostDisplayCurrency(
            savedValue: nil,
            preferredLanguage: "en-US"
        ) == .usd)
        #expect(UsageStore.defaultCostDisplayCurrency(
            savedValue: nil,
            preferredLanguage: "zh-Hans-CN"
        ) == .cny)
        #expect(UsageStore.defaultCostDisplayCurrency(
            savedValue: "cny",
            preferredLanguage: "en-US"
        ) == .cny)
    }

    @Test @MainActor func exchangeRateRefreshSchedulesNextLocalEightAM() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let morning = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 17, hour: 7, minute: 30
        )))
        let evening = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 17, hour: 21, minute: 30
        )))

        #expect(calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: UsageStore.nextExchangeRateRefresh(after: morning, calendar: calendar)
        ) == DateComponents(year: 2026, month: 9, day: 17, hour: 8, minute: 0))
        #expect(calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: UsageStore.nextExchangeRateRefresh(after: evening, calendar: calendar)
        ) == DateComponents(year: 2026, month: 9, day: 18, hour: 8, minute: 0))
    }

    @Test @MainActor func menuBarTitleShowsBothSelectedWindows() {
        let store = UsageStore.preview
        store.showFiveHourInMenuBar = true
        store.showWeeklyInMenuBar = true

        #expect(store.menuBarTitle == [
            L10n.format("5h %d%%", 62),
            L10n.format("W %d%%", 39)
        ].joined(separator: " · "))
    }

    @Test @MainActor func menuBarTitleCanShowWeeklyOnly() {
        let store = UsageStore.preview
        store.showFiveHourInMenuBar = false
        store.showWeeklyInMenuBar = true

        #expect(store.menuBarTitle == L10n.format("W %d%%", 39))
    }

    @Test @MainActor func menuBarTitleUsesNewlyPublishedUsage() {
        let refreshed = CodexUsage(
            fiveHour: UsageWindow(usedPercent: 16, resetAt: nil),
            weekly: UsageWindow(usedPercent: 2, resetAt: nil),
            plan: "plus"
        )

        #expect(UsageStore.menuBarTitle(
            usage: refreshed,
            showFiveHour: true,
            showWeekly: true
        ) == [
            L10n.format("5h %d%%", 84),
            L10n.format("W %d%%", 98)
        ].joined(separator: " · "))
    }

    @Test func detectsResetFromLargeRemainingQuotaJump() {
        let previous = UsageWindow(usedPercent: 80, resetAt: nil)
        let current = UsageWindow(usedPercent: 20, resetAt: nil)
        #expect(UsageResetDetector.didReset(previous: previous, current: current))
    }

    @Test func ignoresNormalSmallQuotaMovement() {
        let previous = UsageWindow(usedPercent: 50, resetAt: nil)
        let current = UsageWindow(usedPercent: 48, resetAt: nil)
        #expect(!UsageResetDetector.didReset(previous: previous, current: current))
    }

    @Test func detectsResetWhenResetTimeAdvances() {
        let now = Date(timeIntervalSince1970: 2_000)
        let oldReset = now.addingTimeInterval(-60)
        let previous = UsageWindow(usedPercent: 15, resetAt: oldReset)
        let current = UsageWindow(usedPercent: 5, resetAt: oldReset.addingTimeInterval(18_000))
        #expect(UsageResetDetector.didReset(previous: previous, current: current, at: now))
    }

    @Test func ignoresMovingFutureResetTimeWithSmallIncrease() {
        let now = Date(timeIntervalSince1970: 2_000)
        let previous = UsageWindow(usedPercent: 50, resetAt: now.addingTimeInterval(600))
        let current = UsageWindow(usedPercent: 48, resetAt: now.addingTimeInterval(900))
        #expect(!UsageResetDetector.didReset(previous: previous, current: current, at: now))
    }

    @Test func suppressesRepeatedFiveHourResetNotification() {
        let now = Date(timeIntervalSince1970: 20_000)
        let previous = UsageWindow(usedPercent: 80, resetAt: nil)
        let current = UsageWindow(usedPercent: 20, resetAt: nil)
        #expect(!UsageResetNotificationPolicy.shouldNotify(
            previous: previous,
            current: current,
            period: .fiveHour,
            lastNotifiedAt: now.addingTimeInterval(-60),
            now: now
        ))
    }

    @Test func allowsNextFiveHourResetAfterCooldown() {
        let now = Date(timeIntervalSince1970: 20_000)
        let previous = UsageWindow(usedPercent: 80, resetAt: nil)
        let current = UsageWindow(usedPercent: 20, resetAt: nil)
        #expect(UsageResetNotificationPolicy.shouldNotify(
            previous: previous,
            current: current,
            period: .fiveHour,
            lastNotifiedAt: now.addingTimeInterval(-5 * 60 * 60),
            now: now
        ))
    }

    @Test func weeklyResetHasNoTimeCooldown() {
        let now = Date(timeIntervalSince1970: 20_000)
        let previous = UsageWindow(usedPercent: 80, resetAt: nil)
        let current = UsageWindow(usedPercent: 20, resetAt: nil)
        #expect(UsageResetNotificationPolicy.shouldNotify(
            previous: previous,
            current: current,
            period: .weekly,
            lastNotifiedAt: now.addingTimeInterval(-60),
            now: now
        ))
    }

    @Test func disarmedWeeklyResetSuppressesContinuousRise() {
        let previous = UsageWindow(usedPercent: 60, resetAt: nil)
        let current = UsageWindow(usedPercent: 20, resetAt: nil)
        #expect(!UsageResetNotificationPolicy.shouldNotify(
            previous: previous,
            current: current,
            period: .weekly,
            isArmed: false,
            lastNotifiedAt: nil
        ))
    }

    @Test func tokenScannerUsesCumulativeDeltasAndModelPricing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-11111111-1111-1111-1111-111111111111.jsonl")
        let lines = [
            #"{"timestamp":"2026-09-17T01:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-terra"}}"#,
            #"{"timestamp":"2026-09-17T01:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":100,"reasoning_output_tokens":20}}}}"#,
            #"{"timestamp":"2026-09-17T01:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1800,"cached_input_tokens":1000,"output_tokens":250,"reasoning_output_tokens":50}}}}"#
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let service = TokenUsageService(roots: [root])
        let summary = await service.scan(period: .today, now: ISO8601DateFormatter().date(from: "2026-09-17T12:00:00Z")!)

        #expect(summary.counts == TokenCounts(input: 1800, cachedInput: 1000, output: 250, reasoningOutput: 50))
        #expect(summary.sessions == 1)
        #expect(summary.models.first?.model == "gpt-5.6-terra")
        #expect(abs(summary.estimatedUSD - 0.0048) < 0.000_001)
    }

    @Test func tokenScannerKeepsUnknownModelsUnpriced() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-22222222-2222-2222-2222-222222222222.jsonl")
        let content = #"""
{"timestamp":"2026-09-17T02:00:00Z","type":"turn_context","payload":{"model":"future-model"}}
{"timestamp":"2026-09-17T02:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0}}}}
"""#
        try content.write(to: file, atomically: true, encoding: .utf8)

        let summary = await TokenUsageService(roots: [root]).scan(period: .today, now: ISO8601DateFormatter().date(from: "2026-09-17T12:00:00Z")!)
        #expect(summary.estimatedUSD == 0)
        #expect(summary.unpricedTokens == 120)
        #expect(summary.models.first?.estimatedUSD == nil)
    }

}
