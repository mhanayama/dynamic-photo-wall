import XCTest

final class DynamicPhotoWallUITests: XCTestCase {
    @MainActor
    func testNetworkSettingsAreAvailableWithoutStartingCommunication() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DPW_UI_TEST_PROFILE"] = UUID().uuidString
        app.launch(); app.activate()
        defer { app.terminate() }
        let tab = app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "ネットワーク")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.click()
        let online = app.descendants(matching: .any).matching(identifier: "network-online").firstMatch
        XCTAssertTrue(online.waitForExistence(timeout: 5))
        XCTAssertTrue(online.isEnabled)
        XCTAssertTrue(app.staticTexts["オフライン"].exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "network-settings-offline"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["変更を取り消す"].click()
        XCTAssertTrue(app.staticTexts["オフライン"].exists)
    }
    @MainActor
    func testAlbumSelectionCanBeCancelledAndSavedWithoutFolders() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DPW_UI_TEST_PROFILE"] = UUID().uuidString
        app.launch(); app.activate()
        defer { app.terminate() }
        func openPhotos() {
            let tab = app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "写真")).firstMatch
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
        app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "一般")).firstMatch.click()
        app.buttons["表示停止"].click()
        openPhotos()
        app.buttons["保存して適用"].click()
        app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "一般")).firstMatch.click()
        let pause = app.buttons["一時停止"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: pause)
        waitForExpectations(timeout: 5)
        app.terminate(); app.launch(); app.activate()
        openPhotos()
        XCTAssertTrue(removeAlbum.waitForExistence(timeout: 5))
        XCTAssertEqual(removeFolders.count, 0)
        app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "一般")).firstMatch.click()
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
            let tab = app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "写真")).firstMatch
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
        app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "一般")).firstMatch.click()
        XCTAssertFalse(app.buttons["保存して表示開始"].isEnabled)
    }
    @MainActor
    func testUnsavedFolderDeletionIsCancelledAndPlaybackControlsWork() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DPW_UI_TEST_PROFILE"] = UUID().uuidString
        app.launch(); app.activate()
        defer { app.terminate() }
        let photos = app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "写真")).firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 5)); photos.click()
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "remove-folder-"))
        XCTAssertEqual(remove.count, 2)
        remove.firstMatch.click()
        XCTAssertEqual(remove.count, 1)
        app.buttons["変更を取り消す"].click()
        XCTAssertEqual(remove.count, 2)
        app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "一般")).firstMatch.click()
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
        let photos = app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", "写真")).firstMatch
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

    @MainActor
    func testDisplayGroupsDeleteEmptyAndLastGroupsAndPreviewRemainsAcrossSettingsClose() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DPW_UI_TEST_PROFILE"] = UUID().uuidString
        app.launch(); app.activate()
        defer { app.terminate() }
        func tab(_ name: String) {
            let item = app.descendants(matching: .tab).matching(NSPredicate(format: "label == %@", name)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5)); item.click()
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        tab("使用ディスプレイ")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "display-enabled-2").firstMatch.waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "display-enabled-2").firstMatch.click()
        tab("画面グルーピング")
        app.buttons["グループを追加"].click()
        capture("group-settings")
        XCTAssertTrue(app.buttons["delete-group-グループ1"].exists)
        app.buttons["delete-group-グループ1"].click()
        XCTAssertFalse(app.buttons["delete-group-グループ1"].exists)
        app.buttons["グループを追加"].click()
        app.buttons["保存して適用"].click()
        app.terminate(); app.launch(); app.activate()
        tab("画面グルーピング")
        XCTAssertTrue(app.buttons["delete-group-グループ1"].exists)
        let preview = app.buttons["test-pattern-toggle"]
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -1000)
        XCTAssertTrue(preview.waitForExistence(timeout: 5)); preview.click()
        XCTAssertEqual(preview.label, "表示停止")
        capture("test-pattern-active")
        app.windows.firstMatch.buttons["_XCUI:CloseWindow"].click()
        app.activate(); app.typeKey(",", modifierFlags: .command)
        tab("画面グルーピング")
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -1000)
        XCTAssertEqual(preview.label, "表示停止")
        preview.click(); XCTAssertEqual(preview.label, "表示")
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 1000)
        app.buttons["delete-group-グループ1"].click()
        app.buttons["保存して適用"].click()
        app.terminate(); app.launch(); app.activate()
        tab("画面グルーピング")
        XCTAssertFalse(app.buttons["delete-group-グループ1"].exists)
        tab("表示モード")
        for id in ["galleryPerDisplay", "galleryScrollPerDisplay", "verticalPanPerDisplay", "horizontalPanPerDisplay", "zoomPerDisplay"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: id).firstMatch.exists)
        }
        capture("per-display-mode-settings")
        tab("動き")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "faceAwarePanDirection").firstMatch.exists)
    }

}
