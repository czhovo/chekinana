import XCTest
import UIKit

@MainActor
final class ChekinanaProductShellUITests: XCTestCase {
    private var app: XCUIApplication!
    private let screenshotDirectory = URL(fileURLWithPath: "/tmp/chekinana-product-visual-review", isDirectory: true)

    override func setUpWithError() throws {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(
            at: screenshotDirectory,
            withIntermediateDirectories: true
        )
    }

    func testFocusedProductSmokeEnglish() {
        runFocusedProductSmoke(
            language: "en",
            locale: "en_US",
            screenshotSuffix: "en"
        )
    }

    func testFocusedProductSmokeJapanese() {
        runFocusedProductSmoke(
            language: "ja",
            locale: "ja_JP",
            screenshotSuffix: "ja"
        )
    }

    func testFocusedProductSmokeSimplifiedChinese() {
        runFocusedProductSmoke(
            language: "zh-Hans",
            locale: "zh_Hans_CN",
            screenshotSuffix: "zh-hans"
        )
    }

    func testFocusedProductSmokeLargeDynamicType() {
        runFocusedProductSmoke(
            language: "en",
            locale: "en_US",
            screenshotSuffix: "large-type",
            contentSizeCategory: "UICTContentSizeCategoryAccessibilityL"
        )
    }

    func testAppLanguageSwitchesImmediatelyPersistsAndCalendarDaysStayNumeric() {
        launch(fixture: "data")
        tapTab("Calendar")
        let selectedDate = element("chekinana.calendar.selected-date")
        XCTAssertTrue(selectedDate.waitForExistence(timeout: 4))
        let leadingDate = app.buttons["chekinana.calendar.day.2026-07-31"]
        XCTAssertTrue(leadingDate.waitForExistence(timeout: 4))
        leadingDate.tap()
        XCTAssertTrue(waitUntil(timeout: 4) {
            (selectedDate.value as? String) == "2026-07-31"
        })

        openDrawer()
        app.buttons["chekinana.shell.drawer.settings"].tap()
        XCTAssertTrue(element("chekinana.settings.page").waitForExistence(timeout: 4))

        let languagePicker = element("chekinana.settings.language.picker")
        languagePicker.tap()
        let japaneseOption = element("chekinana.settings.language.option.ja")
        let chineseOption = element("chekinana.settings.language.option.zh-Hans")
        XCTAssertTrue(japaneseOption.waitForExistence(timeout: 4))
        XCTAssertTrue(chineseOption.exists)
        XCTAssertFalse(element("chekinana.settings.language.option.en").exists)
        japaneseOption.tap()
        XCTAssertTrue(waitUntil(timeout: 4) {
            self.element("chekinana.settings.language.picker").value as? String == "ja"
        })
        XCTAssertTrue(waitUntil(timeout: 4) {
            self.app.buttons["chekinana.settings.done"].label == "完了"
        })
        XCTAssertTrue(app.navigationBars["設定"].exists)
        app.buttons["chekinana.settings.done"].tap()

        XCTAssertTrue(element("chekinana.calendar.page").waitForExistence(timeout: 4))
        XCTAssertEqual(selectedDate.value as? String, "2026-07-31")
        XCTAssertTrue(app.navigationBars["カレンダー"].exists)
        let dayNumber = element("chekinana.calendar.day-number.2026-08-02")
        XCTAssertTrue(dayNumber.waitForExistence(timeout: 4))
        XCTAssertEqual(dayNumber.label, "2")
        XCTAssertFalse(dayNumber.label.contains("日"))

        let expectedJapaneseTabs: [(String, String)] = [
            ("scan", "スキャン"),
            ("idols", "Idol"),
            ("calendar", "カレンダー"),
            ("events", "イベント"),
            ("gallery", "ギャラリー"),
        ]
        for (rawValue, label) in expectedJapaneseTabs {
            XCTAssertEqual(
                app.buttons["chekinana.shell.tab.\(rawValue)"].label,
                label
            )
        }
        tapTab("Events")
        XCTAssertTrue(app.navigationBars["イベント"].exists)
        tapTab("Gallery")
        XCTAssertTrue(app.navigationBars["ギャラリー"].exists)
        tapTab("Calendar")
        XCTAssertEqual(selectedDate.value as? String, "2026-07-31")

        app.terminate()
        app.launch()
        XCTAssertTrue(element("chekinana.shell.root").waitForExistence(timeout: 8))
        openDrawer()
        app.buttons["chekinana.shell.drawer.settings"].tap()
        XCTAssertTrue(element("chekinana.settings.page").waitForExistence(timeout: 4))
        XCTAssertEqual(
            element("chekinana.settings.language.picker").value as? String,
            "ja"
        )
        XCTAssertEqual(app.buttons["chekinana.settings.done"].label, "完了")

        selectAppLanguage("system")
        XCTAssertEqual(
            element("chekinana.settings.language.picker").value as? String,
            "system"
        )
        app.buttons["chekinana.settings.done"].tap()
    }

    func testCalendarCrossMonthCellSelectsDateWithoutChangingMonthPage() {
        launch(fixture: "data")
        tapTab("Calendar")

        let month = element("chekinana.calendar.month")
        let selectedDate = element("chekinana.calendar.selected-date")
        XCTAssertTrue(month.waitForExistence(timeout: 4))
        XCTAssertTrue(selectedDate.waitForExistence(timeout: 4))
        let displayedMonthTitle = month.label

        let leadingDate = app.buttons["chekinana.calendar.day.2026-07-31"]
        XCTAssertTrue(leadingDate.waitForExistence(timeout: 4))
        XCTAssertTrue(leadingDate.isHittable)
        leadingDate.tap()

        XCTAssertTrue(waitUntil(timeout: 4) {
            (selectedDate.value as? String) == "2026-07-31"
        })
        XCTAssertEqual(month.label, displayedMonthTitle)
        XCTAssertTrue(leadingDate.isSelected)
    }

