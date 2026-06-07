import Testing
import Cocoa
import CoreGraphics
@testable import Centered

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

    @Test func windowLargerThanScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let window = CGSize(width: 1920, height: 1080)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == CGFloat(1280) / 2 - CGFloat(1920) / 2)
        #expect(origin.y == CGFloat(800)  / 2 - CGFloat(1080) / 2)
        #expect(origin.x < 0)
        #expect(origin.y < 0)
    }

    @Test func nonIntegerScreenDimensions() {
        let screen = CGRect(x: 0, y: 0, width: 1680, height: 1050)
        let window = CGSize(width: 900, height: 700)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == (CGFloat(1680) - CGFloat(900)) / 2)
        #expect(origin.y == (CGFloat(1050) - CGFloat(700)) / 2)
    }

    @Test func zeroSizeWindow() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = CGSize(width: 0, height: 0)
        let origin = WindowCenterer.centeredOrigin(windowSize: window, in: screen)
        #expect(origin.x == 960)
        #expect(origin.y == 540)
    }

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

@Suite("WindowCenterer animation steps")
struct AnimationPositionTests {

    let start = CGPoint(x: 0,   y: 0)
    let end   = CGPoint(x: 100, y: 200)

    @Test func stepZeroIsStart() {
        let pos = WindowCenterer.animationPosition(from: start, to: end, step: 0, totalSteps: 10)
        #expect(pos == start)
    }

    @Test func finalStepIsApproxEnd() {
        let pos = WindowCenterer.animationPosition(from: start, to: end, step: 10, totalSteps: 10)
        #expect(abs(pos.x - end.x) < 1e-10)
        #expect(abs(pos.y - end.y) < 1e-10)
    }

    @Test func midpointStepUsesCubicEaseOut() {
        let pos = WindowCenterer.animationPosition(from: start, to: end, step: 5, totalSteps: 10)
        #expect(abs(pos.x - 87.5) < 1e-10)
        #expect(abs(pos.y - 175) < 1e-10)
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

    @Test func singleStep() {
        let pos = WindowCenterer.animationPosition(from: start, to: end, step: 1, totalSteps: 1)
        #expect(abs(pos.x - end.x) < 1e-10)
        #expect(abs(pos.y - end.y) < 1e-10)
    }

    @Test func intermediateStepsAreBetweenStartAndEnd() {
        for i in 1..<10 {
            let pos = WindowCenterer.animationPosition(from: start, to: end, step: i, totalSteps: 10)
            #expect(pos.x > start.x && pos.x < end.x)
            #expect(pos.y > start.y && pos.y < end.y)
        }
    }

    @Test func easeOutDeltasDecrease() {
        var previousDX = CGFloat.greatestFiniteMagnitude
        var previousDY = CGFloat.greatestFiniteMagnitude

        for i in 1...10 {
            let prev = WindowCenterer.animationPosition(from: start, to: end, step: i - 1, totalSteps: 10)
            let curr = WindowCenterer.animationPosition(from: start, to: end, step: i,     totalSteps: 10)
            let dx = curr.x - prev.x
            let dy = curr.y - prev.y

            #expect(dx > 0)
            #expect(dy > 0)
            #expect(dx <= previousDX)
            #expect(dy <= previousDY)

            previousDX = dx
            previousDY = dy
        }
    }

    @Test func negativeStepClampsToStart() {
        let pos = WindowCenterer.animationPosition(from: start, to: end, step: -1, totalSteps: 10)
        #expect(pos == start)
    }

    @Test func stepAfterEndClampsToEnd() {
        let pos = WindowCenterer.animationPosition(from: start, to: end, step: 11, totalSteps: 10)
        #expect(abs(pos.x - end.x) < 1e-10)
        #expect(abs(pos.y - end.y) < 1e-10)
    }

    @Test func zeroTotalStepsReturnsEnd() {
        let pos = WindowCenterer.animationPosition(from: start, to: end, step: 0, totalSteps: 0)
        #expect(pos == end)
    }
}

@Suite("AppleScript bundle ID validation")
struct AppleScriptBundleIDValidationTests {

    @Test func normalBundleIDPasses() {
        #expect(WindowCenterer.isValidAppleScriptBundleID("com.apple.Safari"))
    }

    @Test func bundleIDWithDashPasses() {
        #expect(WindowCenterer.isValidAppleScriptBundleID("com.example.my-app"))
    }

    @Test func bundleIDWithUnderscoreFails() {
        #expect(!WindowCenterer.isValidAppleScriptBundleID("com.example.my_app"))
    }

    @Test func emptyBundleIDFails() {
        #expect(!WindowCenterer.isValidAppleScriptBundleID(""))
    }

    @Test func overlongBundleIDFails() {
        #expect(!WindowCenterer.isValidAppleScriptBundleID(String(repeating: "a", count: 256)))
    }

    @Test func quoteInjectionFails() {
        #expect(!WindowCenterer.isValidAppleScriptBundleID("com.example.\"bad"))
    }

