import XCTest

/// End-to-end UI tests. The app runs with `--mock-device`, an in-memory phone
/// that speaks real MTP, so these need no hardware.
final class SendbayUITests: XCTestCase {
    private var app: XCUIApplication!
    private var importFolder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        importFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sendbay-ui-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        // `-key value` arguments override UserDefaults for this launch only.
        app.launchArguments = ["--mock-device", "-importFolder", importFolder.path, "-showHidden", "NO"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: importFolder)
    }

    private var table: XCUIElement { app.tables["fileTable"] }

    private func row(_ name: String) -> XCUIElement { table.staticTexts[name] }

    func testShowsStoragesAndRootFolder() {
        XCTAssertTrue(app.staticTexts["Internal shared storage"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["SD card"].exists)
        XCTAssertTrue(row("DCIM").waitForExistence(timeout: 5))
        XCTAssertTrue(row("Download").exists)
        // Hidden folders stay hidden by default.
        XCTAssertFalse(row(".thumbnails").exists)
    }

    func testNavigatesIntoFoldersAndBack() {
        XCTAssertTrue(row("DCIM").waitForExistence(timeout: 10))
        row("DCIM").doubleClick()
        XCTAssertTrue(row("Camera").waitForExistence(timeout: 5))
        row("Camera").doubleClick()
        XCTAssertTrue(row("IMG_20261029_000001.jpg").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["DCIM"].exists, "path bar shows parent folder")

        app.typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(row("Camera").waitForExistence(timeout: 5))
        app.buttons["Internal shared storage"].firstMatch.click()
        XCTAssertTrue(row("DCIM").waitForExistence(timeout: 5))
    }

    func testSwitchesStorage() {
        XCTAssertTrue(app.staticTexts["SD card"].waitForExistence(timeout: 10))
        app.staticTexts["SD card"].click()
        XCTAssertTrue(row("Movies").waitForExistence(timeout: 5))
        XCTAssertFalse(row("DCIM").exists)
    }

    func testCreatesFolder() {
        XCTAssertTrue(row("DCIM").waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: [.command, .shift])
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Backups")
        app.buttons["Create"].click()
        XCTAssertTrue(row("Backups").waitForExistence(timeout: 5))
    }

    func testDeletesWithConfirmation() {
        XCTAssertTrue(row("Music").waitForExistence(timeout: 10))
        row("Music").click()
        app.typeKey(.delete, modifierFlags: .command)
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(waitForDisappearance(row("Music")))
    }

    func testImportsPhotosOnceAndSkipsDuplicates() throws {
        let button = app.buttons["importPhotosButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        XCTAssertTrue(app.staticTexts["Imported 7 new items"].waitForExistence(timeout: 15))
        let files = try FileManager.default.contentsOfDirectory(atPath: importFolder.path)
        XCTAssertEqual(files.count, 7)
        XCTAssertTrue(files.contains("VID_20261029_120000.mp4"))

        button.click()
        XCTAssertTrue(app.staticTexts["No new photos or videos to import"].waitForExistence(timeout: 15))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: importFolder.path).count, 7)
    }

    func testSearchFiltersCurrentFolder() {
        XCTAssertTrue(row("DCIM").waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("down")
        XCTAssertTrue(row("Download").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForDisappearance(row("DCIM")))
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }
}
