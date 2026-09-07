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
        let oldReset = Date(timeIntervalSince1970: 1_000)
        let previous = UsageWindow(usedPercent: 15, resetAt: oldReset)
        let current = UsageWindow(usedPercent: 5, resetAt: oldReset.addingTimeInterval(18_000))
        #expect(UsageResetDetector.didReset(previous: previous, current: current))
    }

}