    @Test func backslashInjectionFails() {
        #expect(!WindowCenterer.isValidAppleScriptBundleID("com.example.\\bad"))
    }

    @Test func whitespaceFails() {
        #expect(!WindowCenterer.isValidAppleScriptBundleID("com.example.bad\n"))
    }

    @Test func unicodeLetterFails() {
        #expect(!WindowCenterer.isValidAppleScriptBundleID("com.example.Ché"))
    }
}


@Suite("HotKeyBinding preference decoding")
struct HotKeyBindingPreferenceDecodingTests {

    @Test func validDictionaryDecodes() {
        let decoded = HotKeyBinding(dictionary: ["keyCode": 8, "modifiers": NSEvent.ModifierFlags.command.rawValue])
        #expect(decoded?.keyCode == 8)
        #expect(decoded?.modifiers == .command)
    }

    @Test func negativeKeyCodeIsRejected() {
        #expect(HotKeyBinding(dictionary: ["keyCode": -1, "modifiers": UInt(0)]) == nil)
    }

    @Test func oversizedKeyCodeIsRejected() {
        #expect(HotKeyBinding(dictionary: ["keyCode": Int(UInt16.max) + 1, "modifiers": UInt(0)]) == nil)
    }

    @Test func persistedModifiersAreLimitedToSupportedShortcutFlags() {
        let raw = NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.numericPad.rawValue
        let decoded = HotKeyBinding(dictionary: ["keyCode": 8, "modifiers": raw])
        #expect(decoded?.modifiers == .command)
    }
}

@Suite("WindowCenterer display selection")
struct DisplaySelectionTests {

    @Test func picksScreenWithLargestWindowOverlap() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 1000, y: 0, width: 1000, height: 800),
        ]
        let window = CGRect(x: 900, y: 100, width: 300, height: 300)
        #expect(WindowCenterer.bestScreenIndex(containing: window, screenRects: screens) == 1)
    }

    @Test func picksNearestScreenWhenWindowHasNoOverlap() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 1200, y: 0, width: 1000, height: 800),
        ]
        let window = CGRect(x: 2300, y: 100, width: 300, height: 300)
        #expect(WindowCenterer.bestScreenIndex(containing: window, screenRects: screens) == 1)
    }

    @Test func emptyScreenListReturnsNil() {
        let window = CGRect(x: 0, y: 0, width: 300, height: 300)
        #expect(WindowCenterer.bestScreenIndex(containing: window, screenRects: []) == nil)
    }

    @Test func nearFullScreenWindowsAreSkipped() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(WindowCenterer.isEffectivelyFullScreen(windowSize: CGSize(width: 1420, height: 890), in: screen))
        #expect(!WindowCenterer.isEffectivelyFullScreen(windowSize: CGSize(width: 900, height: 700), in: screen))
    }
}

@Suite("DefaultSettings persistence")
struct DefaultSettingsPersistenceTests {

    @Test func hotkeysUseDocumentedDefaults() {
        let suite = UserDefaults(suiteName: "CenteredTests.hotkeysUseDocumentedDefaults")!
        suite.removePersistentDomain(forName: "CenteredTests.hotkeysUseDocumentedDefaults")
        var settings = DefaultSettings(defaults: suite)
        settings.reset()

        #expect(settings.centerActiveBinding == .centerActive)
        #expect(settings.centerAllBinding == .centerAll)
    }

    @Test func behaviorSettingsPersist() {
        let suiteName = "CenteredTests.behaviorSettingsPersist"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        var settings = DefaultSettings(defaults: suite)
        settings.reset()

        settings.isAutoCenteringPaused = true
        settings.centersOnWindowScreen = false
        settings.animationStyle = .instant

        let reloaded = DefaultSettings(defaults: suite)
        #expect(reloaded.isAutoCenteringPaused)
        #expect(!reloaded.centersOnWindowScreen)
        #expect(reloaded.animationStyle == .instant)
    }

    @Test func exclusionsRejectInvalidBundleIDs() {
        let suiteName = "CenteredTests.exclusionsRejectInvalidBundleIDs"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        var settings = DefaultSettings(defaults: suite)
        settings.reset()

        settings.excludedBundleIDs = ["com.example.safe", "com.example.bad\ncom.apple.Terminal"]

        #expect(settings.excludedBundleIDs == ["com.example.safe"])
        #expect(suite.stringArray(forKey: UserDefaults.Key.excludedBundleIDs) == ["com.example.safe"])
    }

    @Test func tamperedInvalidExclusionsFailClosed() {
        let suiteName = "CenteredTests.tamperedInvalidExclusionsFailClosed"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        var settings = DefaultSettings(defaults: suite)
        settings.reset()

        settings.excludedBundleIDs = ["com.example.safe"]
        suite.set(["com.example.safe", "com.example.bad\ncom.apple.Terminal"], forKey: UserDefaults.Key.excludedBundleIDs)

        #expect(settings.excludedBundleIDs.isEmpty)
    }
}
