//
//  CenteredTests.swift
//  CenteredTests
//
//  Created by Darion McGee on 7/25/25.
//

import Testing
import CoreGraphics
@testable import Centered

// MARK: - centeredOrigin(windowSize:in:)

@Suite("WindowCenterer geometry")
struct CenteredOriginTests {

    /// A standard window centered in a typical 1440×900 visible area.
    @Test func centeredInTypicalScreen() {
        let screen = CGRect(x: 0, y: 23, width: 1440, height: 877) // visibleFrame with menu bar
        let window = CGSize(width: 800, height: 600)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == screen.midX - window.width  / 2)
        #expect(origin.y == screen.midY - window.height / 2)
    }

    /// Window exactly as large as the screen should land at the screen origin.
    @Test func windowFillsScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = CGSize(width: 1920, height: 1080)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == 0)
        #expect(origin.y == 0)
    }

    /// A 1×1 window should land at the exact centre of the screen.
    @Test func tinyWindow() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let window = CGSize(width: 1, height: 1)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == 2560 / 2 - 0.5)
        #expect(origin.y == 1440 / 2 - 0.5)
    }

    /// Screen with a non-zero origin (e.g. secondary display to the right).
    @Test func screenWithNonZeroOrigin() {
        let screen = CGRect(x: 1920, y: 0, width: 1280, height: 800)
        let window = CGSize(width: 640, height: 400)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == 1920 + (1280 - 640) / 2)
        #expect(origin.y == (800 - 400) / 2)
    }
}

// MARK: - animationPosition(from:to:step:totalSteps:)

@Suite("WindowCenterer animation steps")
struct AnimationPositionTests {

    let start = CGPoint(x: 0,   y: 0)
    let end   = CGPoint(x: 100, y: 200)

    /// Step 0 should return the start position.
    @Test func stepZeroIsStart() {
        let pos = WindowCenterer.animationPosition(
            from: start, to: end, step: 0, totalSteps: 10
        )
        #expect(pos == start)
    }

    /// Final step should return exactly the end position (no float drift).
    @Test func finalStepIsExactEnd() {
        let pos = WindowCenterer.animationPosition(
            from: start, to: end, step: 10, totalSteps: 10
        )
        #expect(pos == end)
    }

    /// Midpoint step should be halfway between start and end.
    @Test func midpointStep() {
        let pos = WindowCenterer.animationPosition(
            from: start, to: end, step: 5, totalSteps: 10
        )
        #expect(pos.x == 50)
        #expect(pos.y == 100)
    }

    /// Each step should be strictly greater than the last (monotone for positive delta).
    @Test func stepsAreMonotonicallyIncreasing() {
        let positions = (0...10).map {
            WindowCenterer.animationPosition(from: start, to: end, step: $0, totalSteps: 10)
        }
        for i in 1...10 {
            #expect(positions[i].x > positions[i - 1].x)
            #expect(positions[i].y > positions[i - 1].y)
        }
    }

    /// A window already at the target should return the target for every step.
    @Test func noMovementWhenAlreadyCentered() {
        let same = CGPoint(x: 320, y: 240)
        for i in 0...10 {
            let pos = WindowCenterer.animationPosition(
                from: same, to: same, step: i, totalSteps: 10
            )
            #expect(pos == same)
        }
    }

    /// Negative deltas (window moves left/up) should also terminate at end.
    @Test func negativeDirection() {
        let from = CGPoint(x: 500, y: 400)
        let to   = CGPoint(x: 100, y: 50)
        let pos  = WindowCenterer.animationPosition(
            from: from, to: to, step: 10, totalSteps: 10
        )
        #expect(pos == to)
    }
}
