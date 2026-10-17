import XCTest

final class MyVaultUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--uitesting")
    }

    func testOnboardingAppearsOnFirstLaunch() throws {
        app.launch()
        XCTAssertTrue(app.staticTexts["MyVault"].waitForExistence(timeout: 5))
    }

    func testTabNavigation() throws {
        app.launch()
        // Dismiss onboarding if present.
        if app.buttons["Get Started"].waitForExistence(timeout: 3) {
            app.buttons["Get Started"].tap()
        }
        for tab in ["Home", "Vault", "Special Days", "Settings"] {
            let btn = app.tabBars.buttons[tab]
            if btn.waitForExistence(timeout: 3) { btn.tap() }
        }
    }

    func testAddSpecialDayFlow() throws {
        app.launch()
        if app.buttons["Get Started"].waitForExistence(timeout: 3) {
            app.buttons["Get Started"].tap()
        }
        let specialTab = app.tabBars.buttons["Special Days"]
        guard specialTab.waitForExistence(timeout: 5) else { return }
        specialTab.tap()
        let add = app.buttons["Add special day"]
        if add.waitForExistence(timeout: 3) { add.tap() }
    }

    func testVaultNavigation() throws {
        app.launch()
        if app.buttons["Get Started"].waitForExistence(timeout: 3) {
            app.buttons["Get Started"].tap()
        }
        let vaultTab = app.tabBars.buttons["Vault"]
        XCTAssertTrue(vaultTab.waitForExistence(timeout: 5))
        vaultTab.tap()

        // The Vault screen's import button is always present in its toolbar, so it is
        // a reliable marker of the screen itself. Checking it avoids depending on how
        // a TabView reports its navigation bar, and on SwiftData store
        // initialisation timing on a simulator.
        let importButton = app.buttons["Import photos or videos"]
        XCTAssertTrue(
            importButton.waitForExistence(timeout: 10),
            "Tapping the Vault tab should reveal the vault screen"
        )
    }

    func testSettingsOpens() throws {
        app.launch()
        if app.buttons["Get Started"].waitForExistence(timeout: 3) {
            app.buttons["Get Started"].tap()
        }
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
    }
}
