import Testing
import Cocoa
import ApplicationServices
@testable import Centered

@Suite("AX and AppKit coordinate conversion")
struct AXCoordinateTests {
    @Test func primaryVisibleFrameIncludesTopAndBottomReservations() {
        let frame = WindowCenterer.accessibilityRect(
            fromAppKit: CGRect(x: 0, y: 50, width: 1440, height: 826), primaryScreenTop: 900
        )
        #expect(frame == CGRect(x: 0, y: 24, width: 1440, height: 826))
        #expect(WindowCenterer.centeredOrigin(windowSize: CGSize(width: 800, height: 600), in: frame)
            == CGPoint(x: 320, y: 137))
    }

    @Test func verticallyStackedAndNegativeOriginScreens() {
        let upper = WindowCenterer.accessibilityRect(
            fromAppKit: CGRect(x: -300, y: 900, width: 1200, height: 800), primaryScreenTop: 900
        )
        let lower = WindowCenterer.accessibilityRect(
            fromAppKit: CGRect(x: 0, y: -800, width: 1200, height: 800), primaryScreenTop: 900
        )
        #expect(upper == CGRect(x: -300, y: -800, width: 1200, height: 800))
        #expect(lower == CGRect(x: 0, y: 900, width: 1200, height: 800))
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(WindowCenterer.bestScreenIndex(
            containing: CGRect(x: 100, y: -700, width: 400, height: 300),
            screenRects: [primary, upper, lower]
        ) == 1)
        #expect(WindowCenterer.bestScreenIndex(
            containing: CGRect(x: 100, y: 1100, width: 400, height: 300),
            screenRects: [primary, upper, lower]
        ) == 2)
    }

    @Test func conversionIsItsOwnInverse() {
        let rect = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let converted = WindowCenterer.accessibilityRect(fromAppKit: rect, primaryScreenTop: 900)
        #expect(WindowCenterer.accessibilityRect(fromAppKit: converted, primaryScreenTop: 900) == rect)
    }
}

@Suite("Position write failure propagation")
struct PositionWriteTests {
    @Test func rejectedWriteReturnsFailure() {
        let element = AXUIElementCreateSystemWide()
        var calls = 0
        let result = AXPositionWriter.write(CGPoint(x: 100, y: 200), to: element) { _, _, _ in
            calls += 1
            return .cannotComplete
        }
        #expect(!result)
        #expect(calls == 1)
    }

    @Test func successfulWriteUsesPositionAttributeAndExactPoint() {
        let element = AXUIElementCreateSystemWide()
        let expected = CGPoint(x: -200, y: 450)
        let result = AXPositionWriter.write(expected, to: element) { _, attribute, raw in
            #expect(attribute as String == kAXPositionAttribute)
            #expect(CFGetTypeID(raw) == AXValueGetTypeID())
            let value = unsafeBitCast(raw, to: AXValue.self)
            var point = CGPoint()
            #expect(AXValueGetValue(value, .cgPoint, &point))
            #expect(point == expected)
            return .success
        }
        #expect(result)
    }

    @MainActor
    @Test func failureCompletesOnlyOnceAndCannotBecomeSuccess() {
        var results: [WindowPositioningResult] = []
        let operation = WindowPositioningOperation { results.append($0) }
        operation.finish(.failed)
        operation.finish(.succeeded)
        #expect(operation.result == .failed)
        #expect(results == [.failed])
    }

    @MainActor
    @Test func cancellationIsNotReportedAsAWriteFailure() {
        var results: [WindowPositioningResult] = []
        let operation = WindowPositioningOperation { results.append($0) }
        operation.finish(.cancelled)
        operation.finish(.failed)
        #expect(results == [.cancelled])
    }
}
