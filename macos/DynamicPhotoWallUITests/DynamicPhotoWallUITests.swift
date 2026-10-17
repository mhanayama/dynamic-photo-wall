import XCTest

final class DynamicPhotoWallUITests: XCTestCase {
    @MainActor
    func testAlbumSelectionCanBeCancelledAndSavedWithoutFolders() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DPW_UI_TEST_PROFILE"] = UUID().uuidString
        app.launch(); app.activate()
        defer { app.terminate() }
        func openPhotos() {
            let tab = app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "Photos")).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.click()
        }
        func addAlbum() {
            app.buttons["アルバムを追加"].click()
            let album = app.staticTexts["旅行（テスト）"].firstMatch
            XCTAssertTrue(album.waitForExistence(timeout: 5)); album.click()
            app.buttons["選択したアルバムを追加"].click()
        }
        openPhotos()
        addAlbum()
        XCTAssertTrue(app.staticTexts["選択したアルバムの写真: 1枚"].waitForExistence(timeout: 5))
        let removeAlbum = app.buttons["アルバムを削除: 旅行（テスト）"]
        XCTAssertTrue(removeAlbum.exists)
        app.buttons["変更を取り消す"].click()
        XCTAssertFalse(removeAlbum.exists)
        addAlbum()
        let removeFolders = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "remove-folder-"))
        removeFolders.firstMatch.click()
        removeFolders.firstMatch.click()
        app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "Display")).firstMatch.click()
        app.buttons["表示停止"].click()
        openPhotos()
        app.buttons["保存して適用"].click()
        app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "Display")).firstMatch.click()
        let pause = app.buttons["一時停止"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: pause)
        waitForExpectations(timeout: 5)
        app.terminate(); app.launch(); app.activate()
        openPhotos()
        XCTAssertTrue(removeAlbum.waitForExistence(timeout: 5))
        XCTAssertEqual(removeFolders.count, 0)
        app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "Display")).firstMatch.click()
        XCTAssertTrue(app.buttons["保存して表示開始"].isEnabled)
    }

    @MainActor
    func testFolderDeletionPersistsThroughRelaunchIncludingLastSource() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DPW_UI_TEST_PROFILE"] = UUID().uuidString
        app.launch()
        app.activate()
        defer { app.terminate() }

        func openPhotos() {
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            let tab = app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "Photos")).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            tab.click()
        }
        func removeButtons() -> XCUIElementQuery {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "remove-folder-"))
        }
        openPhotos()
        XCTAssertTrue(removeButtons().firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(removeButtons().count, 2)
        removeButtons().element(boundBy: 0).click()
        XCTAssertEqual(removeButtons().count, 1)
        app.buttons["保存して適用"].click()
        app.terminate()
        app.launch()
        openPhotos()
        XCTAssertEqual(removeButtons().count, 1)
        removeButtons().firstMatch.click()
        XCTAssertEqual(removeButtons().count, 0)
        app.buttons["保存して適用"].click()
        app.terminate()
        app.launch()
        openPhotos()
        XCTAssertEqual(removeButtons().count, 0)
        app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "Display")).firstMatch.click()
        XCTAssertFalse(app.buttons["保存して表示開始"].isEnabled)
    }
    @MainActor
    func testUnsavedFolderDeletionIsCancelledAndPlaybackControlsWork() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DPW_UI_TEST_PROFILE"] = UUID().uuidString
        app.launch(); app.activate()
        defer { app.terminate() }
        let photos = app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "Photos")).firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 5)); photos.click()
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "remove-folder-"))
        XCTAssertEqual(remove.count, 2)
        remove.firstMatch.click()
        XCTAssertEqual(remove.count, 1)
        app.buttons["変更を取り消す"].click()
        XCTAssertEqual(remove.count, 2)
        app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "Display")).firstMatch.click()
        app.buttons["表示停止"].click()
        let start = app.buttons["保存して表示開始"]
        XCTAssertTrue(start.isEnabled); start.click()
        let pause = app.buttons["一時停止"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5)); XCTAssertTrue(pause.isEnabled)
        pause.click()
        XCTAssertTrue(app.buttons["再開"].exists)
        app.buttons["次の構成"].click()
        app.buttons["再開"].click()
        XCTAssertTrue(pause.exists)
        app.buttons["表示停止"].click()
        XCTAssertFalse(pause.isEnabled)
    }

    @MainActor
    func testClosingSettingsCancelsDraftAndReopensOnlyOneWindow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DPW_UI_TEST_PROFILE"] = UUID().uuidString
        app.launch(); app.activate()
        defer { app.terminate() }
        let photos = app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "Photos")).firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 5)); photos.click()
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "remove-folder-"))
        remove.firstMatch.click()
        XCTAssertEqual(remove.count, 1)
        app.windows.firstMatch.buttons["_XCUI:CloseWindow"].click()
        XCTAssertEqual(app.windows.count, 0)
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(photos.waitForExistence(timeout: 5)); photos.click()
        XCTAssertEqual(remove.count, 2)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 1)
    }

}
