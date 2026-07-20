import XCTest

final class CubasePreferenceUtilityUITests: XCTestCase {
    @MainActor
    func testDashboardExposesPrimaryActions() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Cubase Preference Utility"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Back Up Now"].exists)
        XCTAssertTrue(app.buttons["Open Backup"].exists)
        XCTAssertTrue(app.staticTexts["Settings Folders"].exists)
        XCTAssertTrue(app.staticTexts["Backup History"].exists)
    }
}
