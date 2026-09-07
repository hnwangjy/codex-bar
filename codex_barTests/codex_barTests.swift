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

}