    func testCalendarExactCombinationVisualFixtureOpensUnifiedEditorAndViewer() {
        launch(fixture: "calendar-groups")
        tapTab("Calendar")

        let groupedRow = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.calendar.group.combination-"
            )
        ).firstMatch
        XCTAssertTrue(groupedRow.waitForExistence(timeout: 4))
        groupedRow.tap()

        let groupEditor = element("chekinana.calendar.group-editor")
        XCTAssertTrue(groupEditor.waitForExistence(timeout: 4))
        XCTAssertGreaterThanOrEqual(
            app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "chekinana.calendar.group-editor.cheki-media."
                )
            ).count,
            2
        )
        XCTAssertTrue(
            app.buttons["chekinana.calendar.group-editor.save"]
                .waitForExistence(timeout: 4)
        )
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(
                format: "identifier ENDSWITH %@",
                ".save"
            )).count,
            1
        )
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "chekinana.calendar.group-editor.record.",
                ".delete"
            )).count,
            2
        )

        let firstMedia = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.calendar.group-editor.cheki-media."
            )
        ).firstMatch
        firstMedia.tap()
        XCTAssertTrue(
            app.buttons["chekinana.gallery.editor.save"]
                .waitForExistence(timeout: 4)
        )
        XCTAssertFalse(element("chekinana.cheki.viewer").exists)
    }

    func testCalendarChekiViewerPhysicalTapOpensExactEditorButSwipeDoesNot() {
        launch(fixture: "calendar-groups")
        tapTab("Calendar")

        app.swipeUp()
        XCTAssertFalse(element("chekinana.cheki.viewer").exists)
        XCTAssertFalse(element("chekinana.calendar.group-editor").exists)
        app.swipeDown()

        let groupRows = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.calendar.group.combination-"
            )
        ).allElementsBoundByIndex
        let multiRow = groupRows.first {
            $0.label.contains("Airi") && $0.label.contains("Mina")
        }
        XCTAssertNotNil(multiRow)
        guard let multiRow else { return }

        let gestureDebug = element(
            multiRow.identifier.replacingOccurrences(
                of: "chekinana.calendar.group.",
                with: "chekinana.calendar.debug.group-gesture."
            )
        )
        XCTAssertTrue(gestureDebug.waitForExistence(timeout: 4))
        let layoutState = gestureDebug.value as? String ?? "missing"
        let layoutDimensions = layoutState
            .replacingOccurrences(of: "layout:", with: "")
            .split(separator: "x")
            .compactMap { Double($0) }
        XCTAssertEqual(layoutDimensions.count, 2, "Unexpected surface state: \(layoutState)")
        if layoutDimensions.count == 2 {
            XCTAssertGreaterThan(layoutDimensions[0], 0, "Surface width: \(layoutState)")
            XCTAssertGreaterThan(layoutDimensions[1], 0, "Surface height: \(layoutState)")
            XCTAssertGreaterThanOrEqual(
                layoutDimensions[0],
                multiRow.frame.width,
                "Gesture surface must cover at least the row's primary content width."
            )
            XCTAssertEqual(
                layoutDimensions[1],
                multiRow.frame.height,
                accuracy: 2,
                "Gesture surface must cover the complete row height."
            )
        }

        let thumbnails = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.calendar.thumbnail."
            )
        ).allElementsBoundByIndex.filter {
            abs($0.frame.midY - multiRow.frame.midY) < 8
        }.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertGreaterThanOrEqual(thumbnails.count, 2)
        if layoutDimensions.count == 2, let lastThumbnail = thumbnails.last {
            let visibleContentWidth = lastThumbnail.frame.maxX - multiRow.frame.minX
            XCTAssertGreaterThanOrEqual(
                layoutDimensions[0] + 2,
                visibleContentWidth,
                "Gesture surface must also cover the trailing thumbnail strip."
            )
        }
        guard let thumbnail = thumbnails.first else { return }
        let chekiID = String(
            thumbnail.identifier.dropFirst("chekinana.calendar.thumbnail.".count)
        )

        thumbnail.tap()
        let viewer = element("chekinana.cheki.viewer")
        XCTAssertTrue(
            viewer.waitForExistence(timeout: 4),
            "Viewer did not appear; gesture state: \(gestureDebug.value as? String ?? "missing")"
        )
        let pageIdentifier = "chekinana.cheki.viewer.page.\(chekiID)"
        let page = element(pageIdentifier)
        XCTAssertTrue(page.waitForExistence(timeout: 4))
        page.swipeLeft()
        XCTAssertFalse(
            element("chekinana.gallery.editor").waitForExistence(timeout: 1),
            "A paging swipe must not be interpreted as an editing tap."
        )
        app.buttons["chekinana.cheki.viewer.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) {
            !self.element("chekinana.cheki.viewer").exists
        })

        element("chekinana.calendar.thumbnail.\(chekiID)").tap()
        let reopenedPage = element(pageIdentifier)
        XCTAssertTrue(reopenedPage.waitForExistence(timeout: 4))
        reopenedPage.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)
        ).tap()
        let editor = element("chekinana.gallery.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        XCTAssertEqual(editor.value as? String, chekiID)
    }

    func testIdolDetailChekiViewerPhysicalTapOpensExactEditor() {
        launch(fixture: "data")
        tapTab("Idols")

        let search = app.textFields["chekinana.idols.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        search.tap()
        search.typeText("Rin")
        let searchKey = app.keyboards.buttons["Search"].firstMatch
        if searchKey.waitForExistence(timeout: 2) { searchKey.tap() }

        let idolCard = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.idols.card."
            )
        ).firstMatch
        XCTAssertTrue(idolCard.waitForExistence(timeout: 4))
        idolCard.tap()
        XCTAssertTrue(element("chekinana.idols.detail").waitForExistence(timeout: 4))

        let chekiType = app.buttons["chekinana.idols.detail.type.cheki"]
        XCTAssertTrue(chekiType.waitForExistence(timeout: 4))
        chekiType.tap()
        let date = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.idols.detail.date.cheki."
            )
        ).firstMatch
        XCTAssertTrue(date.waitForExistence(timeout: 4))
        date.tap()

        let cheki = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.idols.detail.media.cheki-"
            )
        ).firstMatch
        XCTAssertTrue(cheki.waitForExistence(timeout: 4))
        let chekiID = String(
            cheki.identifier.dropFirst(
                "chekinana.idols.detail.media.cheki-".count
            )
        )
        cheki.tap()
        assertCurrentChekiViewerPhysicallyEdits(chekiID: chekiID)
    }

    func testGalleryChekiViewerPhysicalTapOpensExactEditor() {
        launch(fixture: "data")
        tapTab("Gallery")

        let chekiCard = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.gallery.card.cheki-"
            )
        ).firstMatch
        XCTAssertTrue(chekiCard.waitForExistence(timeout: 5))
        let chekiID = String(
            chekiCard.identifier.dropFirst(
                "chekinana.gallery.card.cheki-".count
            )
        )
        chekiCard.tap()
        assertCurrentChekiViewerPhysicallyEdits(chekiID: chekiID)
    }

    func testCalendarGroupUIKitSnapshotDragPersistsExactlyOnce() throws {
        launch(fixture: "calendar-groups")
        tapTab("Calendar")

        func orderedGroupIDs() -> [String] {
            app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "chekinana.calendar.group.combination-"
                )
            ).allElementsBoundByIndex.map(\.identifier)
        }
        let initialOrder = orderedGroupIDs()
        XCTAssertGreaterThanOrEqual(initialOrder.count, 2)
        let sourceID = try XCTUnwrap(initialOrder.first)
        let targetID = initialOrder[1]
        let source = app.buttons[sourceID]
        let target = app.buttons[targetID]
        XCTAssertTrue(source.waitForExistence(timeout: 4))
        XCTAssertTrue(target.exists)

        source.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)
        ).press(
            forDuration: 0.6,
            thenDragTo: target.coordinate(
                withNormalizedOffset: CGVector(dx: 0.45, dy: 0.8)
            )
        )
        XCTAssertTrue(waitUntil(timeout: 5) {
            Array(orderedGroupIDs().prefix(2)) == [targetID, sourceID]
        })

        let debugID = sourceID.replacingOccurrences(
            of: "chekinana.calendar.group.",
            with: "chekinana.calendar.debug.group-gesture."
        )
        let debug = element(debugID)
        XCTAssertTrue(debug.waitForExistence(timeout: 4))
        XCTAssertTrue(waitUntil(timeout: 4) {
            let value = debug.value as? String ?? ""
            return value.contains("swift-state=0")
                && value.contains("persist=1")
        })

        tapTab("Idols")
        tapTab("Calendar")
        XCTAssertEqual(Array(orderedGroupIDs().prefix(2)), [targetID, sourceID])
    }

    func testEmptyShellNavigationDrawerAndSettings() {
        launch(fixture: nil)
        let scanPageAppeared = element("chekinana.scan.page").waitForExistence(timeout: 8)
        if !scanPageAppeared { dumpHierarchy("empty-scan-page-missing") }
        XCTAssertTrue(scanPageAppeared)
        let calendarTab = app.buttons["chekinana.shell.tab.calendar"]
        XCTAssertTrue(calendarTab.waitForExistence(timeout: 3))
        XCTAssertLessThan(
            abs(calendarTab.frame.midX - app.windows.firstMatch.frame.midX),
            12,
            "Calendar must be the middle tab"
        )
        capture("iphone-empty-scan")

        let choosePhotos = app.buttons["chekinana.scan.photos"]
        XCTAssertTrue(choosePhotos.exists)
        XCTAssertTrue(element("chekinana.scan.gpu.status").exists)
        XCTAssertTrue(app.buttons["chekinana.scan.gpu.refresh"].exists)
        XCTAssertTrue(app.staticTexts["GPU · Unknown"].exists)
        XCTAssertFalse(app.buttons["chekinana.scan.gpu.start"].exists)
        XCTAssertFalse(app.switches["chekinana.scan.sleeves"].exists)

        let dateToggle = app.switches["chekinana.scan.date-recognition"]
        let idolToggle = app.switches["chekinana.scan.idol-recognition"]
        let importCheki = app.buttons["chekinana.scan.import-cheki"]
        XCTAssertTrue(importCheki.exists)
        XCTAssertGreaterThan(
            importCheki.frame.midX,
            app.windows.firstMatch.frame.maxX,
            "Import Cheki remains the third horizontally scrolled input"
        )
        XCTAssertEqual(dateToggle.value as? String, "1")
        XCTAssertEqual(idolToggle.value as? String, "1")

        let candidates = app.buttons["chekinana.scan.candidates"]
        XCTAssertTrue(candidates.waitForExistence(timeout: 3))
        scrollAboveTabBar(candidates)
        XCTAssertTrue(waitUntil(timeout: 3) { candidates.isHittable })
        candidates.tap()
        let unassignedCandidate = app.switches["chekinana.scan.candidate.unassigned"]
        XCTAssertTrue(unassignedCandidate.waitForExistence(timeout: 3))
        XCTAssertEqual(unassignedCandidate.value as? String, "Not selected")
        let candidateDone = app.buttons["chekinana.scan.candidates.done"]
        candidateDone.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !candidateDone.exists })

        openDrawer()
        capture("iphone-empty-drawer")
        XCTAssertTrue(element("chekinana.shell.drawer").exists)
        app.buttons["chekinana.shell.drawer.settings"].tap()
        XCTAssertTrue(element("chekinana.settings.page").waitForExistence(timeout: 4))
        capture("iphone-empty-settings")
        app.buttons["chekinana.settings.done"].tap()

        tapTab("Idols")
        XCTAssertTrue(element("chekinana.idols.page").waitForExistence(timeout: 4))
        capture("iphone-empty-idols")
        app.buttons["chekinana.idols.add"].tap()
        XCTAssertTrue(element("chekinana.idols.editor").waitForExistence(timeout: 4))
        XCTAssertFalse(app.textFields["chekinana.prompt"].exists)
        app.buttons["chekinana.idols.editor.cancel"].tap()
        XCTAssertTrue(element("chekinana.idols.page").waitForExistence(timeout: 4))

        tapTab("Events")
        XCTAssertTrue(element("chekinana.events.page").waitForExistence(timeout: 4))
        XCTAssertTrue(element("chekinana.events.page-picker").exists)
        XCTAssertTrue(
            app.segmentedControls["chekinana.events.page-picker"]
                .buttons.element(boundBy: 0).isSelected
        )
        app.buttons["chekinana.events.add"].tap()
        XCTAssertTrue(element("chekinana.events.editor").waitForExistence(timeout: 4))
        XCTAssertFalse(app.textFields["chekinana.prompt"].exists)
        app.buttons["chekinana.events.editor.cancel"].tap()

        tapTab("Scan")
        XCTAssertEqual(dateToggle.value as? String, "1")
        XCTAssertEqual(idolToggle.value as? String, "1")

        tapTab("Gallery")
        XCTAssertTrue(element("chekinana.gallery.empty").waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["chekinana.gallery.add"].exists)
        capture("iphone-empty-gallery")

        tapTab("Calendar")
        XCTAssertTrue(element("chekinana.calendar.empty-day").waitForExistence(timeout: 4))
        capture("iphone-empty-calendar")
        let month = element("chekinana.calendar.month")
        let selectedDate = element("chekinana.calendar.selected-date")
        let originalMonth = month.label
        let originalDate = selectedDate.value as? String
        app.buttons["chekinana.calendar.next-month"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { month.label != originalMonth })
        let nextDate = selectedDate.value as? String
        XCTAssertNotEqual(nextDate, originalDate)
        XCTAssertTrue(nextDate?.hasSuffix("-01") == true)
        if let nextDate {
            XCTAssertTrue(app.buttons["chekinana.calendar.day.\(nextDate)"].isSelected)
        }
        app.buttons["chekinana.calendar.previous-month"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { month.label == originalMonth })
        XCTAssertTrue((selectedDate.value as? String)?.hasSuffix("-01") == true)
    }

    func testCandidatePickerSeparatesUnassignedAndSupportsIndependentIdolSelection() {
        launch(fixture: "data")

        let candidates = app.buttons["chekinana.scan.candidates"]
        XCTAssertTrue(candidates.waitForExistence(timeout: 3))
        scrollAboveTabBar(candidates)
        XCTAssertTrue(waitUntil(timeout: 3) { candidates.isHittable })
        candidates.tap()

        let unassigned = app.switches["chekinana.scan.candidate.unassigned"]
        XCTAssertTrue(unassigned.waitForExistence(timeout: 3))
        XCTAssertEqual(unassigned.value as? String, "Not selected")

        let idolOptions = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@",
                "chekinana.scan.candidate.",
                "chekinana.scan.candidate.unassigned"
            )
        )
        XCTAssertGreaterThanOrEqual(idolOptions.count, 2)

        let first = idolOptions.element(boundBy: 0)
        let second = idolOptions.element(boundBy: 1)
        let initialFirstValue = first.value as? String
        let initialSecondValue = second.value as? String
        XCTAssertTrue(["Selected", "Not selected"].contains(initialFirstValue ?? ""))
        XCTAssertTrue(["Selected", "Not selected"].contains(initialSecondValue ?? ""))
        first.tap()
        XCTAssertNotEqual(first.value as? String, initialFirstValue)
        XCTAssertEqual(second.value as? String, initialSecondValue)
        second.tap()
        let toggledFirstValue = first.value as? String
        let toggledSecondValue = second.value as? String
        XCTAssertNotEqual(toggledSecondValue, initialSecondValue)

        unassigned.tap()
        XCTAssertEqual(unassigned.value as? String, "Selected")
        XCTAssertEqual(first.value as? String, toggledFirstValue)
        XCTAssertEqual(second.value as? String, toggledSecondValue)

        app.buttons["chekinana.scan.candidates.done"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) {
            !self.app.buttons["chekinana.scan.candidates.done"].exists
        })
    }

    func testGPUClosedShowsStartAndRefreshControls() {
        launch(fixture: nil, runtimeFixture: "offline-ready")

        let status = element("chekinana.scan.gpu.status")
        XCTAssertTrue(status.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["chekinana.scan.gpu.start"].exists)
        XCTAssertFalse(app.buttons["chekinana.scan.gpu.terminate"].exists)
        XCTAssertTrue(app.buttons["chekinana.scan.gpu.refresh"].exists)
        XCTAssertFalse(app.buttons["chekinana.scan.camera"].isEnabled)
        XCTAssertFalse(app.buttons["chekinana.scan.photos"].isEnabled)
    }

    func testGPUClosedFixtureExposesStart() {
        launch(fixture: nil, runtimeFixture: "closed")

        XCTAssertTrue(app.buttons["chekinana.scan.gpu.start"].waitForExistence(timeout: 4))
    }

    func testDataFixturePagesSearchFilterDetailsAndCalendar() {
        launch(fixture: "data")

        tapTab("Idols")
        let idolCards = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idols.card.")
        )
        let hasFixtureIdolCards = waitUntil(timeout: 5) { idolCards.count >= 3 }
        if !hasFixtureIdolCards { dumpHierarchy("data-idols-count-\(idolCards.count)") }
        XCTAssertTrue(hasFixtureIdolCards)
        let favoriteButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idols.favorite.")
        )
        XCTAssertGreaterThanOrEqual(favoriteButtons.count, 3)
        capture("iphone-data-idols")

        let idolSearch = app.textFields["chekinana.idols.search"]
        XCTAssertTrue(idolSearch.waitForExistence(timeout: 3))
        XCTAssertTrue(idolSearch.isHittable)
        idolSearch.tap()
        idolSearch.typeText("Rin")
        XCTAssertTrue(waitUntil(timeout: 3) { idolCards.count == 1 })
        let idolSearchKey = app.keyboards.buttons["Search"].firstMatch
        if idolSearchKey.waitForExistence(timeout: 2) {
            idolSearchKey.tap()
            XCTAssertTrue(waitUntil(timeout: 4) { !self.app.keyboards.firstMatch.exists })
        }
        XCTAssertTrue(idolCards.firstMatch.isHittable)
        idolCards.firstMatch.tap()
        XCTAssertTrue(element("chekinana.idols.detail").waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["chekinana.idols.detail.edit"].exists)
        XCTAssertFalse(app.buttons["chekinana.idols.detail.assistant"].exists)
        let idolChekiType = app.buttons["chekinana.idols.detail.type.cheki"]
        XCTAssertTrue(idolChekiType.waitForExistence(timeout: 4))
        XCTAssertTrue(idolChekiType.isHittable)
        idolChekiType.tap()
        let idolDateRows = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.idols.detail.date.cheki."
            )
        )
        XCTAssertTrue(waitUntil(timeout: 4) { idolDateRows.count >= 1 })
        idolDateRows.firstMatch.tap()
        let idolChekis = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idols.detail.media.cheki-")
        )
        XCTAssertTrue(waitUntil(timeout: 4) { idolChekis.count >= 1 })
        idolChekis.firstMatch.tap()
        let idolChekiDetailAppeared = app.buttons["chekinana.gallery.detail.close"]
            .waitForExistence(timeout: 4)
        capture(idolChekiDetailAppeared
            ? "iphone-data-idol-cheki-detail"
            : "failure-iphone-data-idol-cheki-detail")
        XCTAssertTrue(idolChekiDetailAppeared)
        app.buttons["chekinana.gallery.detail.close"].tap()
        let idolDateGroup = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.idols.detail.date-group.cheki."
            )
        ).firstMatch
        if idolDateGroup.waitForExistence(timeout: 2) {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 2))
            back.tap()
        }
        let idolDatePage = element("chekinana.idols.detail.date-page.cheki")
        if idolDatePage.waitForExistence(timeout: 2) {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 2))
            back.tap()
        }
        XCTAssertTrue(element("chekinana.idols.detail").waitForExistence(timeout: 4))
        app.buttons["chekinana.idols.detail.done"].tap()
        XCTAssertTrue(element("chekinana.idols.page").waitForExistence(timeout: 4))
        let clearIdolSearch = app.buttons["chekinana.idols.search.clear"]
        XCTAssertTrue(clearIdolSearch.waitForExistence(timeout: 3))
        XCTAssertTrue(clearIdolSearch.isHittable)
        clearIdolSearch.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { idolCards.count >= 3 })

        tapTab("Events")
        XCTAssertTrue(element("chekinana.events.page").waitForExistence(timeout: 4))
        let eventCards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.events.card.")
        )
        let eventPagePickers = app.segmentedControls.matching(
            identifier: "chekinana.events.page-picker"
        )
        XCTAssertTrue(waitUntil(timeout: 3) {
            eventPagePickers.allElementsBoundByIndex.contains(where: \.isHittable)
        })
        let eventPagePicker = eventPagePickers.allElementsBoundByIndex.first(where: \.isHittable)!
        eventPagePicker.coordinate(
            withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)
        ).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { eventCards.count == 2 })
        let satelliteEvent = app.staticTexts["Satellite Mini Tour"]
        XCTAssertTrue(satelliteEvent.waitForExistence(timeout: 3))
        capture("iphone-data-events")
        XCTAssertTrue(satelliteEvent.isHittable)
        satelliteEvent.tap()
        XCTAssertTrue(element("chekinana.events.detail").waitForExistence(timeout: 4))
        let eventChekis = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.events.detail.cheki.")
        )
        XCTAssertTrue(waitUntil(timeout: 4) { eventChekis.count >= 1 })
        XCTAssertTrue(eventChekis.firstMatch.isHittable)
        eventChekis.firstMatch.tap()
        let eventChekiDetailAppeared = app.buttons["chekinana.gallery.detail.close"]
            .waitForExistence(timeout: 4)
        capture(eventChekiDetailAppeared
            ? "iphone-data-event-cheki-detail"
            : "failure-iphone-data-event-cheki-detail")
        XCTAssertTrue(eventChekiDetailAppeared)
        app.buttons["chekinana.gallery.detail.close"].tap()
        XCTAssertTrue(element("chekinana.events.detail").waitForExistence(timeout: 4))
        app.buttons["chekinana.events.detail.done"].tap()
        XCTAssertTrue(element("chekinana.events.page").waitForExistence(timeout: 4))

        tapTab("Gallery")
        let galleryCards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.gallery.card.")
        )
        XCTAssertTrue(waitUntil(timeout: 5) { galleryCards.count == 4 })
        capture("iphone-data-gallery")

        let lastGalleryCard = galleryCards.element(boundBy: galleryCards.count - 1)
        scrollAboveTabBar(lastGalleryCard)
        capture("iphone-data-gallery-bottom")
        XCTAssertLessThanOrEqual(lastGalleryCard.frame.maxY, element("chekinana.shell.tabbar").frame.minY)

        galleryCards.firstMatch.tap()
        XCTAssertTrue(app.buttons["chekinana.gallery.detail.close"].waitForExistence(timeout: 4))
        XCTAssertTrue(element("chekinana.gallery.detail.light").exists)
        capture("iphone-data-gallery-detail")
        app.buttons["chekinana.gallery.detail.edit"].tap()
        XCTAssertTrue(app.buttons["chekinana.gallery.editor.change-idols"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.switches["Airi"].exists)
        app.buttons["chekinana.gallery.editor.change-idols"].tap()
        XCTAssertTrue(element("chekinana.gallery.editor.idol-selection").waitForExistence(timeout: 4))
        app.buttons["chekinana.gallery.editor.idols.done"].tap()
        app.buttons["chekinana.gallery.editor.cancel"].tap()
        app.buttons["chekinana.gallery.detail.close"].tap()
        for _ in 0..<3 { app.swipeDown() }
        let favoriteSegment = app.buttons["chekinana.gallery.favorite"]
        XCTAssertTrue(favoriteSegment.waitForExistence(timeout: 4))
        XCTAssertTrue(favoriteSegment.isHittable)
        favoriteSegment.tap()
        let showsTwoFavorites = waitUntil(timeout: 4) { galleryCards.count == 2 }
        if !showsTwoFavorites { dumpHierarchy("gallery-favorites-count-\(galleryCards.count)") }
        XCTAssertTrue(showsTwoFavorites)
        XCTAssertTrue(galleryCards.element(boundBy: 0).isHittable)
        XCTAssertTrue(galleryCards.element(boundBy: 1).isHittable)

        tapTab("Calendar")
        XCTAssertTrue(element("chekinana.calendar.selected-day").waitForExistence(timeout: 4))
        let selectedDayCount = element("chekinana.calendar.count.2026-08-02")
        XCTAssertTrue(selectedDayCount.waitForExistence(timeout: 3))
        XCTAssertEqual(selectedDayCount.label, "2")
        let calendarRecords = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.calendar.group.")
        )
        XCTAssertGreaterThanOrEqual(calendarRecords.count, 1)
        capture("iphone-data-calendar")
        calendarRecords.firstMatch.tap()
        XCTAssertTrue(element("chekinana.calendar.group-summary").waitForExistence(timeout: 4))
        XCTAssertTrue(element("chekinana.calendar.group.strip").exists)
        app.buttons["chekinana.calendar.group.done"].tap()
        XCTAssertTrue(element("chekinana.calendar.page").waitForExistence(timeout: 4))
        let lastCalendarRecord = calendarRecords.element(boundBy: calendarRecords.count - 1)
        scrollAboveTabBar(lastCalendarRecord)
        capture("iphone-data-calendar-bottom")
        XCTAssertTrue(lastCalendarRecord.isHittable)
        XCTAssertLessThanOrEqual(lastCalendarRecord.frame.maxY, element("chekinana.shell.tabbar").frame.minY)

        openDrawer()
        let drawerAppeared = element("chekinana.shell.drawer").waitForExistence(timeout: 3)
        if !drawerAppeared { dumpHierarchy("drawer-missing-after-menu-tap") }
        XCTAssertTrue(drawerAppeared)
        capture("iphone-data-drawer")
        app.buttons["chekinana.shell.drawer.assistant"].tap()
        XCTAssertTrue(app.textFields["chekinana.prompt"].waitForExistence(timeout: 4))
        let assistantClose = app.buttons["chekinana.assistant.close"]
        XCTAssertTrue(assistantClose.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(assistantClose.frame.height, 44)
        assistantClose.tap()
    }

    func testDrawerDismissesFromScrimAndHasAccessibleTargets() {
        launch(fixture: "data")
        openDrawer()

        for identifier in [
            "chekinana.shell.drawer.close",
            "chekinana.shell.drawer.assistant",
            "chekinana.shell.drawer.calendar",
            "chekinana.shell.drawer.settings",
        ] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.exists, identifier)
            XCTAssertTrue(button.isHittable, identifier)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, identifier)
        }

        let scrim = app.buttons["chekinana.shell.drawer.scrim"]
        XCTAssertTrue(scrim.exists)
        scrim.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !self.element("chekinana.shell.drawer").exists })
        XCTAssertTrue(element("chekinana.scan.page").exists)
    }

    func testEventEditorUsesWeiboURLWithAlwaysEditableFieldsAndImages() {
        let sourceURL = "https://weibo.com/123456/AbC123"
        UIPasteboard.general.string = sourceURL
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["CHEKINANA_UI_TEST_STORE"] = "1"
        app.launchEnvironment["CHEKINANA_UI_RESET_STORE"] = "1"
        app.launchEnvironment["CHEKINANA_EVENT_CANDIDATE_UI_STUB"] = "fixture"
        app.launch()
        XCTAssertTrue(element("chekinana.shell.root").waitForExistence(timeout: 8))
        tapTab("Events")
        openEventEditor()

        XCTAssertFalse(app.segmentedControls["chekinana.events.editor.mode"].exists)
        XCTAssertFalse(app.textViews["chekinana.events.editor.text-source"].exists)

        let pasteButton = app.buttons["chekinana.events.editor.weibo-paste"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 4))
        XCTAssertTrue(waitUntil(timeout: 4) { pasteButton.isHittable })
        pasteButton.tap()
        let urlSource = app.textFields["chekinana.events.editor.weibo-source"]
        XCTAssertTrue(waitUntil(timeout: 4) {
            urlSource.value as? String == sourceURL
        })
        let parseURL = app.buttons["chekinana.events.editor.extract"]
        XCTAssertTrue(parseURL.exists)
        XCTAssertTrue(parseURL.isHittable)
        parseURL.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !self.app.keyboards.firstMatch.exists })
        let nameField = app.textFields["chekinana.events.editor.name"]
        XCTAssertTrue(waitUntil(timeout: 5) { (nameField.value as? String) == "Fixture Live" })
        let avatarPreview = element("chekinana.events.editor.avatar-preview")
        XCTAssertTrue(avatarPreview.waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.textFields["chekinana.events.editor.weibo-url"].value as? String,
            "https://weibo.com/123456/AbC123"
        )

        XCTAssertEqual(app.textFields["chekinana.events.editor.city"].value as? String, "上海")
        XCTAssertEqual(
            app.textFields["chekinana.events.editor.livehouse"].value as? String,
            "Fixture Livehouse 中大二号馆"
        )
        XCTAssertFalse(app.switches["chekinana.events.editor.has-date"].exists)
        XCTAssertTrue(element("chekinana.events.editor.date").exists)

        nameField.tap()
        nameField.typeText(" Edited")
        let ticketURL = app.textFields["chekinana.events.editor.ticket-url"]
        for _ in 0..<4 where !ticketURL.exists {
            app.swipeUp()
        }
        XCTAssertTrue(ticketURL.waitForExistence(timeout: 4))
        XCTAssertTrue(app.textFields["chekinana.events.editor.weibo-url"].exists)
        XCTAssertEqual(
            ticketURL.value as? String,
            "https://showstart.com/event/fixture"
        )
        let addImages = app.buttons["chekinana.events.editor.images.add"]
        for _ in 0..<4 where !addImages.exists {
            app.swipeUp()
        }
        XCTAssertTrue(addImages.waitForExistence(timeout: 4))
        app.buttons["chekinana.events.editor.save"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) {
            !self.element("chekinana.events.editor").exists
        })
        XCTAssertTrue(element("chekinana.events.page").waitForExistence(timeout: 5))
        let savedEvent = app.staticTexts["Fixture Live Edited"]
        if !savedEvent.waitForExistence(timeout: 2) {
            let pickers = app.segmentedControls.matching(
                identifier: "chekinana.events.page-picker"
            )
            XCTAssertTrue(waitUntil(timeout: 3) {
                pickers.allElementsBoundByIndex.contains(where: \.isHittable)
            })
            let picker = pickers.allElementsBoundByIndex.first(where: \.isHittable)!
            picker.coordinate(
                withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)
            ).tap()
            XCTAssertTrue(waitUntil(timeout: 3) {
                picker.buttons.element(boundBy: 1).isSelected
            })
        }
        XCTAssertTrue(savedEvent.waitForExistence(timeout: 5))
    }

    func testEventEditorSystemPasteControlPastesWeiboURLOnRealTap() {
        let uniqueURL = "https://weibo.com/7890706297/5293529858316367?ui-paste=container"
        UIPasteboard.general.string = uniqueURL
        XCTAssertEqual(UIPasteboard.general.string, uniqueURL)

        launch(fixture: nil)
        tapTab("Events")
        openEventEditor()

        let pasteButton = app.buttons["chekinana.events.editor.weibo-paste"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 4))
        XCTAssertTrue(pasteButton.isEnabled)
        XCTAssertTrue(waitUntil(timeout: 4) { pasteButton.isHittable })
        pasteButton.tap()

        let sourceField = app.textFields["chekinana.events.editor.weibo-source"]
        XCTAssertTrue(sourceField.waitForExistence(timeout: 4))
        let didPaste = waitUntil(timeout: 4) {
            sourceField.value as? String == uniqueURL
        }
        XCTAssertTrue(
            didPaste,
            "Expected pasted URL; actual source: \(String(describing: sourceField.value))"
        )
        XCTAssertFalse(pasteButton.exists)
        XCTAssertTrue(
            waitUntil(timeout: 2) { sourceField.isHittable },
            "A nonempty URL must remove the paste overlay and restore normal field editing."
        )
    }

    func testAssistantLongCandidatesStayAtTopAndSessionSurvivesReentry() {
        launch(fixture: "data", assistantFixture: "long_candidates")
        openDrawer()
        app.buttons["chekinana.shell.drawer.assistant"].tap()

        let firstCandidate = app.staticTexts["Candidate 1"]
        XCTAssertTrue(firstCandidate.waitForExistence(timeout: 5))
        XCTAssertTrue(firstCandidate.isHittable)
        let cancel = app.buttons["chekinana.idol.candidates.cancel"]
        XCTAssertFalse(cancel.isHittable, "Long candidates must not force-scroll to the final control")

        let plusButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idol.candidate.select.")
        )
        XCTAssertGreaterThanOrEqual(plusButtons.count, 1)
        plusButtons.firstMatch.tap()
        XCTAssertTrue(firstCandidate.waitForExistence(timeout: 4))
        XCTAssertTrue(firstCandidate.isHittable, "Selecting a candidate must preserve the top region")

        app.buttons["chekinana.assistant.close"].tap()
        XCTAssertTrue(element("chekinana.shell.root").waitForExistence(timeout: 4))
        openDrawer()
        app.buttons["chekinana.shell.drawer.assistant"].tap()
        XCTAssertTrue(firstCandidate.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["History message 1"].exists)
        XCTAssertGreaterThanOrEqual(plusButtons.count, 1, "Remaining candidate actions must survive reentry")
    }

    func testIdolDragReorderPersistsAcrossPageReentry() throws {
        launch(fixture: "data")
        tapTab("Idols")
        let airi = app.staticTexts["Airi"]
        let mina = app.staticTexts["Mina"]
        let rin = app.staticTexts["Rin"]
        XCTAssertTrue(airi.waitForExistence(timeout: 4))
        XCTAssertTrue(rin.waitForExistence(timeout: 4))
        XCTAssertLessThan(airi.frame.minY, mina.frame.minY)

        XCTAssertFalse(app.staticTexts["No pattern"].exists)
        XCTAssertFalse(app.staticTexts["1 pattern"].exists)
        XCTAssertFalse(app.staticTexts["2 patterns"].exists)
        let idolCards = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idols.card.")
        )
        let cardElements = idolCards.allElementsBoundByIndex
        let airiCard = try XCTUnwrap(cardElements.first {
            $0.frame.contains(CGPoint(x: airi.frame.midX, y: airi.frame.midY))
        })
        let rinCard = try XCTUnwrap(cardElements.first {
            $0.frame.contains(CGPoint(x: rin.frame.midX, y: rin.frame.midY))
        })
        let minaCard = try XCTUnwrap(cardElements.first {
            $0.frame.contains(CGPoint(x: mina.frame.midX, y: mina.frame.midY))
        })
        XCTAssertTrue((airiCard.value as? String)?.contains("No stored pattern") == true)
        XCTAssertTrue((minaCard.value as? String)?.contains("Stored pattern available") == true)
        XCTAssertTrue((rinCard.value as? String)?.contains("Stored pattern available") == true)
        let dragHandle = element("chekinana.idols.drag-handle.\(try XCTUnwrap(airiCard.identifier.split(separator: ".").last))")
        XCTAssertTrue(dragHandle.waitForExistence(timeout: 3))
        let dragStart = dragHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dragEnd = rinCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(forDuration: 1.0, thenDragTo: dragEnd)
        XCTAssertTrue(waitUntil(timeout: 4) { mina.frame.minY < airi.frame.minY })

        tapTab("Calendar")
        tapTab("Idols")
        XCTAssertLessThan(mina.frame.minY, airi.frame.minY)

        let search = app.textFields["chekinana.idols.search"]
        search.tap()
        search.typeText("Mina")
        XCTAssertTrue(element("chekinana.idols.reorder.search-disabled").waitForExistence(timeout: 3))
    }

    func testDeletingAnIdolPatternPersistsAfterSavingAndReopening() {
        launch(fixture: "data")
        tapTab("Idols")

        let mina = app.staticTexts["Mina"]
        XCTAssertTrue(mina.waitForExistence(timeout: 4))
        mina.tap()
        XCTAssertTrue(element("chekinana.idols.detail").waitForExistence(timeout: 4))
        app.buttons["chekinana.idols.detail.edit"].tap()
        XCTAssertTrue(element("chekinana.idols.editor").waitForExistence(timeout: 4))

        let removeButtons = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.idols.editor.pattern.remove."
            )
        )
        let patternCount = element("chekinana.idols.editor.pattern-count")
        XCTAssertTrue(patternCount.waitForExistence(timeout: 3))
        let initialPatternCount = Int(patternCount.value as? String ?? "") ?? 0
        XCTAssertGreaterThan(initialPatternCount, 0)
        removeButtons.firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 3) {
            (self.element("chekinana.idols.editor.pattern-count").value as? String)
                == String(initialPatternCount - 1)
        })
        app.buttons["chekinana.idols.editor.save"].tap()

        XCTAssertTrue(waitUntil(timeout: 8) {
            !self.element("chekinana.idols.editor").exists
        })
        XCTAssertTrue(element("chekinana.idols.detail").waitForExistence(timeout: 3))
        app.buttons["chekinana.idols.detail.edit"].tap()
        XCTAssertTrue(element("chekinana.idols.editor").waitForExistence(timeout: 4))
        XCTAssertEqual(
            element("chekinana.idols.editor.pattern-count").value as? String,
            String(initialPatternCount - 1)
        )
    }

    func testScanSelectedPhotoTransfersPlanAndAutoSubmits() throws {
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["CHEKINANA_UI_TEST_STORE"] = "1"
        app.launchEnvironment["CHEKINANA_UI_RESET_STORE"] = "1"
        app.launchEnvironment["CHEKINANA_NATIVE_SCAN_UI_STUB"] = "fixture"
        app.launchEnvironment["CHEKINANA_NATIVE_SCAN_UI_DISABLE_IDOL_RECOGNITION"] = "1"
        app.launchEnvironment["CHEKINANA_NATIVE_SCAN_UI_AUTO_START"] = "1"
        app.launchEnvironment["CHEKINANA_PRODUCT_UI_FIXTURE"] = "data"
        app.launch()
        XCTAssertTrue(element("chekinana.scan.review").waitForExistence(timeout: 30))
        XCTAssertTrue(element("chekinana.scan.review.warning").exists)
        let firstCard = element("chekinana.scan.review.card.1")
        let secondCard = element("chekinana.scan.review.card.2")
        let thirdCard = element("chekinana.scan.review.card.3")
        XCTAssertTrue(firstCard.waitForExistence(timeout: 4))
        XCTAssertTrue(secondCard.exists)
        XCTAssertTrue(thirdCard.exists)
        XCTAssertLessThan(abs(firstCard.frame.minY - secondCard.frame.minY), 8)
        XCTAssertLessThan(firstCard.frame.minX, secondCard.frame.minX)
        XCTAssertGreaterThan(thirdCard.frame.minY, firstCard.frame.minY)
        let shotTypeButtons = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.scan.review.user-appears."
            )
        )
        XCTAssertEqual(shotTypeButtons.count, 3)
        let firstShotType = shotTypeButtons.firstMatch
        XCTAssertEqual(firstShotType.value as? String, "solo")
        XCTAssertGreaterThanOrEqual(firstShotType.frame.width, 44)
        XCTAssertGreaterThanOrEqual(firstShotType.frame.height, 44)
        XCTAssertTrue(firstShotType.isHittable)
        firstShotType.tap()
        XCTAssertTrue(waitUntil(timeout: 3) {
            (shotTypeButtons.firstMatch.value as? String) == "2-shot"
        })
        XCTAssertFalse(element("chekinana.scan.review.editor").exists)
        for position in 1...2 {
            let idol = element("chekinana.scan.review.idol.\(position)")
            let date = element("chekinana.scan.review.date.\(position)")
            XCTAssertTrue(idol.exists)
            XCTAssertTrue(date.exists)
            XCTAssertGreaterThanOrEqual(
                date.frame.minX - idol.frame.maxX,
                4,
                "Avatar strip and date must not overlap"
            )
            XCTAssertFalse((idol.value as? String ?? "").isEmpty)
            XCTAssertFalse((date.value as? String ?? "").isEmpty)
        }

        let downloadButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.scan.review.download.")
        )
        let rotateButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.scan.review.rotate.")
        )
        let reviewCards = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.scan.review.card.")
        )
        let annotationButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.scan.review.annotation.")
        )
        XCTAssertGreaterThanOrEqual(downloadButtons.count, 2)
        XCTAssertEqual(
            rotateButtons.count,
            reviewCards.count,
            "Every visible Review card must expose exactly one rotate button."
        )
        XCTAssertEqual(reviewCards.count, 3)
        let firstRotate = firstCard.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.scan.review.rotate."
            )
        ).firstMatch
        let secondRotate = secondCard.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.scan.review.rotate."
            )
        ).firstMatch
        XCTAssertTrue(firstRotate.exists)
        XCTAssertTrue(secondRotate.exists)
        XCTAssertEqual(firstCard.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.scan.review.rotate."
            )
        ).count, 1)
        XCTAssertGreaterThanOrEqual(firstRotate.frame.height, 44)
        XCTAssertTrue(firstRotate.isHittable)
        let firstRotationState = firstRotate.value as? String
        let secondRotationState = secondRotate.value as? String
        firstRotate.tap()
        XCTAssertTrue(waitUntil(timeout: 8) {
            (firstRotate.value as? String) != firstRotationState
        })
        XCTAssertEqual(secondRotate.value as? String, secondRotationState)
        XCTAssertFalse(element("chekinana.scan.review.editor").exists)
        XCTAssertGreaterThanOrEqual(annotationButtons.count, 2)
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.scan.review.favorite.")
        ).count, 0)
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.scan.review.edit.")
        ).count, 0)
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.scan.review.delete.")
        ).count, 0)

        let firstIdolButton = element("chekinana.scan.review.idol.1")
        XCTAssertTrue(waitUntil(timeout: 4) { firstIdolButton.isHittable })
        firstIdolButton.tap()
        let idolPicker = element("chekinana.scan.review.idol-picker")
        XCTAssertTrue(idolPicker.waitForExistence(timeout: 8))
        let unassigned = element("chekinana.scan.review.idol-option.unassigned")
        XCTAssertTrue(unassigned.waitForExistence(timeout: 3))
        if (unassigned.value as? String) != "Selected" {
            unassigned.tap()
        }
        XCTAssertEqual(unassigned.value as? String, "Selected")
        app.buttons["chekinana.scan.review.idol-picker.done"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) {
            (self.element("chekinana.scan.review.idol.1").value as? String) == "Unassigned"
        })
        XCTAssertTrue(waitUntil(timeout: 4) { !idolPicker.exists })

        XCTAssertTrue(waitUntil(timeout: 4) { firstIdolButton.isHittable })
        firstIdolButton.tap()
        XCTAssertTrue(idolPicker.waitForExistence(timeout: 8))
        let idolOptions = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.scan.review.idol-option."
            )
        )
        let airi = idolOptions.matching(NSPredicate(format: "label == %@", "Airi")).firstMatch
        let mina = idolOptions.matching(NSPredicate(format: "label == %@", "Mina")).firstMatch
        XCTAssertTrue(airi.waitForExistence(timeout: 3))
        XCTAssertTrue(mina.exists)
        airi.tap()
        mina.tap()
        XCTAssertEqual(airi.value as? String, "Selected")
        XCTAssertEqual(mina.value as? String, "Selected")
        app.buttons["chekinana.scan.review.idol-picker.done"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { !idolPicker.exists })

        let firstDateButton = element("chekinana.scan.review.date.1")
        XCTAssertTrue(waitUntil(timeout: 4) { firstDateButton.isHittable })
        firstDateButton.tap()
        let datePicker = element("chekinana.scan.review.date-picker")
        XCTAssertTrue(datePicker.waitForExistence(timeout: 8))
        app.buttons["chekinana.scan.review.date-picker.clear"].tap()
        app.buttons["chekinana.scan.review.date-picker.done"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) {
            (self.element("chekinana.scan.review.date.1").value as? String) == "日期未识别"
        })
        XCTAssertTrue(waitUntil(timeout: 4) { !datePicker.exists })
        XCTAssertTrue(waitUntil(timeout: 4) { firstDateButton.isHittable })
        firstDateButton.tap()
        XCTAssertTrue(datePicker.waitForExistence(timeout: 8))
        let useDateToggle = app.switches["chekinana.scan.review.date-picker.use-date"]
        XCTAssertTrue(useDateToggle.waitForExistence(timeout: 3))
        XCTAssertTrue(["0", "Off"].contains(useDateToggle.value as? String ?? ""))
        XCTAssertTrue(useDateToggle.isHittable)
        useDateToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(timeout: 4) {
            let value = self.app.switches[
                "chekinana.scan.review.date-picker.use-date"
            ].value as? String ?? ""
            return ["1", "On"].contains(value)
        })
        app.buttons["chekinana.scan.review.date-picker.done"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { !datePicker.exists })

        let firstImage = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.scan.review.image.")
        ).firstMatch
        XCTAssertTrue(waitUntil(timeout: 4) { firstImage.isHittable })
        firstImage.tap()
        XCTAssertTrue(element("chekinana.scan.review.editor").waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["User appears"].exists)
        XCTAssertFalse(app.staticTexts["用户入镜"].exists)
        XCTAssertTrue(app.buttons["chekinana.scan.review.editor.delete"].exists)
        let sizePicker = element("chekinana.scan.review.editor.size")
        for _ in 0..<3 where !sizePicker.exists {
            app.swipeUp()
        }
        XCTAssertTrue(sizePicker.waitForExistence(timeout: 3))
        XCTAssertEqual((sizePicker.value as? String)?.lowercased(), "mini")
        app.buttons["chekinana.scan.review.editor.cancel"].tap()
        XCTAssertFalse(app.textFields["chekinana.prompt"].exists)
        app.buttons["chekinana.scan.review.back"].tap()
        let discardAlert = app.alerts["Discard unsaved results?"]
        XCTAssertTrue(discardAlert.waitForExistence(timeout: 3))
        discardAlert.buttons["Discard"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) {
            !self.element("chekinana.scan.review").exists
        })
    }

    func testCatalogueInfoCardAutoFillsIdolForm() {
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["CHEKINANA_UI_TEST_STORE"] = "1"
        app.launchEnvironment["CHEKINANA_UI_RESET_STORE"] = "1"
        app.launchEnvironment["CHEKINANA_IDOL_UI_STUB"] = "multi_fixture"
        app.launch()
        XCTAssertTrue(element("chekinana.shell.root").waitForExistence(timeout: 8))
        tapTab("Idols")
        app.buttons["chekinana.idols.add"].tap()
        let query = app.textFields["chekinana.idols.editor.catalogue-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 4))
        query.tap()
        query.typeText("Mina")
        app.buttons["chekinana.idols.editor.catalogue-search"].tap()
        let results = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idols.editor.catalogue-result.")
        )
        XCTAssertTrue(waitUntil(timeout: 5) { results.count == 2 })
        results.element(boundBy: 1).tap()
        XCTAssertTrue(element("chekinana.idols.editor.catalogue-applied").waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["Name"].value as? String, "Mina Second")
        XCTAssertEqual(app.textFields["Group"].value as? String, "UI Fixture Two")
        XCTAssertEqual(app.textFields["Birthday"].value as? String, "2001-02-02")
        XCTAssertEqual(app.textFields["Verification"].value as? String, "fixture")
        app.buttons["Cancel"].tap()
    }

    func testSettingsClearAllDataRequiresConfirmationAndReportsSuccess() {
        launch(fixture: "data")
        openDrawer()
        app.buttons["chekinana.shell.drawer.settings"].tap()
        let clear = app.buttons["chekinana.settings.clear-data"]
        XCTAssertTrue(clear.waitForExistence(timeout: 4))
        clear.tap()
        let confirmation = app.buttons["chekinana.settings.clear-data.confirm"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.tap()
        let alert = app.alerts["Local data"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.allElementsBoundByIndex.contains {
            $0.label.contains("Cleared")
        })
        alert.buttons["OK"].tap()
        app.buttons["chekinana.settings.done"].tap()
        tapTab("Idols")
        XCTAssertTrue(element("chekinana.idols.empty").waitForExistence(timeout: 4))
    }

    func testIdolRowsRenderContentAtFixedHeightOnFirstEntry() {
        launch(fixture: "data")
        tapTab("Idols")

        let cards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idols.card.")
        )
        let hasCards = waitUntil(timeout: 5) { cards.count >= 3 }
        if !hasCards { dumpHierarchy("idols-fixed-rows-count-\(cards.count)") }
        XCTAssertTrue(hasCards)
        for name in ["Airi", "Mina", "Rin"] {
            let label = app.staticTexts[name]
            XCTAssertTrue(label.waitForExistence(timeout: 2), name)
            XCTAssertTrue(label.isHittable, name)
        }
        for card in cards.allElementsBoundByIndex {
            XCTAssertGreaterThan(card.frame.height, 70)
            XCTAssertLessThan(card.frame.height, 100)
        }
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idols.favorite.")
            ).count,
            3
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idols.drag-handle.")
            ).count,
            3
        )
        capture("iphone-idols-fixed-rows")
    }

    func testScanDateRangeCanScrollToStartWithLargeSourceButtons() {
        launch(fixture: nil)
        let camera = app.buttons["chekinana.scan.camera"]
        let photos = app.buttons["chekinana.scan.photos"]
        XCTAssertTrue(camera.waitForExistence(timeout: 3))
        XCTAssertTrue(photos.exists)
        XCTAssertGreaterThanOrEqual(camera.frame.height, 110)
        XCTAssertGreaterThanOrEqual(photos.frame.height, 110)
        XCTAssertTrue(app.staticTexts["Take a photo"].exists)
        XCTAssertTrue(app.staticTexts["Choose from library"].exists)

        let range = app.switches["chekinana.scan.date-scope.range"]
        scrollAboveTabBar(range)
        XCTAssertTrue(range.waitForExistence(timeout: 3))
        range.tap()
        XCTAssertTrue(element("chekinana.scan.date-range-from").waitForExistence(timeout: 3))
        XCTAssertTrue(element("chekinana.scan.date-range-to").exists)
        let start = app.buttons["chekinana.scan.start"]
        scrollAboveTabBar(start)
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(
            start.frame.maxY,
            element("chekinana.shell.tabbar").frame.minY
        )
        capture("iphone-scan-expanded-date-range")
    }

    func testScanInputPhotosExposeCompactPerSourceRotateAndDeleteControls() {
        app = XCUIApplication()
        app.launchEnvironment["CHEKINANA_UI_TEST_STORE"] = "1"
        app.launchEnvironment["CHEKINANA_UI_RESET_STORE"] = "1"
        app.launchEnvironment["CHEKINANA_NATIVE_SCAN_UI_INPUT_FIXTURE"] = "1"
        app.launch()

        XCTAssertTrue(element("chekinana.scan.page").waitForExistence(timeout: 8))
        let rotateButtons = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "chekinana.scan.input.rotate."
        ))
        let deleteButtons = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "chekinana.scan.input.delete."
        ))
        let inputImages = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "chekinana.scan.input.image."
        ))
        XCTAssertTrue(waitUntil(timeout: 6) { rotateButtons.count == 2 })
        XCTAssertEqual(deleteButtons.count, 2)
        XCTAssertEqual(inputImages.count, 2)

        let firstRotate = rotateButtons.element(boundBy: 0)
        let secondRotate = rotateButtons.element(boundBy: 1)
        let firstDelete = deleteButtons.element(boundBy: 0)
        let secondDelete = deleteButtons.element(boundBy: 1)
        let firstImage = inputImages.element(boundBy: 0)
        XCTAssertTrue(firstRotate.isHittable)
        XCTAssertTrue(firstDelete.isHittable)
        XCTAssertGreaterThanOrEqual(firstRotate.frame.width, 29)
        XCTAssertLessThanOrEqual(firstRotate.frame.width, 34)
        XCTAssertGreaterThanOrEqual(firstDelete.frame.width, 29)
        XCTAssertLessThanOrEqual(firstDelete.frame.width, 34)
        XCTAssertLessThan(firstRotate.frame.midX, firstDelete.frame.midX)
        XCTAssertEqual(firstRotate.frame.intersection(firstDelete.frame), .null)
        XCTAssertLessThan(firstRotate.frame.midX, firstImage.frame.midX)
        XCTAssertGreaterThan(firstDelete.frame.midX, firstImage.frame.midX)

        let firstState = firstRotate.value as? String
        let secondState = secondRotate.value as? String
        firstRotate.tap()
        XCTAssertTrue(waitUntil(timeout: 4) {
            (firstRotate.value as? String) != firstState
        })
        XCTAssertEqual(secondRotate.value as? String, secondState)
        XCTAssertEqual(deleteButtons.count, 2)

        XCTAssertFalse(firstImage.elementType == .button)
        firstImage.tap()
        XCTAssertEqual(deleteButtons.count, 2, "Image body must not delete an input.")

        let secondDeleteID = secondDelete.identifier
        firstDelete.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { deleteButtons.count == 1 })
        XCTAssertEqual(deleteButtons.firstMatch.identifier, secondDeleteID)
        XCTAssertEqual(rotateButtons.count, 1)
        XCTAssertEqual(inputImages.count, 1)
    }

    func testGPUManagementControlsPersistAfterPageReentry() {
        launch(fixture: nil, runtimeFixture: "closed")
        tapTab("Idols")
        tapTab("Scan")

        XCTAssertTrue(app.buttons["chekinana.scan.gpu.start"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["chekinana.scan.gpu.refresh"].exists)
    }

    func testGallerySeparatesThreeMediaPagesIntoThreeColumns() {
        launch(fixture: "mixed-media")
        tapTab("Gallery")
        let cards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.gallery.card.")
        )
        let types = app.segmentedControls["chekinana.gallery.type"]
        XCTAssertTrue(types.waitForExistence(timeout: 4))
        let cases: [(id: String, rawKind: String, aspectRatio: CGFloat)] = [
            ("chekinana.gallery.type.cheki", "cheki", 1_200.0 / 1_908.0),
            ("chekinana.gallery.type.shame", "shame", 3.0 / 4.0),
            ("chekinana.gallery.type.douga", "douga", 9.0 / 16.0),
        ]
        for item in cases {
            let type = app.buttons[item.id]
            XCTAssertTrue(type.waitForExistence(timeout: 3), item.rawKind)
            type.tap()
            XCTAssertTrue(waitUntil(timeout: 4) { type.isSelected })
            let shotType = app.segmentedControls["chekinana.gallery.shot-type"]
            if item.rawKind == "cheki" {
                XCTAssertTrue(shotType.waitForExistence(timeout: 3))
                let all = app.buttons["chekinana.gallery.shot-type.all"]
                let solo = app.buttons["chekinana.gallery.shot-type.solo"]
                let twoShot = app.buttons["chekinana.gallery.shot-type.two-shot"]
                XCTAssertTrue(all.exists)
                XCTAssertTrue(solo.exists)
                XCTAssertTrue(twoShot.exists)
                solo.tap()
                XCTAssertTrue(waitUntil(timeout: 4) { cards.count == 1 })
                XCTAssertTrue(cards.firstMatch.identifier.contains(".cheki-"))
                twoShot.tap()
                XCTAssertTrue(waitUntil(timeout: 4) { cards.count == 1 })
                XCTAssertTrue(cards.firstMatch.identifier.contains(".cheki-"))
                all.tap()
                XCTAssertTrue(waitUntil(timeout: 4) { cards.count == 4 })
            } else {
                XCTAssertFalse(shotType.exists)
            }
            XCTAssertTrue(
                waitUntil(timeout: 5) { cards.count > 0 },
                item.rawKind
            )
            let frames = cards.allElementsBoundByIndex.map(\.frame)
            XCTAssertTrue(frames.allSatisfy { abs($0.width - frames[0].width) < 1 })
            XCTAssertLessThanOrEqual(cards.element(boundBy: min(2, cards.count - 1)).frame.maxX, app.windows.firstMatch.frame.maxX)
            XCTAssertTrue(cards.allElementsBoundByIndex.allSatisfy {
                $0.identifier.contains(".\(item.rawKind)-")
            })
            XCTAssertEqual(
                frames[0].width / frames[0].height,
                item.aspectRatio,
                accuracy: 0.03,
                item.rawKind
            )
        }
        capture("iphone-gallery-three-pages")
    }

    func testCompletedMatchGameKeepsAudioPlayerInsideSafePageHeight() {
        launch(
            fixture: nil,
            extraEnvironment: ["CHEKINANA_MATCH_GAME_UI_COMPLETE": "1"]
        )
        openDrawer()
        app.buttons["chekinana.shell.drawer.match-game"].tap()
        let player = element("chekinana.match-game.audio-player")
        XCTAssertTrue(player.waitForExistence(timeout: 4))
        XCTAssertTrue(element("chekinana.match-game.board").exists)
        XCTAssertLessThanOrEqual(
            player.frame.maxY,
            app.windows.firstMatch.frame.maxY - 16
        )
        capture("iphone-match-game-complete-player")
    }

    private func launch(
        fixture: String?,
        assistantFixture: String? = nil,
        runtimeFixture: String? = nil,
        extraEnvironment: [String: String] = [:],
        extraArguments: [String] = []
    ) {
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["CHEKINANA_UI_TEST_STORE"] = "1"
        app.launchEnvironment["CHEKINANA_UI_RESET_STORE"] = "1"
        if let fixture {
            app.launchEnvironment["CHEKINANA_PRODUCT_UI_FIXTURE"] = fixture
        }
        if let assistantFixture {
            app.launchEnvironment["CHEKINANA_ASSISTANT_SESSION_UI_STUB"] = assistantFixture
        }
        if let runtimeFixture {
            app.launchEnvironment["CHEKINANA_SCANNER_RUNTIME_UI_STUB"] = runtimeFixture
        }
        for (key, value) in extraEnvironment {
            app.launchEnvironment[key] = value
        }
        app.launchArguments.append(contentsOf: extraArguments)
        app.launch()
        XCTAssertTrue(element("chekinana.shell.root").waitForExistence(timeout: 8))
    }

    private func runFocusedProductSmoke(
        language: String,
        locale: String,
        screenshotSuffix: String,
        contentSizeCategory: String? = nil
    ) {
        var arguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ]
        if let contentSizeCategory {
            arguments.append(contentsOf: [
                "-UIPreferredContentSizeCategoryName", contentSizeCategory,
            ])
        }
        launch(
            fixture: "data",
            extraEnvironment: ["CHEKINANA_CHEKIROKU_UI_STUB": "fixture"],
            extraArguments: arguments
        )

        tapTab("Calendar")
        let calendarAdd = app.buttons["chekinana.calendar.add"]
        assertHittable(calendarAdd, "Calendar add")
        calendarAdd.tap()
        XCTAssertTrue(
            element("chekinana.calendar.add_record.editor")
                .waitForExistence(timeout: 4)
        )
        let calendarCancel = app.buttons["chekinana.calendar.add_record.cancel"]
        let calendarSave = app.buttons["chekinana.calendar.add_record.save"]
        assertHittable(calendarCancel, "Calendar editor cancel")
        XCTAssertTrue(calendarSave.exists)
        XCTAssertFalse(calendarCancel.frame.intersects(calendarSave.frame))
        XCTAssertTrue(element("chekinana.calendar.add_record.type").exists)
        capture("iphone-focused-calendar-\(screenshotSuffix)")
        calendarCancel.tap()
        XCTAssertTrue(waitUntil(timeout: 5) {
            !self.element("chekinana.calendar.add_record.editor").exists
        })
        XCTAssertTrue(element("chekinana.calendar.page").waitForExistence(timeout: 4))

        tapTab("Events")
        let eventPicker = app.segmentedControls["chekinana.events.page-picker"]
        XCTAssertTrue(eventPicker.waitForExistence(timeout: 4))
        XCTAssertTrue(eventPicker.isHittable)
        XCTAssertEqual(eventPicker.buttons.count, 2)
        eventPicker.buttons.element(boundBy: 1).tap()
        openEventEditor()
        let eventName = app.textFields["chekinana.events.editor.name"]
        XCTAssertTrue(eventName.waitForExistence(timeout: 4))
        eventName.tap()
        eventName.typeText("Fixture Localized Event")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let eventCancel = app.buttons["chekinana.events.editor.cancel"]
        let eventSave = app.buttons["chekinana.events.editor.save"]
        assertHittable(eventCancel, "Event editor cancel above keyboard")
        assertHittable(eventSave, "Event editor save above keyboard")
        XCTAssertFalse(eventCancel.frame.intersects(eventSave.frame))
        capture("iphone-focused-event-editor-\(screenshotSuffix)")
        eventSave.tap()
        XCTAssertTrue(element("chekinana.events.page").waitForExistence(timeout: 8))

        openDrawer()
        assertHittable(
            app.buttons["chekinana.shell.drawer.settings"],
            "Settings drawer action"
        )
        app.buttons["chekinana.shell.drawer.settings"].tap()
        XCTAssertTrue(element("chekinana.settings.page").waitForExistence(timeout: 4))
        let settingsDone = app.buttons["chekinana.settings.done"]
        assertHittable(settingsDone, "Settings done")
        let clearData = app.buttons["chekinana.settings.clear-data"]
        for _ in 0..<5 where !clearData.exists || !clearData.isHittable {
            app.swipeUp()
        }
        assertHittable(clearData, "Settings destructive action")
        capture("iphone-focused-settings-\(screenshotSuffix)")
        settingsDone.tap()
        XCTAssertTrue(element("chekinana.shell.root").waitForExistence(timeout: 4))

        openDrawer()
        assertHittable(
            app.buttons["chekinana.shell.drawer.assistant"],
            "Assistant drawer action"
        )
        app.buttons["chekinana.shell.drawer.assistant"].tap()
        XCTAssertTrue(element("chekinana.prompt").waitForExistence(timeout: 4))
        let assistantClose = app.buttons["chekinana.assistant.close"]
        assertHittable(assistantClose, "Assistant back")
        capture("iphone-focused-assistant-\(screenshotSuffix)")
        assistantClose.tap()
        XCTAssertTrue(element("chekinana.shell.root").waitForExistence(timeout: 4))

        openDrawer()
        let importAction = app.buttons["chekinana.shell.drawer.chekiroku-import"]
        assertHittable(importAction, "ChekiRoku drawer action")
        importAction.tap()
        XCTAssertTrue(element("chekinana.import.page").waitForExistence(timeout: 4))
        let continueButton = app.buttons["chekinana.import.step1.continue"]
        XCTAssertTrue(waitUntil(timeout: 8) {
            continueButton.exists && continueButton.isEnabled && continueButton.isHittable
        })
        continueButton.tap()
        let recordBack = app.buttons["chekinana.import.step2.back"]
        let recordImport = app.buttons["chekinana.import.step2.import"]
        assertHittable(recordBack, "ChekiRoku record back")
        XCTAssertTrue(waitUntil(timeout: 5) {
            recordImport.exists && recordImport.isEnabled && recordImport.isHittable
        })
        XCTAssertFalse(recordBack.frame.intersects(recordImport.frame))
        capture("iphone-focused-import-\(screenshotSuffix)")
        recordImport.tap()
        let completionDone = app.buttons["chekinana.import.completion.done"]
        XCTAssertTrue(
            completionDone.waitForExistence(timeout: 10),
            "ChekiRoku completion must expose its Done action"
        )
        assertHittable(completionDone, "ChekiRoku completion done")
        completionDone.tap()
        XCTAssertTrue(element("chekinana.import.read").waitForExistence(timeout: 4))
        let importBack = app.buttons["chekinana.import.back"]
        assertHittable(importBack, "ChekiRoku import back")
        importBack.tap()
        XCTAssertTrue(element("chekinana.shell.root").waitForExistence(timeout: 4))
    }

    private func assertHittable(
        _ element: XCUIElement,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: 4),
            "\(description) must exist",
            file: file,
            line: line
        )
        XCTAssertTrue(
            waitUntil(timeout: 4) { element.isHittable },
            "\(description) must be hittable",
            file: file,
            line: line
        )
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(
            window.intersects(element.frame),
            "\(description) must remain inside the visible window",
            file: file,
            line: line
        )
    }

    private func assertCurrentChekiViewerPhysicallyEdits(
        chekiID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let viewer = element("chekinana.cheki.viewer")
        XCTAssertTrue(
            viewer.waitForExistence(timeout: 5),
            "The shared Cheki viewer must appear.",
            file: file,
            line: line
        )
        let page = element("chekinana.cheki.viewer.page.\(chekiID)")
        XCTAssertTrue(
            page.waitForExistence(timeout: 5),
            "The viewer must start on the selected physical Cheki.",
            file: file,
            line: line
        )
        page.swipeLeft()
        XCTAssertFalse(
            element("chekinana.gallery.editor").waitForExistence(timeout: 1),
            "A page swipe must not open the editor.",
            file: file,
            line: line
        )
        page.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)
        ).tap()
        let editor = element("chekinana.gallery.editor")
        XCTAssertTrue(
            editor.waitForExistence(timeout: 5),
            "A physical image tap must open the Cheki editor.",
            file: file,
            line: line
        )
        XCTAssertEqual(
            editor.value as? String,
            chekiID,
            "The editor must receive the exact physical Cheki UUID.",
            file: file,
            line: line
        )
    }

    private func tapTab(_ title: String) {
        let tabID: String
        switch title {
        case "Scan": tabID = "chekinana.shell.tab.scan"
        case "Idols": tabID = "chekinana.shell.tab.idols"
        case "Events": tabID = "chekinana.shell.tab.events"
        case "Gallery": tabID = "chekinana.shell.tab.gallery"
        case "Calendar": tabID = "chekinana.shell.tab.calendar"
        default: return
        }
        let tab = app.buttons[tabID]
        XCTAssertTrue(tab.waitForExistence(timeout: 3), title)
        XCTAssertTrue(waitUntil(timeout: 4) { tab.isHittable }, title)
        tab.tap()
        let pageIdentifier: String
        switch title {
        case "Scan": pageIdentifier = "chekinana.scan.page"
        case "Idols": pageIdentifier = "chekinana.idols.page"
        case "Events": pageIdentifier = "chekinana.events.page"
        case "Gallery": pageIdentifier = "chekinana.gallery.page"
        case "Calendar": pageIdentifier = "chekinana.calendar.page"
        default: return
        }
        var pageAppeared = element(pageIdentifier).waitForExistence(timeout: 4)
        if !pageAppeared {
            tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            pageAppeared = element(pageIdentifier).waitForExistence(timeout: 4)
        }
        if !pageAppeared { dumpHierarchy("tab-\(title.lowercased())-did-not-switch") }
        XCTAssertTrue(pageAppeared, title)
    }

    private func openDrawer() {
        let menus = app.buttons.matching(identifier: "chekinana.shell.menu")
        XCTAssertTrue(waitUntil(timeout: 3) {
            menus.allElementsBoundByIndex.contains(where: \.isHittable)
        })
        guard let menu = menus.allElementsBoundByIndex.first(where: \.isHittable) else {
            return XCTFail("No visible page menu is hittable")
        }
        menu.tap()
        var appeared = element("chekinana.shell.drawer").waitForExistence(timeout: 3)
        if !appeared, menu.exists, menu.isHittable {
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            appeared = element("chekinana.shell.drawer").waitForExistence(timeout: 3)
        }
        if !appeared { dumpHierarchy("drawer-root-missing") }
        XCTAssertTrue(appeared)
    }

    private func selectAppLanguage(_ rawValue: String) {
        let picker = element("chekinana.settings.language.picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 4))
        if picker.value as? String == rawValue { return }
        picker.tap()
        let option = element("chekinana.settings.language.option.\(rawValue)")
        XCTAssertTrue(option.waitForExistence(timeout: 4), rawValue)
        XCTAssertTrue(waitUntil(timeout: 4) { option.isHittable }, rawValue)
        option.tap()
        XCTAssertTrue(waitUntil(timeout: 4) {
            self.element("chekinana.settings.language.picker").value as? String == rawValue
        }, rawValue)
    }

    private func openEventEditor() {
        let add = app.buttons["chekinana.events.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 4))
        XCTAssertTrue(waitUntil(timeout: 4) { add.isHittable })
        add.tap()
        let editor = element("chekinana.events.editor")
        var appeared = editor.waitForExistence(timeout: 8)
        if !appeared, add.exists, add.isHittable {
            add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            appeared = editor.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(appeared)
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let resolvedName: String
        let width = app.windows.firstMatch.frame.width
        if name.hasPrefix("iphone-") && width >= 600 {
            resolvedName = name.replacingOccurrences(of: "iphone-", with: "ipad-", options: .anchored)
        } else if name.hasPrefix("iphone-") && width < 400 {
            resolvedName = name.replacingOccurrences(of: "iphone-", with: "small-", options: .anchored)
        } else {
            resolvedName = name
        }
        let url = screenshotDirectory.appendingPathComponent("\(resolvedName).png")
        try? screenshot.pngRepresentation.write(to: url, options: .atomic)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = resolvedName
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dumpHierarchy(_ name: String) {
        let description = app.debugDescription
        let url = screenshotDirectory.appendingPathComponent("\(name).txt")
        try? description.write(to: url, atomically: true, encoding: .utf8)
        capture("failure-\(name)")
        let attachment = XCTAttachment(string: description)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return condition()
    }

    private func scrollAboveTabBar(_ element: XCUIElement) {
        let tabBarTop = self.element("chekinana.shell.tabbar").frame.minY
        for _ in 0..<4 where !element.exists || element.frame.maxY > tabBarTop {
            app.swipeUp()
        }
    }
}
