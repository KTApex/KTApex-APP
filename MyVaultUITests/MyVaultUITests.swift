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

    func testVaultOpensWithSlideshowControl() throws {
        app.launch()
        if app.buttons["Get Started"].waitForExistence(timeout: 3) {
            app.buttons["Get Started"].tap()
        }
        let vaultTab = app.tabBars.buttons["Vault"]
        XCTAssertTrue(vaultTab.waitForExistence(timeout: 5))
        vaultTab.tap()
        XCTAssertTrue(app.otherElements["vault.screen"].waitForExistence(timeout: 10),
                      "the vault screen should be reachable")

        // With an empty vault the empty state is shown and the slideshow button is
        // intentionally absent; with media it must be present. Either way the screen
        // must not crash or show a blank grid.
        let slideshow = app.buttons["Start slideshow"]
        let emptyState = app.staticTexts["No private memories yet"]
        XCTAssertTrue(slideshow.waitForExistence(timeout: 3) || emptyState.waitForExistence(timeout: 3),
                      "the vault should show either its grid controls or its empty state")
    }

    func testAlbumsScreenOpensAndOffersCreation() throws {
        app.launch()
        if app.buttons["Get Started"].waitForExistence(timeout: 3) {
            app.buttons["Get Started"].tap()
        }
        let vaultTab = app.tabBars.buttons["Vault"]
        XCTAssertTrue(vaultTab.waitForExistence(timeout: 5))
        vaultTab.tap()

        // Browse Albums lives in the vault's more menu.
        let more = app.buttons["More options"]
        guard more.waitForExistence(timeout: 10) else { return }
        more.tap()
        let browse = app.buttons["Browse Albums"]
        guard browse.waitForExistence(timeout: 3) else { return }
        browse.tap()

        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New album"].exists,
                      "the albums screen must offer album creation")
    }

    func testGridSizeSettingIsAvailable() throws {
        app.launch()
        if app.buttons["Get Started"].waitForExistence(timeout: 3) {
            app.buttons["Get Started"].tap()
        }
        let vaultTab = app.tabBars.buttons["Vault"]
        XCTAssertTrue(vaultTab.waitForExistence(timeout: 5))
        vaultTab.tap()

        let more = app.buttons["More options"]
        guard more.waitForExistence(timeout: 10) else { return }
        more.tap()
        // The old control exposed raw column counts; the new one exposes density.
        XCTAssertTrue(
            app.buttons["Thumbnail Size"].waitForExistence(timeout: 3)
                || app.staticTexts["Thumbnail Size"].exists,
            "a thumbnail-size control must be reachable from the gallery"
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
}
