import XCTest

final class TortugaAppUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-scenario", scenario, "-didShowWelcome", "YES",
                               "-openWindowAtLaunch", "YES", "-showInDock", "YES"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Click an element once it's there (screens change a moment after a click).
    private func press(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "no \(id)", file: file, line: line)
        target.click()
    }

    private func waitFor(_ element: XCUIElement, labelContaining text: String, timeout: TimeInterval = 15) {
        // On macOS a StaticText's words are its value, not its label.
        let found = expectation(for: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text),
                                evaluatedWith: element)
        wait(for: [found], timeout: timeout)
    }

    /// New apps join the top of the list and push the others down; wait for
    /// the last of the four so a click lands on the row it aims at.
    private func waitForAllApps(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "route.row.com.apple.Music").waitForExistence(timeout: 10))
    }

    /// Keep a screenshot of the window in the test results, for looking at.
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTorOnAppsAppearAndNewCircuitChangesTheExit() {
        let app = launch("normal")
        press(app, "mode.tor")
        waitFor(element(app, "status"), labelContaining: "Tor on")
        let row = element(app, "route.row.com.apple.Safari")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        waitForAllApps(app)
        let exit = element(app, "row.exit.com.apple.Safari")
        let before = exit.value as? String ?? ""
        XCTAssertFalse(before.isEmpty)
        row.click()
        press(app, "circuit.com.apple.Safari")
        let changed = expectation(for: NSPredicate(format: "value != %@", before), evaluatedWith: exit)
        wait(for: [changed], timeout: 5)
        sleep(5)
        snap(app, "route")
    }

    func testRouteScreenHasTheMap() {
        let app = launch("normal")
        press(app, "mode.tor")
        waitFor(element(app, "status"), labelContaining: "Tor on")
        waitForAllApps(app)
        let map = element(app, "route.map")
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        XCTAssertTrue(map.label.contains("Safari:"), map.label)
        XCTAssertTrue(element(app, "route.guard").exists)
        snap(app, "map")
    }

    func testTorDiesThenRestartBringsItBack() {
        let app = launch("torDies")
        press(app, "mode.tor")
        waitFor(element(app, "status"), labelContaining: "Tor on")
        waitFor(element(app, "status"), labelContaining: "traffic is blocked")
        snap(app, "blocked")
        press(app, "restart")
        waitFor(element(app, "status"), labelContaining: "Tor on")
    }

    func testABadObfs4LineIsMarkedAndAGoodOneSaved() {
        let app = launch("normal")
        press(app, "sidebar.bridges")
        press(app, "bridge.obfs4")
        let lines = element(app, "bridges.obfs4.lines")
        XCTAssertTrue(lines.waitForExistence(timeout: 5))
        lines.click()
        lines.typeText("obfs4 192.0.2.1:443 nope")
        XCTAssertTrue(element(app, "bridges.error").waitForExistence(timeout: 3))
        snap(app, "bridges-error")
        lines.typeKey("a", modifierFlags: .command)
        lines.typeKey(.delete, modifierFlags: [])
        lines.typeText("obfs4 192.0.2.1:443 " + String(repeating: "A", count: 40) + " cert=x iat-mode=0")
        XCTAssertTrue(element(app, "bridges.error").waitForNonExistence(timeout: 3))
        press(app, "bridges.obfs4.save")
        waitFor(element(app, "bridges.obfs4.count"), labelContaining: "1 saved", timeout: 5)
    }
}
