import XCTest

final class TortugaAppUITests: XCTestCase {
    func testLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-didShowWelcome", "YES", "-openWindowAtLaunch", "YES", "-showInDock", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["mode.tor"].firstMatch.waitForExistence(timeout: 10))
    }
}
