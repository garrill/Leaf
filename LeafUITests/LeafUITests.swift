//
//  LeafUITests.swift
//  LeafUITests
//
//  Created by Jonny Garrill on 20/07/2026.
//

import XCTest

final class LeafUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    /// `-uiTestReset` (handled in `AppDelegate.resetStateIfRequestedForUITesting()`) wipes the
    /// app's `UserDefaults` domain on launch so every test starts from a clean, repo-less
    /// sidebar rather than whatever state a previous run or the developer's own usage left behind.
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestReset"]
        app.launch()
        return app
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testWindowTitleIsLeafOnFreshLaunch() throws {
        let app = launchApp()

        let window = app.windows["Leaf"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
    }

    @MainActor
    func testEmptyStateShowsAddRepositoryPrompt() throws {
        let app = launchApp()

        XCTAssertTrue(app.staticTexts["No Repositories"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add local repository"].exists)
    }

    @MainActor
    func testAddRepositoryButtonOpensAndCancelsFilePicker() throws {
        let app = launchApp()

        let addButton = app.buttons["Add local repository"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        // NSOpenPanel surfaces as its own sheet/window with a "Cancel" button.
        let cancelButton = app.dialogs.buttons["Cancel"].firstMatch
        let cancelButtonExists = cancelButton.waitForExistence(timeout: 5)
        XCTAssertTrue(cancelButtonExists)
        if cancelButtonExists {
            cancelButton.click()
        }

        // Cancelling shouldn't have added anything — the empty state should still be showing.
        XCTAssertTrue(app.staticTexts["No Repositories"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsWindowOpens() throws {
        let app = launchApp()

        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(app.staticTexts["Font Size"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["External Editor"].exists || app.staticTexts["Choose…"].exists)
    }

    @MainActor
    func testRepositoryMenuHasExpectedItems() throws {
        let app = launchApp()

        let repositoryMenuBarItem = app.menuBarItems["Repository"]
        XCTAssertTrue(repositoryMenuBarItem.waitForExistence(timeout: 5))
        repositoryMenuBarItem.click()

        for title in ["Push", "Pull", "Fetch", "Remove", "Show in Finder", "Rename", "Choose Icon…"] {
            XCTAssertTrue(app.menuItems[title].exists, "Expected a \"\(title)\" item in the Repository menu")
        }

        // Dismiss the open menu so it doesn't linger into the next test.
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testSidebarToggleMenuItemExists() throws {
        let app = launchApp()

        let viewMenu = app.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5))
        viewMenu.click()

        let toggleItem = app.menuItems["Hide Sidebar"].exists ? app.menuItems["Hide Sidebar"] : app.menuItems["Show Sidebar"]
        XCTAssertTrue(toggleItem.exists)

        app.typeKey(.escape, modifierFlags: [])
    }
}
