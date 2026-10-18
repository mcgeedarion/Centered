import XCTest

final class CenteredUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false

    }

    override func tearDownWithError() throws {
    }

    @MainActor
    func testApplicationLaunchesAndRemainsRunning() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertNotEqual(app.state, .notRunning)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
