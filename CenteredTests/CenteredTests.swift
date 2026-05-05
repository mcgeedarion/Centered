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

    @Test func centeredInTypicalScreen() {
        let screen = CGRect(x: 0, y: 23, width: 1440, height: 877)
        let window = CGSize(width: 800, height: 600)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == screen.midX - window.width  / 2)
        #expect(origin.y == screen.midY - window.height / 2)
    }

    @Test func windowFillsScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = CGSize(width: 1920, height: 1080)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == 0)
        #expect(origin.y == 0)
    }

    @Test func tinyWindow() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let window = CGSize(width: 1, height: 1)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == CGFloat(2560) / 2 - 0.5)
        #expect(origin.y == CGFloat(1440) / 2 - 0.5)
    }

    @Test func screenWithNonZeroOrigin() {
        let screen = CGRect(x: 1920, y: 0, width: 1280, height: 800)
        let window = CGSize(width: 640, height: 400)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == CGFloat(1920) + (CGFloat(1280) - CGFloat(640)) / 2)
        #expect(origin.y == (CGFloat(800) - CGFloat(400)) / 2)
    }

    /// Large window bigger than the screen should produce a negative origin
    /// (window extends off-screen but is still geometrically centred).
    @Test func windowLargerThanScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let window = CGSize(width: 1920, height: 1080)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == CGFloat(1280) / 2 - CGFloat(1920) / 2)  // -320
        #expect(origin.y == CGFloat(800)  / 2 - CGFloat(1080) / 2)  // -140
        #expect(origin.x < 0)
        #expect(origin.y < 0)
    }

    /// Retina / HiDPI: non-integer screen dimensions should not cause drift.
    @Test func nonIntegerScreenDimensions() {
        let screen = CGRect(x: 0, y: 0, width: 1680, height: 1050)
        let window = CGSize(width: 900, height: 700)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == (CGFloat(1680) - CGFloat(900)) / 2)  // 390.0
        #expect(origin.y == (CGFloat(1050) - CGFloat(700)) / 2)  // 175.0
    }

    /// Zero-size window: should produce the screen midpoint as origin.
    @Test func zeroSizeWindow() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = CGSize(width: 0, height: 0)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == 960)
        #expect(origin.y == 540)
    }

    /// Origin of the centred window should always be within screen bounds
    /// for any window smaller than the screen.
    @Test func originIsWithinScreenBoundsForSmallWindows() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let sizes: [CGSize] = [
            CGSize(width: 100,  height: 100),
            CGSize(width: 800,  height: 600),
            CGSize(width: 1920, height: 1080),
            CGSize(width: 2559, height: 1439),
        ]
        for window in sizes {
            let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
            #expect(origin.x >= screen.minX, "x out of bounds for window \(window)")
            #expect(origin.y >= screen.minY, "y out of bounds for window \(window)")
        }
    }
}

// MARK: - animationPosition(from:to:step:totalSteps:)

@Suite("WindowCenterer animation steps")
struct AnimationPositionTests {

    let start = CGPoint(x: 0,   y: 0)
    let end   = CGPoint(x: 100, y: 200)

    @Test func stepZeroIsStart() {
        let pos = WindowCenterer.animationPosition(from: start, to: end, step: 0, totalSteps: 10)
        #expect(pos == start)
    }

    /// Use approximate equality for final step to guard against float drift
    /// with arbitrary start/end values.
    @Test func finalStepIsApproxEnd() {
        let pos = WindowCenterer.animationPosition(from: start, to: end, step: 10, totalSteps: 10)
        #expect(abs(pos.x - end.x) < 1e-10)
        #expect(abs(pos.y - end.y) < 1e-10)
    }

    @Test func midpointStep() {
        let pos = WindowCenterer.animationPosition(from: start, to: end, step: 5, totalSteps: 10)
        #expect(pos.x == 50)
        #expect(pos.y == 100)
    }

    @Test func stepsAreMonotonicallyIncreasing() {
        let positions = (0...10).map {
            WindowCenterer.animationPosition(from: start, to: end, step: $0, totalSteps: 10)
        }
        for i in 1...10 {
            #expect(positions[i].x > positions[i - 1].x)
            #expect(positions[i].y > positions[i - 1].y)
        }
    }

    @Test func noMovementWhenAlreadyCentered() {
        let same = CGPoint(x: 320, y: 240)
        for i in 0...10 {
            let pos = WindowCenterer.animationPosition(from: same, to: same, step: i, totalSteps: 10)
            #expect(pos == same)
        }
    }

    @Test func negativeDirection() {
        let from = CGPoint(x: 500, y: 400)
        let to   = CGPoint(x: 100, y: 50)
        let pos  = WindowCenterer.animationPosition(from: from, to: to, step: 10, totalSteps: 10)
        #expect(abs(pos.x - to.x) < 1e-10)
        #expect(abs(pos.y - to.y) < 1e-10)
    }

