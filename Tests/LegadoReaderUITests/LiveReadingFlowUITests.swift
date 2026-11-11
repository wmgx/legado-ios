import XCTest

@MainActor
final class LiveReadingFlowUITests: XCTestCase {
    private let app: XCUIApplication = {
        let app = XCUIApplication()
        // Xcode's runtime-issue callback can crash on Network.framework's log
        // quarantine with thousands of failing hosts. Keep server testing active.
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        return app
    }()

    func testSearchLatencyAndCachedQuery() throws {
        guard ProcessInfo.processInfo.environment["LEGADO_SEARCH_UI_BENCHMARK"] == "1" else {
            throw XCTSkip("Use the LegadoSearchPerformanceUITests scheme with the imported catalog")
        }
        continueAfterFailure = false
        app.launchArguments = ["-uiDemoTab", "search", "-uiAutomationSearch", "家父汉高祖", "-themeMode", "1"]
        let started = Date()
        app.launch()
        let exact = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "家父汉高祖, 历史系之狼")).firstMatch
        XCTAssertTrue(exact.waitForExistence(timeout: 90))
        print("[SearchPerformance] launch_to_exact_seconds=\(Date().timeIntervalSince(started))")
        attach("all-sources-search-latency")
        app.buttons["搜索选项"].tap()
        if app.buttons["停止搜索"].exists { app.buttons["停止搜索"].tap() }
        let search = app.searchFields["书名或作者"]
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "家父汉")
        let repeated = Date()
        search.typeText("\n")
        XCTAssertTrue(app.staticTexts["“家父汉”"].waitForExistence(timeout: 10))
        XCTAssertTrue(exact.exists)
        print("[SearchPerformance] cached_query_to_result_seconds=\(Date().timeIntervalSince(repeated))")
        attach("cached-search-result")
        exact.tap()
        XCTAssertTrue(app.navigationBars["书籍详情"].waitForExistence(timeout: 10))
        attach("detail-from-running-search")
    }

    func testImportSearchDetailReadSwitchAndResume() throws {
        guard ProcessInfo.processInfo.environment["LEGADO_LIVE_UI_TESTS"] == "1" else {
            throw XCTSkip("Use the LegadoLiveReadingUITests scheme for real-server testing")
        }
        continueAfterFailure = false
        defer {
            if (testRun?.failureCount ?? 0) > 0 {
                attach("failure")
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "failure-accessibility-tree"
                tree.lifetime = .keepAlways
                add(tree)
            }
        }
        app.launchArguments = ["-uiDemoTab", "search", "-uiAutomationSearch", "家父汉高祖", "-pageAnim", "0", "-themeMode", "1"]
        app.launch()
        XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 30))
        app.buttons["搜索选项"].tap()
        app.buttons["书源管理"].tap()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 10))
        app.buttons["添加书源"].firstMatch.tap()
        app.buttons["链接或 JSON"].tap()
        let url = app.textFields["https://example.com/sources.json"]
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        url.tap()
        url.typeText("https://raw.githubusercontent.com/tickmao/Novel/master/sources/legado/full.json")
        app.navigationBars["导入书源"].buttons["导入"].tap()
        XCTAssertTrue(app.navigationBars["书源导入预检"].waitForExistence(timeout: 120))
        app.navigationBars["书源导入预检"].buttons["选择"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        app.buttons["全选"].tap()
        attach("01-import-preview")
        XCTAssertTrue(app.navigationBars["书源导入预检"].buttons["导入"].isEnabled)
        app.navigationBars["书源导入预检"].buttons["导入"].tap()
        XCTAssertTrue(app.alerts["书源导入完成"].waitForExistence(timeout: 90))
        attach("02-import-completed")
        app.alerts.buttons["好"].tap()
        app.navigationBars["书源"].buttons.element(boundBy: 0).tap()
        selectSearchSource("https://www.aixiaxsw.com")
        let search = app.searchFields["书名或作者"]
        search.tap()
        search.typeText("\n")
        let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "家父汉高祖, 历史系之狼")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 90))
        attach("03-search")
        title.tap()
        XCTAssertTrue(app.navigationBars["书籍详情"].waitForExistence(timeout: 10))
        let start = app.buttons.matching(NSPredicate(format: "label IN %@", ["开始阅读", "继续阅读"])).firstMatch
        waitUntil("Readable directory", timeout: 90) { start.exists && start.isEnabled }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "历史系之狼")).firstMatch.exists)
        attach("04-detail")
        if app.buttons["加入书架"].exists {
            app.buttons["加入书架"].tap()
            XCTAssertTrue(app.buttons["已在书架"].waitForExistence(timeout: 10))
        }
        if app.buttons["继续阅读"].exists {
            let firstChapter = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "这娃一点也不像朕")).firstMatch
            XCTAssertTrue(firstChapter.exists)
            firstChapter.tap()
        } else {
            start.tap()
        }
        waitForBody(containing: "这娃一点也不像朕")
        attach("05-reading")
        let readingText = app.textViews["reader.text"].value as? String ?? ""
        showReaderMenu()
        app.buttons["更多"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        app.buttons["朗读设置"].tap()
        XCTAssertTrue(app.navigationBars["朗读设置"].waitForExistence(timeout: 10))
        let previewText = app.textFields["speech.previewText"]
        XCTAssertTrue(previewText.waitForExistence(timeout: 10))
        let excerpt = previewText.value as? String ?? ""
        XCTAssertGreaterThan(excerpt.count, 20)
        let bodyWithoutWhitespace = readingText.components(separatedBy: .whitespacesAndNewlines).joined()
        let excerptWithoutWhitespace = excerpt.components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertTrue(bodyWithoutWhitespace.contains(String(excerptWithoutWhitespace.prefix(40))))
        XCTAssertNotEqual(app.staticTexts["speech.rateValue"].label, "0.0×")
        app.buttons["1.5×"].tap()
        XCTAssertEqual(app.staticTexts["speech.rateValue"].label, "1.5×")
        let preview = app.buttons["speech.preview"]
        for _ in 0..<4 {
            if preview.isHittable { break }
            app.swipeUp()
        }
        preview.tap()
        waitUntil("Real chapter speech preview", timeout: 15) { preview.label.contains("停止试听") }
        attach("05a-real-chapter-speech-settings")
        preview.tap()
        app.navigationBars["朗读设置"].buttons["完成"].tap()
        showReaderMenu()
        let chapterProgress = app.sliders["reader.chapterProgress"]
        XCTAssertTrue(chapterProgress.exists)
        chapterProgress.adjust(toNormalizedSliderPosition: 0.5)
        showReaderMenu()
        app.buttons["下一章"].tap()
        waitForBody(containing: "隔壁家的太子")
        attach("06-next-chapter")
        showReaderMenu()
        app.buttons["换源"].tap()
        XCTAssertTrue(app.navigationBars["为《家父汉高祖》换源"].waitForExistence(timeout: 10))
        let firstVerified = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "sourceSwitch.candidate.", "历史系之狼", "目录和当前章节正文可读"
        )).firstMatch
        XCTAssertTrue(firstVerified.waitForExistence(timeout: 180))
        let replacement = app.buttons[firstVerified.identifier]
        let replacementName = String(replacement.label.components(separatedBy: ", ").first ?? "")
        XCTAssertFalse(replacementName.isEmpty)
        XCTAssertTrue(replacement.isEnabled)
        attach("07-source-candidates")
        replacement.tap()
        waitUntil("Source switch sheet dismissed", timeout: 90) {
            !self.app.navigationBars["为《家父汉高祖》换源"].exists
        }
        waitForBody(containing: "隔壁家的太子")
        showReaderMenu()
        waitUntil("Replacement source active", timeout: 20) {
            self.app.buttons["reader.changeSource"].value as? String == replacementName
        }
        attach("08-switched-reading")
        app.buttons["返回"].tap()
        app.terminate()
        app.launchArguments = ["-pageAnim", "0", "-themeMode", "1"]
        app.launch()
        let resume = app.buttons["bookshelf.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 30))
        resume.tap()
        waitForBody(containing: "隔壁家的太子")
        showReaderMenu()
        XCTAssertEqual(app.buttons["reader.changeSource"].value as? String, replacementName)
        attach("09-resumed-reading")
    }

    func testRealBookSpreadTapsAndLiveChapterScrubbing() throws {
        guard ProcessInfo.processInfo.environment["LEGADO_LIVE_UI_TESTS"] == "1" else {
            throw XCTSkip("Use the imported real book with the LegadoLiveReadingUITests scheme")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for mode in [0, 1, 3] {
            app.terminate()
            app.launchArguments = ["-pageAnim", String(mode), "-textSize", "32", "-themeMode", "1", "-screenOrientation", "0"]
            app.launch()
            let resume = app.buttons["bookshelf.continue"]
            XCTAssertTrue(resume.waitForExistence(timeout: 30))
            resume.tap()
            let body = mode == 3 ? app.collectionViews["reader.continuous"] : app.textViews["reader.text"]
            XCTAssertTrue(body.waitForExistence(timeout: 30))
            if mode != 3 { XCTAssertGreaterThan((body.value as? String ?? "").count, 500) }
            showReaderMenu()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "家父汉高祖")).firstMatch.exists)
            let progress = app.sliders["reader.chapterProgress"]
            progress.adjust(toNormalizedSliderPosition: 0)
            let start = progress.value as? String
            body.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()

            if XCUIDevice.shared.supportsPointerInteraction {
                // The inner edges of both leaves open the menu, including its top and bottom.
                for point in [CGVector(dx: 0.45, dy: 0.15), CGVector(dx: 0.55, dy: 0.85)] {
                    body.coordinate(withNormalizedOffset: point).tap()
                    XCTAssertTrue(app.buttons["换源"].waitForExistence(timeout: 5))
                    XCTAssertEqual(progress.value as? String, start)
                    body.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
                }
            }
            if mode != 3 {
                body.coordinate(withNormalizedOffset: .init(dx: 0.95, dy: 0.5)).tap()
                showReaderMenu()
                XCTAssertNotEqual(progress.value as? String, start)
                body.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
                body.coordinate(withNormalizedOffset: .init(dx: 0.05, dy: 0.5)).tap()
                showReaderMenu()
                XCTAssertEqual(progress.value as? String, start)
            }

            showReaderMenu()
            // The recording includes a slow drag and a hold before release for live-preview review.
            progress.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5))
                .press(forDuration: 0.2,
                       thenDragTo: progress.coordinate(withNormalizedOffset: .init(dx: 0.85, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 2)
            XCTAssertNotEqual(progress.value as? String, start)
            attach("real-book-live-chapter-scrub-mode-\(mode)")
        }
    }

    func testDownloadAndMainInterfaceReview() throws {
        guard ProcessInfo.processInfo.environment["LEGADO_LIVE_UI_TESTS"] == "1" else { throw XCTSkip("Requires the real book and catalog") }
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let theme = environment["LEGADO_REVIEW_THEME"] ?? "1"
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-themeMode", theme, "-readerTheme", theme == "2" ? "night" : "preset1", "-defaultHomePage", "bookshelf", "-screenOrientation", "0"]
        app.launch()
        for tab in ["书架", "发现", "统计", "我的"] {
            let button = app.buttons[tab].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 20))
            button.tap()
            let heading = tab == "统计" ? "阅读统计" : tab
            XCTAssertTrue(app.staticTexts["page.header.\(heading)"].waitForExistence(timeout: 10))
            attach("review-\(theme)-\(tab)")
        }
        app.buttons["书架"].firstMatch.tap()
        let resume = app.buttons["bookshelf.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        resume.tap()
        XCTAssertTrue(app.textViews["reader.text"].firstMatch.waitForExistence(timeout: 30))
        showReaderMenu()
        attach("review-\(theme)-reader-menu")
        app.buttons["目录"].tap()
        let drawer = app.otherElements["reader.toc.drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        XCTAssertLessThan(drawer.frame.width, app.frame.width * 0.9)
        let search = app.textFields["搜索章节"]
        let top = search.frame.minY
        drawer.swipeUp()
        XCTAssertEqual(search.frame.minY, top, accuracy: 1)
        app.buttons["定位当前章节"].tap()
        attach("review-\(theme)-directory")
        app.buttons["下载章节"].tap()
        XCTAssertTrue(app.navigationBars["下载章节"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls.buttons["整本书"].exists)
        attach("review-\(theme)-download-whole")
        if let requested = environment["LEGADO_REVIEW_DOWNLOAD_COUNT"], let count = Int(requested), count > 0 {
            app.buttons["download.start"].tap()
            XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 10))
            attach("review-\(theme)-download-whole-running")
            app.buttons["暂停"].tap()
            app.segmentedControls.buttons["从当前章起"].tap()
            app.buttons["\(count) 章"].tap()
            app.buttons["download.start"].tap()
            waitUntil("Download real chapters", timeout: 150) {
                let progress = self.app.descendants(matching: .any).matching(identifier: "download.progress").firstMatch
                return progress.exists && progress.value as? String == "\(count)/\(count)"
            }
            attach("review-\(theme)-download-complete")
        }
        app.buttons["完成"].tap()
        showReaderMenu()
        app.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["阅读设置"].waitForExistence(timeout: 5))
        for category in ["文字", "布局", "外观", "翻页"] {
            app.segmentedControls.buttons[category].tap()
            attach("review-\(theme)-settings-\(category)")
        }
        if XCUIDevice.shared.supportsPointerInteraction {
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 0.8) // UIKit can report idle before its rotation animation finishes.
            attach("review-\(theme)-landscape-settings")
            XCUIDevice.shared.orientation = .portrait
            Thread.sleep(forTimeInterval: 0.8)
        }
        app.buttons["完成"].tap()
        showReaderMenu()
        app.buttons["目录"].tap()
        app.buttons["筛选章节"].tap()
        app.buttons["已下载"].firstMatch.tap()
        waitUntil("Chapter filter menu closes", timeout: 5) { !self.app.buttons["全部章节"].exists }
        attach("review-\(theme)-downloaded-filter")
        app.buttons["关闭"].tap()
        showReaderMenu()
        app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons["bookshelf.continue"].waitForExistence(timeout: 10))
        app.buttons["我的"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["page.header.我的"].waitForExistence(timeout: 10))
        let profile = app.scrollViews["profile.scroll"]
        let sources = app.buttons["profile.globe"]
        for _ in 0..<5 {
            if sources.exists && sources.frame.minY > 100 && sources.frame.maxY < app.frame.maxY - 100 { break }
            profile.swipeUp()
        }
        sources.tap()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 10))
        attach("review-\(theme)-sources")
        app.buttons["返回"].tap()
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        let speech = app.buttons["profile.waveform"]
        for _ in 0..<4 {
            if speech.exists && speech.frame.minY > 100 && speech.frame.maxY < app.frame.maxY - 100 { break }
            profile.swipeDown()
        }
        speech.tap()
        XCTAssertTrue(app.navigationBars["朗读设置"].waitForExistence(timeout: 10))
        attach("review-\(theme)-speech")
        app.buttons["管理在线引擎"].tap()
        XCTAssertTrue(app.navigationBars["朗读引擎"].waitForExistence(timeout: 10))
        attach("review-\(theme)-engines")
        app.buttons["返回"].tap()
        XCTAssertTrue(app.navigationBars["朗读设置"].waitForExistence(timeout: 5))
        app.navigationBars["朗读设置"].buttons.firstMatch.tap()
        XCTAssertTrue(profile.waitForExistence(timeout: 10))

    }

    func testRealBookReadingPlaybackAdvances() throws {
        guard ProcessInfo.processInfo.environment["LEGADO_LIVE_UI_TESTS"] == "1" else { throw XCTSkip("Requires configured real book and TTS") }
        continueAfterFailure = false
        app.launchArguments = ["-defaultHomePage", "bookshelf", "-screenOrientation", "0", "-uiMuteSpeech"]
        app.launch()
        let resume = app.buttons["bookshelf.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20)); resume.tap()
        XCTAssertTrue(app.textViews["reader.text"].firstMatch.waitForExistence(timeout: 30))
        showReaderMenu(); app.buttons["朗读"].tap()
        XCTAssertFalse(app.navigationBars["朗读设置"].exists)
        XCTAssertTrue(app.buttons["暂停朗读"].waitForExistence(timeout: 30))
        waitUntil("Audio buffering finishes", timeout: 45) { !self.app.progressIndicators["正在准备音频"].exists }
        let progress = app.sliders["reader.chapterProgress"]
        let initial = progress.value as? String
        waitUntil("Real audio completes a segment", timeout: 60) { progress.value as? String != initial }
        attach("real-book-reading-playback")
        app.buttons["暂停朗读"].tap()
        XCTAssertTrue(app.buttons["继续朗读"].waitForExistence(timeout: 5))
        let paused = progress.value as? String
        app.buttons["继续朗读"].tap()
        waitUntil("Resumed audio completes another segment", timeout: 60) { progress.value as? String != paused }
        app.buttons["朗读设置"].tap()
        XCTAssertTrue(app.navigationBars["朗读设置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["speech.preview"].exists)
        app.buttons["完成"].tap()
        app.buttons["停止朗读"].tap()
    }

    func testCustomTTSServiceConfigurationAndPreview() throws {
        guard ProcessInfo.processInfo.environment["LEGADO_LIVE_UI_TESTS"] == "1" else { throw XCTSkip("Requires the configured Home TTS engine and real book") }
        continueAfterFailure = false
        let theme = ProcessInfo.processInfo.environment["LEGADO_REVIEW_THEME"] ?? "1"
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-defaultHomePage", "bookshelf", "-screenOrientation", "0", "-themeMode", theme,
                               "-readerTheme", theme == "2" ? "night" : "preset1"]
        app.launch()
        let resume = app.buttons["bookshelf.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20)); resume.tap()
        XCTAssertTrue(app.textViews["reader.text"].firstMatch.waitForExistence(timeout: 30))
        showReaderMenu(); app.buttons["朗读"].tap()
        XCTAssertTrue(app.buttons["朗读设置"].waitForExistence(timeout: 10))
        app.buttons["朗读设置"].tap()
        let configure = app.buttons["声音与连接"]
        XCTAssertTrue(configure.waitForExistence(timeout: 10)); configure.tap()
        let address = app.textFields["speech.serviceAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        app.buttons["清空服务地址"].tap()
        address.tap(); address.typeText("tts.wmgx.top")
        app.buttons["speech.serviceConnect"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "speech.serviceConnection").firstMatch.waitForExistence(timeout: 25))
        app.buttons["speech.serviceVoice"].tap()
        app.buttons["晓晓 · 女声"].tap()
        let preview = app.buttons["speech.servicePreview"]
        if preview.frame.maxY > app.frame.maxY - 70 { app.swipeUp() }
        preview.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "speech.servicePlayback").firstMatch.waitForExistence(timeout: 45))
        attach("custom-service-\(theme)-real-book-preview")
        preview.tap()
        app.buttons["speech.serviceVoice"].tap(); app.buttons["云希 · 男声"].tap()
        app.navigationBars["声音与连接"].buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["朗读设置"].waitForExistence(timeout: 10))
        configure.tap()
        let key = app.secureTextFields["speech.serviceKey"]
        XCTAssertTrue(key.waitForExistence(timeout: 10)); key.tap(); key.typeText("invalid")
        app.buttons["speech.serviceConnect"].tap()
        let error = app.staticTexts["speech.serviceError"]
        XCTAssertTrue(error.waitForExistence(timeout: 20)); XCTAssertTrue(error.label.contains("检查密钥"))
        attach("custom-service-\(theme)-invalid-key")
        app.navigationBars["声音与连接"].buttons["取消"].tap()
        app.buttons["放弃修改"].tap()
        XCTAssertTrue(app.navigationBars["朗读设置"].waitForExistence(timeout: 5))
        waitUntil("Service configuration dismissed", timeout: 5) { !address.exists && configure.isHittable }
        configure.tap()
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        app.buttons["speech.serviceConnect"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "speech.serviceConnection").firstMatch.waitForExistence(timeout: 25))
        app.navigationBars["声音与连接"].buttons["取消"].tap()
        app.buttons["管理在线引擎"].tap()
        let service = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "speech.configure.")).firstMatch
        XCTAssertTrue(service.waitForExistence(timeout: 10)); service.tap()
        XCTAssertTrue(app.navigationBars["声音与连接"].waitForExistence(timeout: 10))
        let advanced = app.buttons["高级规则"]
        for _ in 0..<6 {
            if advanced.exists && advanced.isHittable { break }
            app.swipeUp()
        }
        advanced.tap()
        XCTAssertTrue(app.collectionViews["speech.engineForm"].waitForExistence(timeout: 10))
        app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "高级规则 · ")).firstMatch.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["声音与连接"].waitForExistence(timeout: 5))
        app.navigationBars["声音与连接"].buttons["取消"].tap()
        app.buttons["添加引擎"].tap(); app.buttons["连接自建服务"].tap()
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["连接自建服务"].buttons["保存"].isEnabled)
        attach("custom-service-\(theme)-add-form")
        app.buttons["取消"].tap()
    }

    func testImportedTTSCollectionPlayback() throws {
        guard ProcessInfo.processInfo.environment["LEGADO_LIVE_UI_TESTS"] == "1" else { throw XCTSkip("Requires the imported TTS collection and real book") }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-defaultHomePage", "bookshelf", "-screenOrientation", "0"]
        app.launch()
        let resume = app.buttons["bookshelf.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        resume.tap()
        XCTAssertTrue(app.textViews["reader.text"].firstMatch.waitForExistence(timeout: 30))
        showReaderMenu()
        app.buttons["朗读"].tap()
        XCTAssertTrue(app.buttons["朗读设置"].waitForExistence(timeout: 10))
        app.buttons["朗读设置"].tap()
        XCTAssertGreaterThan((app.textFields["speech.previewText"].value as? String ?? "").count, 20)
        app.buttons["管理在线引擎"].tap()
        app.buttons["更多"].tap()
        app.buttons["清除朗读缓存"].tap()
        let search = app.searchFields["搜索引擎名称"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("思必驰\n")
        let preview = app.buttons["speech.preview.1632019596388"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        XCTAssertTrue(app.staticTexts["speech.enginePlayback"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.staticTexts["speech.enginePlayback"].exists)
        attach("imported-dui-real-book-playing")
        preview.tap()
        search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "PER4126\n")
        app.buttons["speech.preview.1617429726281"].tap()
        let result = app.staticTexts["speech.engineError"]
        waitUntil("Imported Baidu engine failure", timeout: 25) { result.exists && result.label.contains("鉴权失败") }
        attach("imported-baidu-upstream-error")
    }

    func testHomeTTSProtocolImportAndRealBookPlayback() throws {
        guard let json = ProcessInfo.processInfo.environment["LEGADO_HOME_TTS_IMPORT_JSON"],
              #available(iOS 16.4, *) else { throw XCTSkip("Requires the local Home TTS service and real-book fixture") }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-pageAnim", "3", "-themeMode", "1", "-screenOrientation", "0"]
        app.launch()
        if let collectionURL = ProcessInfo.processInfo.environment["LEGADO_TTS_COLLECTION_URL"] {
            var collectionLink = URLComponents(string: "legado://import/httpTTS")!
            collectionLink.queryItems = [.init(name: "src", value: collectionURL)]
            XCUIDevice.shared.system.open(try XCTUnwrap(collectionLink.url))
            XCTAssertTrue(app.staticTexts["speech.importCount"].waitForExistence(timeout: 45))
            XCTAssertTrue(app.staticTexts["speech.importCount"].label.contains("55/55"))
            attach("legacy-tts-collection-preview")
            app.navigationBars["导入朗读引擎"].buttons["导入"].tap()
            XCTAssertTrue(app.navigationBars["导入完成"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["已导入 55 个引擎"].exists)
            app.buttons["完成"].tap()
        }
        var link = URLComponents(string: "legado://import/httpTTS")!
        link.queryItems = [.init(name: "src", value: json)]
        XCUIDevice.shared.system.open(try XCTUnwrap(link.url))
        XCTAssertTrue(app.navigationBars["导入朗读引擎"].waitForExistence(timeout: 20))
        let selected = app.switches.firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        if selected.value as? String == "0" { selected.tap() }
        attach("home-tts-import-preview")
        app.navigationBars["导入朗读引擎"].buttons["导入"].tap()
        XCTAssertTrue(app.navigationBars["导入完成"].waitForExistence(timeout: 10))
        app.buttons["完成"].tap()
        let resume = app.buttons["bookshelf.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        resume.tap()
        XCTAssertTrue(app.collectionViews["reader.continuous"].waitForExistence(timeout: 30))
        showReaderMenu()
        app.buttons["朗读"].tap()
        XCTAssertTrue(app.buttons["朗读设置"].waitForExistence(timeout: 10))
        app.buttons["朗读设置"].tap()
        let sample = app.textFields["speech.previewText"].value as? String ?? ""
        XCTAssertGreaterThan(sample.count, 20)
        let manage = app.buttons["管理在线引擎"]
        for _ in 0..<5 {
            if manage.exists && manage.frame.height > 0 && manage.frame.maxY < app.frame.maxY - 80 && manage.frame.minY > 100 { break }
            app.swipeUp()
        }
        manage.tap()
        XCTAssertTrue(app.navigationBars["朗读引擎"].waitForExistence(timeout: 10))
        let id = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])?.first?["id"] as? Int64)
        let preview = app.buttons["speech.preview.\(id)"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.tap()
        XCTAssertTrue(app.staticTexts["speech.enginePlayback"].waitForExistence(timeout: 60))
        attach("home-tts-real-book-playing")
        preview.tap()
        app.buttons["选择"].tap()
        app.buttons["speech.select.\(id)"].tap()
        app.buttons["测试"].tap()
        waitUntil("Home audio probe", timeout: 20) { self.app.staticTexts["speech.testResult.\(id)"].label == "音频可播放" }
        attach("tts-selection-actions")
        app.buttons["删除"].tap()
        XCTAssertTrue(app.alerts["删除朗读引擎？"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        app.navigationBars.buttons["取消"].tap()
        app.buttons["添加引擎"].tap()
        app.buttons["连接自建服务"].tap()
        XCTAssertTrue(app.textFields["speech.serviceAddress"].waitForExistence(timeout: 10))
        attach("tts-simple-service-form")
        app.buttons["取消"].tap()
        app.buttons["添加引擎"].tap()
        app.buttons["扫码添加"].tap()
        XCTAssertTrue(app.navigationBars["二维码导入"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["从照片选择二维码"].exists)
        app.buttons["取消"].tap()
    }

    func testReaderSelectionPurificationAndReadingControls() throws {
        guard ProcessInfo.processInfo.environment["LEGADO_LIVE_UI_TESTS"] == "1" else { throw XCTSkip("Requires the imported real book") }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let mode = ProcessInfo.processInfo.environment["LEGADO_SELECTION_MODE"] ?? "3"
        app.launchArguments = ["-pageAnim", mode, "-themeMode", ProcessInfo.processInfo.environment["LEGADO_READER_THEME_MODE"] ?? "1", "-readerTheme", ProcessInfo.processInfo.environment["LEGADO_READER_THEME"] ?? "night", "-screenOrientation", "0", "-defaultHomePage", "bookshelf"]
        app.launch()
        let resume = app.buttons["bookshelf.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        resume.tap()
        let text = app.textViews["reader.text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 30))
        let original = text.value as? String ?? ""
        showReaderMenu()
        app.buttons["下一章"].tap()
        waitUntil("Next chapter while menu stays open", timeout: 30) { text.exists && (text.value as? String ?? "").count > 30 && text.value as? String != original }
        XCTAssertTrue(app.buttons["上一章"].exists)
        app.buttons["上一章"].tap()
        waitUntil("Previous chapter while menu stays open", timeout: 30) { text.exists && text.value as? String == original }
        XCTAssertTrue(app.buttons["下一章"].exists)
        app.buttons["目录"].tap()
        let toc = app.otherElements["reader.toc.drawer"]
        XCTAssertTrue(toc.waitForExistence(timeout: 5))
        XCTAssertLessThan(toc.frame.width, app.frame.width * 0.9)
        XCTAssertTrue(app.buttons["reader.toc.current"].waitForExistence(timeout: 5))
        let search = app.textFields["搜索章节"]
        let searchY = search.frame.minY
        toc.swipeUp()
        XCTAssertEqual(search.frame.minY, searchY, accuracy: 1)
        XCTAssertLessThanOrEqual(app.buttons["定位当前章节"].frame.maxX, toc.frame.maxX)
        app.buttons["定位当前章节"].tap()
        attach("reader-side-drawer")
        app.coordinate(withNormalizedOffset: .init(dx: 0.96, dy: 0.5)).tap()
        XCTAssertFalse(toc.exists)
        showReaderMenu()
        app.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["阅读设置"].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["翻页"].tap()
        let top = app.switches["顶部返回章首"]
        for _ in 0..<4 { if top.exists { break }; app.swipeUp() }
        XCTAssertEqual(top.value as? String, "0")
        top.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(top.value as? String, "1")
        top.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(top.value as? String, "0")
        app.segmentedControls.buttons["外观"].tap()
        let systemBrightness = app.switches["使用系统亮度"]
        for _ in 0..<5 {
            if systemBrightness.exists && systemBrightness.isHittable { break }
            app.collectionViews["reader.settingsForm"].swipeUp()
        }
        XCTAssertTrue(systemBrightness.exists)
        if systemBrightness.value as? String == "1" { systemBrightness.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertTrue(app.sliders["阅读亮度"].waitForExistence(timeout: 3))
        systemBrightness.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(systemBrightness.value as? String, "1")
        attach("reader-system-brightness-settings")
        app.segmentedControls.buttons["翻页"].tap()
        app.buttons["点击区域设置"].tap()
        XCTAssertTrue(app.buttons["恢复等分"].waitForExistence(timeout: 5))
        let divider = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "左侧分界线")).firstMatch
        XCTAssertTrue(divider.exists)
        let from = divider.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.45))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(.init(dx: 30, dy: 0)))
        attach("reader-transparent-tap-zones")
        app.buttons["恢复等分"].tap()
        app.buttons["完成"].tap()
        let before = text.value as? String ?? ""
        app.coordinate(withNormalizedOffset: .init(dx: 0.3, dy: 0.34)).press(forDuration: 1.2)
        let add = app.buttons["添加净化规则"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["复制"].exists)
        attach("reader-selection-menu")
        add.tap()
        let name = app.textFields["名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["使用正则表达式"].value as? String, "0")
        let oldName = name.value as? String ?? ""
        name.coordinate(withNormalizedOffset: .init(dx: 0.98, dy: 0.5)).tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count) + "CodexSelectedTextAcceptance-20261111")
        attach("reader-selection-rule-draft")
        app.buttons["保存"].tap()
        waitUntil("Saved purification updates the current chapter", timeout: 20) { text.exists && !(text.value as? String ?? "").isEmpty && text.value as? String != before }
        attach("reader-selection-rule-applied")
    }

    func testPortraitSettingsAndEngineEditorRemainScrollable() throws {
        guard ProcessInfo.processInfo.environment["LEGADO_LIVE_UI_TESTS"] == "1" else {
            throw XCTSkip("Use the imported real book with the LegadoLiveReadingUITests scheme")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-pageAnim", "3", "-themeMode", "1", "-screenOrientation", "0"]
        app.launch()
        let resume = app.buttons["bookshelf.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 30))
        resume.tap()
        let reader = app.collectionViews["reader.continuous"]
        XCTAssertTrue(reader.waitForExistence(timeout: 30))
        let initialPosition = (reader.value as? String ?? "").split(separator: " ").prefix(2)
        if XCUIDevice.shared.supportsPointerInteraction { reader.scroll(byDeltaX: 0, deltaY: 500) }
        else { reader.swipeUp() }
        XCTAssertNotEqual((reader.value as? String ?? "").split(separator: " ").prefix(2), initialPosition)
        showReaderMenu()
        app.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["阅读设置"].waitForExistence(timeout: 10))
        attach("portrait-reader-settings-initial")
        let settingsForm = app.collectionViews["reader.settingsForm"]
        XCTAssertGreaterThan(settingsForm.frame.height, app.frame.height * 0.65)
        app.segmentedControls.buttons["翻页"].tap()
        let clickSettings = app.buttons["点击区域设置"]
        for _ in 0..<6 {
            if clickSettings.exists && clickSettings.isHittable { break }
            app.collectionViews["reader.settingsForm"].swipeUp()
        }
        attach("portrait-reader-settings-scrolled")
        XCTAssertTrue(clickSettings.isHittable)
        app.buttons["完成"].tap()
        showReaderMenu()
        app.buttons["朗读"].tap()
        XCTAssertTrue(app.buttons["朗读设置"].waitForExistence(timeout: 10))
        app.buttons["朗读设置"].tap()
        let engines = app.buttons["管理在线引擎"]
        for _ in 0..<6 {
            if engines.exists && engines.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(engines.isHittable)
        engines.tap()
        app.buttons["添加引擎"].tap()
        app.buttons["手动编辑规则"].tap()
        XCTAssertTrue(app.navigationBars["新建在线朗读引擎"].waitForExistence(timeout: 10))
        let editor = app.collectionViews["speech.engineForm"]
        XCTAssertGreaterThan(editor.frame.height, app.frame.height * 0.65)
        app.buttons["高级配置"].tap()
        attach("portrait-engine-editor-initial")
        let script = app.textViews["登录检查 JS"]
        for _ in 0..<10 {
            if script.exists && script.isHittable && script.frame.maxY < editor.frame.maxY - 36 { break }
            if XCUIDevice.shared.supportsPointerInteraction { editor.scroll(byDeltaX: 0, deltaY: 500) }
            else { editor.swipeUp() }
        }
        attach("portrait-engine-editor-scrolled")
        XCTAssertTrue(script.isHittable)
        XCTAssertLessThan(script.frame.maxY, editor.frame.maxY - 36)
        script.tap()
        script.typeText("// 竖屏编辑验证")
        XCTAssertTrue((script.value as? String ?? "").contains("竖屏编辑验证"))
        if !XCUIDevice.shared.supportsPointerInteraction {
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            XCTAssertLessThan(script.frame.minY + 25, keyboard.frame.minY)
        }
        attach("portrait-engine-editor-keyboard")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.navigationBars["新建在线朗读引擎"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["取消"].isHittable)
        attach("landscape-engine-editor-keyboard")
        app.buttons["取消"].tap()
        app.buttons["放弃修改"].tap()
        XCUIDevice.shared.orientation = .portrait
    }

    private func selectSearchSource(_ sourceID: String) {
        app.buttons["搜索选项"].tap()
        if app.buttons["停止搜索"].exists {
            app.buttons["停止搜索"].tap()
            app.buttons["搜索选项"].tap()
        }
        app.buttons["分组或书源"].tap()
        app.segmentedControls.buttons["书源"].tap()
        let filter = app.searchFields["筛选书源"]
        filter.tap()
        filter.typeText(sourceID)
        let source = app.staticTexts[sourceID].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        app.buttons["确定"].tap()
    }

    private func waitForBody(containing chapter: String) {
        let body = app.textViews["reader.text"]
        waitUntil("Body of \(chapter)", timeout: 90) {
            guard body.exists, body.isHittable else { return false }
            let value = body.value as? String ?? ""
            return value.contains(chapter) && value.count > 500
        }
        let value = body.value as? String ?? ""
        XCTAssertGreaterThan(value.components(separatedBy: "\n").count, 5)
        XCTAssertFalse(value.contains("<p>"))
        XCTAssertFalse(value.contains(#"\r\n"#))
    }

    private func showReaderMenu() {
        if !app.buttons["换源"].exists {
            let continuous = app.collectionViews["reader.continuous"]
            let surface = continuous.exists ? continuous : app.textViews["reader.text"]
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons["换源"].waitForExistence(timeout: 10))
    }

    private func waitUntil(_ name: String, timeout: TimeInterval, condition: @escaping () -> Bool) {
        let ready = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        ready.expectationDescription = name
        wait(for: [ready], timeout: timeout)
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