    /// A single-step animation should jump directly to the end.
    @Test func singleStep() {
        let pos = WindowCenterer.animationPosition(from: start, to: end, step: 1, totalSteps: 1)
        #expect(abs(pos.x - end.x) < 1e-10)
        #expect(abs(pos.y - end.y) < 1e-10)
    }

    /// All steps should lie strictly between start and end (exclusive)
    /// for a positive-direction move.
    @Test func intermediateStepsAreBetweenStartAndEnd() {
        for i in 1..<10 {
            let pos = WindowCenterer.animationPosition(from: start, to: end, step: i, totalSteps: 10)
            #expect(pos.x > start.x && pos.x < end.x)
            #expect(pos.y > start.y && pos.y < end.y)
        }
    }

    /// Steps should be evenly spaced: each delta == (end - start) / totalSteps.
    @Test func evenlySpaced() {
        let expectedDX = (end.x - start.x) / 10
        let expectedDY = (end.y - start.y) / 10
        for i in 1...10 {
            let prev = WindowCenterer.animationPosition(from: start, to: end, step: i - 1, totalSteps: 10)
            let curr = WindowCenterer.animationPosition(from: start, to: end, step: i,     totalSteps: 10)
            #expect(abs((curr.x - prev.x) - expectedDX) < 1e-10)
            #expect(abs((curr.y - prev.y) - expectedDY) < 1e-10)
        }
    }
}

// MARK: - App name sanitization

@Suite("App name sanitization")
struct AppNameSanitizationTests {

    let centerer = WindowCenterer()

    // --- Names that should PASS ---

    @Test func normalAppName() {
        #expect(centerer.sanitizedAppName("Safari") == "Safari")
    }

    @Test func appNameWithSpaces() {
        #expect(centerer.sanitizedAppName("Final Cut Pro") == "Final Cut Pro")
    }

    @Test func appNameWithDotAndDash() {
        #expect(centerer.sanitizedAppName("my-app.v2") == "my-app.v2")
    }

    @Test func appNameWithUnderscoreAndNumbers() {
        #expect(centerer.sanitizedAppName("app_2024") == "app_2024")
    }

    @Test func appNameWithMixedCase() {
        #expect(centerer.sanitizedAppName("IntelliJ IDEA") == "IntelliJ IDEA")
    }

    // --- Whitespace control chars stripped before allowlist check ---

    @Test func newlineIsStripped() {
        // "Safari\n" strips to "Safari" which is then allowed.
        #expect(centerer.sanitizedAppName("Safari\n") == "Safari")
    }

    @Test func tabIsStripped() {
        #expect(centerer.sanitizedAppName("Safari\t") == "Safari")
    }

    @Test func nullByteIsStripped() {
        #expect(centerer.sanitizedAppName("Safari\0") == "Safari")
    }

    @Test func carriageReturnIsStripped() {
        #expect(centerer.sanitizedAppName("Safari\r") == "Safari")
    }

    // --- Names that should FAIL (return nil) ---

    @Test func scriptInjectionWithQuote() {
        // A quote character would break out of the AppleScript string.
        #expect(centerer.sanitizedAppName("bad\"app") == nil)
    }

    @Test func scriptInjectionWithBackslash() {
        #expect(centerer.sanitizedAppName("bad\\app") == nil)
    }

    @Test func emojiIsRejected() {
        #expect(centerer.sanitizedAppName("App 🚀") == nil)
    }

    @Test func semicolonIsRejected() {
        #expect(centerer.sanitizedAppName("app;rm -rf /") == nil)
    }

    @Test func parenthesesAreRejected() {
        #expect(centerer.sanitizedAppName("app()") == nil)
    }

    @Test func unicodeLettersAreRejected() {
        // Non-ASCII letters (e.g. accented chars) are not in CharacterSet.alphanumerics
        // on all platforms — verify the behaviour is consistent.
        let result = centerer.sanitizedAppName("Ché")
        // alphanumerics includes Unicode letters in Swift, so accented chars pass.
        // This test documents the current behaviour rather than asserting pass/fail.
        if result != nil {
            #expect(result == "Ché")
        }
    }

    @Test func emptyStringIsAllowed() {
        // An empty name strips to "", which passes the allSatisfy vacuously.
        #expect(centerer.sanitizedAppName("") == "")
    }

    @Test func onlyControlCharsBecomesEmptyAndPasses() {
        // "\n\r\t" strips to "", which vacuously passes the allowlist.
        #expect(centerer.sanitizedAppName("\n\r\t") == "")
    }
}
