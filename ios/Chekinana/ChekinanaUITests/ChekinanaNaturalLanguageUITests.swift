import XCTest

@MainActor
final class ChekinanaNaturalLanguageUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    func testConversationChromeUsesChekinanaCopyAndHidesQuickActions() {
        launchApp()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Chekinana"].waitForExistence(timeout: 5))
        XCTAssertEqual(prompt.placeholderValue, "Ask chekinana...")
        XCTAssertFalse(app.otherElements["chekinana.empty-state"].exists)
        XCTAssertEqual(transcriptValue, "messages=0")
        XCTAssertFalse(app.otherElements["chekinana.quick-actions"].exists)
        for identifier in [
            "chekinana.quick.add-idol",
            "chekinana.quick.event-weibo",
            "chekinana.quick.scan-photos",
            "chekinana.quick.list-cheki",
        ] {
            XCTAssertFalse(app.buttons[identifier].exists, identifier)
        }
    }

    func testChekiImagePreviewIsAccessibleAndIndependentFromSelection() {
        launchApp(chekiPreviewFixture: true)
        defer { app.terminate() }

        let openButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.cheki.preview.open.")
        )
        XCTAssertTrue(waitUntil(timeout: 8) { openButtons.count == 1 })
        let open = openButtons.firstMatch
        XCTAssertTrue(open.isHittable)
        XCTAssertGreaterThanOrEqual(open.frame.width, 44)
        XCTAssertGreaterThanOrEqual(open.frame.height, 44)
        XCTAssertTrue((open.value as? String)?.contains("2026.07.04") == true)
        let dateStatuses = app.staticTexts.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "chekinana.cheki.date-annotation."
            )
        )
        XCTAssertEqual(dateStatuses.count, 1)
        XCTAssertEqual(dateStatuses.firstMatch.label, "日期：2026.07.04")

        let selectButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.cheki.select.")
        )
        XCTAssertEqual(selectButtons.count, 1)
        let select = selectButtons.firstMatch
        XCTAssertEqual(select.label, "选择这张切")
        let transcriptBeforePreview = transcriptValue

        open.tap()
        let close = app.buttons["chekinana.cheki.preview.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["chekinana.cheki.preview.title"].exists)
        XCTAssertTrue(
            app.staticTexts["chekinana.cheki.preview.loaded"].waitForExistence(timeout: 5),
            "Preview fixture did not reach the loaded state"
        )
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        close.tap()

        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertEqual(transcriptValue, transcriptBeforePreview)
        XCTAssertEqual(select.label, "选择这张切")

        select.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { select.label == "已选中" })
        open.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["chekinana.cheki.preview.loaded"].waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertEqual(select.label, "已选中")
    }

    func testUnsupportedNaturalLanguageIsRejectedByTypedInterpreter() {
        launchApp()
        defer { app.terminate() }
        submit("显示帮助")

        assertTranscriptContains("显示帮助")
        assertTranscriptContains("这项请求暂不支持")
    }

    func testNaturalLanguageListIdolUsesTypedRemotePlan() {
        launchApp()
        defer { app.terminate() }
        submit("列出所有偶像")

        assertTranscriptContains("列出所有偶像")
        assertTranscriptContains("还没有添加 Idol")
        XCTAssertTrue(waitForReady(timeout: 8))
    }

    func testMultipleIntentsRequireClarificationWithoutExecution() {
        launchApp()
        defer { app.terminate() }
        submit("显示所有活动然后删除活动 Summer Live")

        assertTranscriptContains("这项请求暂不支持")
        XCTAssertFalse(transcriptValue.contains("理解为："))
        XCTAssertFalse(transcriptValue.contains("error:"))
    }

    func testMissingAddIdolNameRequiresClarificationWithoutExecution() {
        launchApp()
        defer { app.terminate() }
        submit("添加一个偶像")

        assertTranscriptContains("请补充要添加的 Idol 名称")
        XCTAssertFalse(transcriptValue.contains("理解为："))
        XCTAssertFalse(transcriptValue.contains("searching"))
    }

    func testCannotFindHostPreservesInputAndRetrySucceedsWithoutDuplicateEcho() {
        launchApp(stub: "retry_success")
        defer { app.terminate() }
        let input = "今天心情怎么样"
        submit(input)

        assertTranscriptContains("无法解析自然语言服务域名")
        XCTAssertEqual(prompt.value as? String, input)
        let retry = app.buttons["chekinana.nl.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertTrue(retry.isHittable)
        retry.tap()

        assertTranscriptContains("还没有添加 Idol")
        XCTAssertEqual(transcriptValue.components(separatedBy: input).count - 1, 1)
        XCTAssertFalse(retry.exists)
        XCTAssertTrue(prompt.isEnabled)
    }

    func testRemoteTransportErrorsAreTypedAndComposerRecovers() {
        assertRemoteErrors([
            ("cannot_find_host", "无法解析自然语言服务域名"),
            ("offline", "当前无法连接网络"),
            ("timeout", "自然语言服务响应超时"),
            ("connection_lost", "请求过程中网络连接中断"),
        ])
    }

    func testRemoteServiceErrorsAreTypedAndComposerRecovers() {
        assertRemoteErrors([
            ("401", "当前公开地址尚未提供自然语言解释服务"),
            ("429", "自然语言服务请求过于频繁"),
            ("rate_limit_unavailable", "自然语言服务暂时无法检查调用额度"),
            ("upstream_timeout", "自然语言模型响应超时"),
            ("upstream_unavailable", "自然语言模型上游暂时不可用"),
        ])
    }

    func testRemoteInvalidOutputErrorsAreTypedAndComposerRecovers() {
        assertRemoteErrors([
            ("invalid_model_output", "自然语言模型返回了无法安全执行的结果"),
            ("invalid_schema", "无法安全解析的内容"),
        ])
    }

    private func assertRemoteErrors(
        _ cases: [(stub: String, expected: String)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (stub, expected) in cases {
            launchApp(stub: stub)
            let input = "今天心情怎么样"
            submit(input, file: file, line: line)
            assertTranscriptContains(expected, file: file, line: line)
            XCTAssertEqual(prompt.value as? String, input, file: file, line: line)
            XCTAssertTrue(prompt.isEnabled, file: file, line: line)
            XCTAssertTrue(app.buttons["chekinana.nl.retry"].isHittable, file: file, line: line)
            app.terminate()
        }
    }

    func testInFlightInterpretationCanBeCancelledAndComposerRecovers() {
        launchApp(stub: "cancel")
        defer { app.terminate() }
        let input = "今天心情怎么样"
        submit(input)
        let cancel = app.buttons["chekinana.nl.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()

        assertTranscriptContains("已取消本次解释请求")
        XCTAssertEqual(prompt.value as? String, input)
        XCTAssertTrue(prompt.isEnabled)
        XCTAssertFalse(app.buttons["chekinana.nl.cancel"].exists)
    }

    func testDraftRetryAndCancelPreserveDraftAndClearBusy() {
        launchApp(stub: "draft_retry_success")
        submit("创建一个活动")
        assertTranscriptContains("还需要日期")
        let existing = confirmationIdentifiers(prefix: "chekinana.confirm.")
        submit("日期是 2026-08-09")
        assertTranscriptContains("无法解析自然语言服务域名")
        app.buttons["chekinana.nl.retry"].tap()
        _ = waitForNewConfirmation(after: existing, prefix: "chekinana.confirm.")
        XCTAssertTrue(waitForReady(timeout: 8))
        app.terminate()

        launchApp(stub: "draft_then_cancel")
        submit("创建一个活动")
        assertTranscriptContains("还需要日期")
        let followUp = "日期是 2026-08-09"
        submit(followUp)
        let cancel = app.buttons["chekinana.nl.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertEqual(prompt.value as? String, followUp)
        assertTranscriptContains("还需要日期")
        XCTAssertTrue(waitForReady(timeout: 8))
        app.terminate()
    }

    func testTaskLanguageDoesNotBypassInFlightInterpreter() {
        launchApp(stub: "cancel")
        defer { app.terminate() }
        submit("显示所有活动")
        let cancel = app.buttons["chekinana.nl.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        assertTranscriptContains("已取消本次解释请求")
    }

    func testNaturalConfirmationWithoutPendingOperationDoesNotWrite() {
        launchApp()
        defer { app.terminate() }
        submit("确认上一步")

        assertTranscriptContains("确认上一步")
        assertTranscriptContains("there is no pending operation to confirm")
    }

    func testClearRemovesTranscriptAndComposerRemainsUsable() {
        launchApp()
        defer { app.terminate() }
        submit("显示帮助")
        assertTranscriptContains("这项请求暂不支持")

        submit("清空聊天记录")
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.transcriptValue == "messages=0"
        }, "clear did not remove the visible transcript")
        XCTAssertFalse(app.otherElements["chekinana.empty-state"].exists)
        XCTAssertTrue(prompt.exists)
        XCTAssertTrue(sendButton.exists)

        submit("列出所有偶像")
        assertTranscriptContains("列出所有偶像")
        assertTranscriptContains("还没有添加 Idol")
    }

    func testRemoteSuccessAndFocus() {
        launchApp(stub: "success")
        defer { app.terminate() }
        submit("今天帮我整理一下")
        assertTranscriptContains("还没有添加 Event")
        XCTAssertEqual(transcriptValue.components(separatedBy: "今天帮我整理一下").count - 1, 1)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testKeyboardSubmitUsesSafeNaturalLanguagePath() {
        launchApp()
        defer { app.terminate() }
        guard focusPrompt() else {
            XCTFail("Keyboard did not appear")
            return
        }
        prompt.typeText("列出所有偶像")
        prompt.typeText("\n")

        assertTranscriptContains("列出所有偶像")
        assertTranscriptContains("还没有添加 Idol")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testComposerTracksKeyboardSafeAreaAndReturnsImmediatelyAfterDoneAndSend() throws {
        launchApp()
        defer { app.terminate() }
        let composerBottom = app.descendants(matching: .any)
            .matching(identifier: "chekinana.composer.bottom-marker")
            .firstMatch
        XCTAssertTrue(composerBottom.waitForExistence(timeout: 2))
        let restingPromptFrame = prompt.frame
        let restingComposerBottomFrame = composerBottom.frame
        let keyboard = app.keyboards.firstMatch

        prompt.tap()
        guard keyboard.waitForExistence(timeout: 2) else {
            throw XCTSkip("The simulator did not expose a software keyboard")
        }
        let appFrame = app.windows.firstMatch.frame
        guard keyboard.frame.minY < appFrame.maxY - 80 else {
            throw XCTSkip("The simulator exposed only the hardware-keyboard accessory bar")
        }
        var raisedPromptFrame = prompt.frame
        var raisedComposerBottomFrame = composerBottom.frame
        var keyboardFrame = keyboard.frame
        let composerRaised = waitUntil(timeout: 2) {
            raisedPromptFrame = self.prompt.frame
            raisedComposerBottomFrame = composerBottom.frame
            keyboardFrame = keyboard.frame
            return raisedComposerBottomFrame.maxY <= keyboardFrame.minY + 1
                && restingPromptFrame.minY - raisedPromptFrame.minY > 80
                && restingComposerBottomFrame.minY - raisedComposerBottomFrame.minY > 80
        }
        XCTAssertTrue(
            composerRaised,
            "Composer did not immediately follow the keyboard safe area. "
                + "restingPrompt=\(restingPromptFrame), raisedPrompt=\(raisedPromptFrame), "
                + "restingComposerBottom=\(restingComposerBottomFrame), "
                + "raisedComposerBottom=\(raisedComposerBottomFrame), "
                + "keyboard=\(keyboardFrame)"
        )

        let done = app.buttons["chekinana.keyboard.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 1))
        done.tap()
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                !keyboard.exists
                    && abs(self.prompt.frame.minY - restingPromptFrame.minY) < 8
                    && abs(composerBottom.frame.minY - restingComposerBottomFrame.minY) < 8
            },
            "Composer did not immediately return after Done dismissed the keyboard"
        )

        prompt.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2))
        prompt.typeText("列出所有偶像")
        XCTAssertTrue(sendButton.isEnabled && sendButton.isHittable)
        sendButton.tap()
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                !keyboard.exists
                    && abs(self.prompt.frame.minY - restingPromptFrame.minY) < 8
                    && abs(composerBottom.frame.minY - restingComposerBottomFrame.minY) < 8
            },
            "Composer did not immediately return after sending"
        )
    }

    func testAddIdolConfirmationAccessibilityAndPersistence() {
        launchApp(enrichmentFixture: true)
        defer { app.terminate() }

        submitWithArrow("添加偶像 Alice")
        assertTranscriptContains("添加偶像 Alice")
        XCTAssertTrue(waitForReady(timeout: 15))
        assertIdolCardInformation(lineCount: 3)
        let candidate = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idol.candidate.select.")
        ).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 8))
        candidate.tap()
        XCTAssertTrue(
            app.images.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idol.candidate.confirmed.")
            ).firstMatch.waitForExistence(timeout: 8)
        )
        submit("清空聊天记录")
        submit("列出所有偶像")
        assertTranscriptContains("列出所有偶像")
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.app.staticTexts["Alice"].exists },
            "Confirmed Idol was not visible after clearing and listing persisted data"
        )
        assertIdolCardInformation(lineCount: 3)
        XCTAssertTrue(app.staticTexts["0 Cheki"].exists)
    }

    func testMultiIdolSelectionConfirmationReturnsReadyAndResolvesCandidates() {
        launchApp(multiEnrichmentFixture: true)
        defer { app.terminate() }

        submitWithArrow("添加偶像 Alice")
        XCTAssertTrue(waitForReady(timeout: 15), "Idol candidates did not finish loading")

        let candidates = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idol.candidate.select.")
        )
        XCTAssertTrue(waitUntil(timeout: 8) { candidates.count == 2 }, "Expected two Idol candidates")
        assertIdolCardInformation(lineCount: 6)
        let selected = candidates.element(boundBy: 0)
        XCTAssertTrue(selected.isHittable)
        selected.tap()

        XCTAssertTrue(waitForReady(timeout: 8), "Candidate selection remained busy")
        XCTAssertTrue(
            waitUntil(timeout: 8) { candidates.count == 1 },
            "Confirmed candidate remained selectable or hid the other candidate"
        )
        XCTAssertTrue(
            app.images.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idol.candidate.confirmed.")
            ).firstMatch.exists
        )

        submit("清空聊天记录")
        submit("列出所有偶像")
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                self.app.staticTexts["Alice"].exists || self.app.staticTexts["Alice Second"].exists
            },
            "Confirmed selected Idol was not persisted"
        )
    }

    func testNineReturnedIdolCandidatesAllRenderWithoutLoadMore() {
        launchApp(nineEnrichmentFixture: true)
        defer { app.terminate() }

        submitWithArrow("添加偶像 Nine Candidate")
        XCTAssertTrue(waitForReady(timeout: 15), "Nine Idol candidates did not finish loading")

        let candidates = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idol.candidate.select.")
        )
        XCTAssertTrue(
            waitUntil(timeout: 8) { candidates.count == 9 },
            "Expected every one of the nine returned candidates to be rendered"
        )
        for index in 1...9 {
            XCTAssertTrue(app.staticTexts["Nine Candidate \(index)"].exists)
        }
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Load more")
            ).firstMatch.exists
        )
    }

    func testTypedLocalLookingPhrasesAlwaysStartRemoteInterpretation() {
        for input in [
            "添加以下idol：巫歌 饭饭 木兰 aina eriko mina 石榴 优子 萝北",
            "扫描已选照片",
            "scancheki",
            "取消",
        ] {
            launchApp(stub: "cancel")
            submitWithArrow(input)

            let remoteCancel = app.buttons["chekinana.nl.cancel"]
            XCTAssertTrue(
                remoteCancel.waitForExistence(timeout: 3),
                "Typed text did not reach remote interpretation: \(input)"
            )
            XCTAssertFalse(app.buttons["chekinana.media.cancel"].exists)
            XCTAssertFalse(
                app.buttons.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idol.candidate.select.")
                ).firstMatch.exists
            )
            remoteCancel.tap()
            assertTranscriptContains("已取消本次解释请求")
            app.terminate()
        }
    }

    func testWeiboEventCandidateEditsPrepareConfirmAndPersistSevenFields() {
        launchApp(stub: "event_candidate", eventCandidateStub: "fixture")
        defer { app.terminate() }
        let existingConfirmations = confirmationIdentifiers(prefix: "chekinana.confirm.")

        submitWithArrow("https://weibo.com/123456/AbC123")
        XCTAssertTrue(waitForReady(timeout: 8), "Event extraction did not return to ready")
        XCTAssertTrue(app.textFields["chekinana.event.candidate.name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["chekinana.event.candidate.date"].exists)
        XCTAssertTrue(app.textFields["chekinana.event.candidate.city"].exists)
        XCTAssertTrue(app.textFields["chekinana.event.candidate.livehouse"].exists)
        XCTAssertTrue(app.textFields["chekinana.event.candidate.weibo-url"].exists)
        XCTAssertTrue(app.textFields["chekinana.event.candidate.ticket-url"].exists)
        XCTAssertTrue(app.textViews["chekinana.event.candidate.note"].exists)
        XCTAssertTrue(app.staticTexts["chekinana.event.candidate.date-undetermined"].exists)

        let prepare = app.buttons["chekinana.event.candidate.prepare"]
        XCTAssertTrue(prepare.isEnabled && prepare.isHittable)
        XCTAssertGreaterThanOrEqual(prepare.frame.width, 44)
        XCTAssertGreaterThanOrEqual(prepare.frame.height, 44)
        prepare.tap()
        XCTAssertFalse(app.textFields["chekinana.event.candidate.name"].exists)
        let confirmationID = waitForNewConfirmation(
            after: existingConfirmations,
            prefix: "chekinana.confirm."
        )
        tapConfirmation(identifier: confirmationID)

        submit("清空聊天记录")
        submit("显示所有活动")
        XCTAssertTrue(waitUntil(timeout: 8) { self.app.staticTexts["名称：Fixture Live"].exists })
        XCTAssertTrue(app.staticTexts["日期：未确定日期"].exists)
        XCTAssertTrue(app.staticTexts["城市：上海"].exists)
        XCTAssertTrue(app.staticTexts["场地：Fixture Livehouse 中大二号馆"].exists)
    }

    func testWeiboEventAddressBlockerAndInFlightTranscriptActivityWriteNothing() {
        launchApp(stub: "event_candidate", eventCandidateStub: "address_fixture")
        submitWithArrow("创建 Event https://weibo.com/123456/AbC123")
        XCTAssertTrue(waitForReady(timeout: 8))
        let prepare = app.buttons["chekinana.event.candidate.prepare"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        XCTAssertFalse(prepare.isEnabled)
        XCTAssertTrue(app.staticTexts["chekinana.event.candidate.blocker.livehouse-address"].exists)
        app.buttons["chekinana.event.candidate.cancel"].tap()
        XCTAssertTrue(waitForReady(timeout: 5))
        app.terminate()

        launchApp(stub: "event_candidate", eventCandidateStub: "hang")
        submitWithArrow("https://weibo.com/123456/AbC123")
        let activity = app.activityIndicators["chekinana.transcript.activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertFalse(app.activityIndicators["chekinana.event.candidate.extracting"].exists)
        XCTAssertFalse(app.buttons["chekinana.event.candidate.extract.cancel"].exists)
        XCTAssertFalse(app.buttons["chekinana.media.cancel"].exists)
        XCTAssertFalse(app.buttons["chekinana.nl.cancel"].exists)
        app.terminate()

        launchApp(resetStore: false)
        submit("显示所有活动")
        assertTranscriptContains("还没有添加 Event")
        app.terminate()
    }

    func testEventCandidateEditingDoesNotReleaseAnotherBusyFlow() {
        launchApp(stub: "event_candidate_then_cancel", eventCandidateStub: "fixture")
        defer { app.terminate() }

        submitWithArrow("addevent https://weibo.com/123456/AbC123")
        XCTAssertTrue(waitForReady(timeout: 8))
        let name = app.textFields["chekinana.event.candidate.name"]
        let prepare = app.buttons["chekinana.event.candidate.prepare"]
        let candidateCancel = app.buttons["chekinana.event.candidate.cancel"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))

        submit("今天心情怎么样")
        let nlCancel = app.buttons["chekinana.nl.cancel"]
        XCTAssertTrue(nlCancel.waitForExistence(timeout: 5))
        XCTAssertFalse(name.isEnabled)
        XCTAssertFalse(prepare.isEnabled)
        XCTAssertFalse(candidateCancel.isEnabled)

        nlCancel.tap()
        XCTAssertTrue(waitForReady(timeout: 5))
        XCTAssertTrue(name.isEnabled)
        XCTAssertTrue(prepare.isEnabled)
        XCTAssertTrue(candidateCancel.isEnabled)
    }

    func testLongAndControlInputAreRejectedLocally() {
        launchApp(stub: "success", prefill: String(repeating: "长", count: 1_001))
        submitPrefilled()
        assertTranscriptContains("输入不符合自然语言服务的安全限制")
        XCTAssertFalse(app.buttons["chekinana.nl.retry"].exists)
        app.terminate()

        launchApp(stub: "success", prefill: "请帮我看看\u{0007}这个")
        submitPrefilled()
        assertTranscriptContains("输入不符合自然语言服务的安全限制")
        XCTAssertFalse(app.buttons["chekinana.nl.retry"].exists)
        app.terminate()
    }

    func testCredentialedURLAndMultipleIntentAreRejectedWithoutWrites() {
        launchApp(stub: "success")
        submit("请添加活动 https://user:password@example.com/live")
        assertTranscriptContains("检测到可能的凭据或本地标识")
        XCTAssertFalse(transcriptValue.contains("password"))
        XCTAssertFalse(app.buttons["chekinana.nl.cancel"].exists)
        submit("显示所有活动")
        assertTranscriptContains("还没有添加 Event")
        app.terminate()

        launchApp()
        submit("列出所有偶像然后删除偶像 Alice")
        assertTranscriptContains("这项请求暂不支持")
        XCTAssertFalse(transcriptValue.contains("理解为："))
        app.terminate()
    }

    func testTypedConfirmationCodeIsPrivacyRejectedBeforeRemoteInterpretation() {
        launchApp()
        defer { app.terminate() }
        let existingConfirmations = confirmationIdentifiers(prefix: "chekinana.confirm.")

        submit("添加活动 Privacy Fixture 2026-08-09")
        XCTAssertTrue(waitForReady(timeout: 15))
        let identifier = waitForNewConfirmation(
            after: existingConfirmations,
            prefix: "chekinana.confirm."
        )
        let code = String(identifier.dropFirst("chekinana.confirm.".count))
        XCTAssertFalse(code.isEmpty)

        submit("确认 \(code)")

        assertTranscriptContains("检测到可能的凭据或本地标识")
        XCTAssertFalse(transcriptValue.contains(code))
        XCTAssertFalse(app.buttons["chekinana.nl.cancel"].exists)
    }

    func testRetryMutationAndInFlightCancelDoNotDuplicateWritesOrEchoes() {
        launchApp(stub: "retry_add_event_success")
        let input = "帮我创建重试活动"
        let existingConfirmations = confirmationIdentifiers(prefix: "chekinana.confirm.")
        submit(input)
        assertTranscriptContains("无法解析自然语言服务域名")
        XCTAssertEqual(prompt.value as? String, input)
        let retry = app.buttons["chekinana.nl.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        assertTranscriptContains("已准备好这项更改")
        let confirmationID = waitForNewConfirmation(
            after: existingConfirmations,
            prefix: "chekinana.confirm."
        )
        XCTAssertEqual(transcriptValue.components(separatedBy: input).count - 1, 1)
        tapConfirmation(identifier: confirmationID)
        XCTAssertTrue(app.staticTexts["名称：Remote Retry"].waitForExistence(timeout: 8))

        submit("清空聊天记录")
        submit("显示所有活动")
        let persistedEventNames = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "名称：Remote Retry")
        )
        XCTAssertTrue(waitUntil(timeout: 8) { persistedEventNames.count == 1 })
        app.terminate()

        launchApp(stub: "cancel")
        let cancelledInput = "帮我创建一个不会落库的活动"
        submit(cancelledInput)
        let cancel = app.buttons["chekinana.nl.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        assertTranscriptContains("已取消本次解释请求")
        XCTAssertEqual(prompt.value as? String, cancelledInput)
        XCTAssertEqual(transcriptValue.components(separatedBy: cancelledInput).count - 1, 1)
        app.terminate()
        launchApp(stub: "success", resetStore: false)
        submit("显示所有活动")
        assertTranscriptContains("还没有添加 Event")
        app.terminate()
    }

    func testOptionalRealEndpointLLMFirstAndWeiboExtractorSmoke() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CHEKINANA_RUN_REAL_NL_SMOKE"] == "1" else {
            throw XCTSkip("Set CHEKINANA_RUN_REAL_NL_SMOKE=1 to call the deployed NL endpoint")
        }
        guard let weiboURL = environment["CHEKINANA_REAL_WEIBO_SMOKE_URL"],
              !weiboURL.isEmpty else {
            throw XCTSkip("Set CHEKINANA_REAL_WEIBO_SMOKE_URL to a public status URL")
        }

        launchApp(realNLEndpoint: true)
        defer { app.terminate() }

        submit("请帮我盘点一下当前数据库里已经登记过的演出场次")
        assertTranscriptContains("还没有添加 Event")
        XCTAssertTrue(waitForReady(timeout: 20))

        submitWithArrow("请根据这条公开微博创建活动：\(weiboURL)")
        XCTAssertTrue(
            app.textFields["chekinana.event.candidate.name"].waitForExistence(timeout: 30),
            "Typed addevent/url did not trigger the seven-field extractor"
        )
        XCTAssertTrue(app.textFields["chekinana.event.candidate.weibo-url"].exists)
        app.buttons["chekinana.event.candidate.cancel"].tap()
        XCTAssertTrue(waitForReady(timeout: 8))
    }

    func testIdolEventChekiCRUDIndexGroupingChoicesAndPersistenceRelaunch() throws {
        throw XCTSkip("Legacy scenario includes edit/delete intents outside the current v1 NL whitelist")
        /*
        launchApp(mediaFixture: true, enrichmentFixture: true)
        defer { app.terminate() }

        submitAndConfirm("添加偶像 Alice")
        submitAndConfirm("添加偶像 Alicia")
        submitAndConfirm("添加偶像 Bob")

        submitAndConfirm("添加活动 https://example.com/events/url-only")
        assertTranscriptContains("已添加 Event")
        submitAndConfirm("添加活动 Live Night 2026-08-02")
        assertTranscriptContains("名称：Live Night")

        let existingCancellations = confirmationIdentifiers(prefix: "chekinana.cancel.")
        submit("添加活动 Cancelled Event 2026-08-05")
        let cancellationID = waitForNewConfirmation(
            after: existingCancellations,
            prefix: "chekinana.cancel."
        )
        tapConfirmation(identifier: cancellationID)
        assertTranscriptContains("cancelled confirmation")

        submitAndConfirm("把活动 Live Night 的名称改成 Live Final")
        submitAndConfirm("把活动 Live Final 的日期改成 2026-08-03")
        assertTranscriptContains("已更新 Event")
        submit("查看活动 Live Final")
        assertTranscriptContains("名称：Live Final")
        assertTranscriptContains("日期：2026-08-03")

        submit("帮我记录这些切")
        assertTranscriptContains("已识别出 3 张切")
        let shortcut = app.buttons["为全部切补充信息"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 8))
        XCTAssertTrue(shortcut.isHittable)
        shortcut.tap()
        assertTranscriptContains("还需要 Idol")

        let aliceChoice = app.buttons["Alice"]
        let bobChoice = app.buttons["Bob"]
        XCTAssertTrue(aliceChoice.waitForExistence(timeout: 5))
        XCTAssertTrue(aliceChoice.isHittable)
        aliceChoice.tap()
        XCTAssertTrue(bobChoice.isHittable)
        bobChoice.tap()
        let continueButton = app.buttons["chekinana.clarification.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        XCTAssertTrue(continueButton.isHittable)
        continueButton.tap()
        assertTranscriptContains("还需要 Event 或日期")

        let existingChekiConfirmations = confirmationIdentifiers(prefix: "chekinana.confirm.")
        let liveChoice = app.buttons["Live Final"]
        XCTAssertTrue(liveChoice.waitForExistence(timeout: 5))
        XCTAssertTrue(liveChoice.isHittable)
        liveChoice.tap()
        tapAllNewConfirmations(
            after: existingChekiConfirmations,
            expectedCount: 3
        )

        var selectionIdentifiers = listPersistedChekiSelectionIdentifiers(expectedCount: 3)
        assertVisibleIndexesOneThroughThree()
        selectPersistedCheki(identifier: selectionIdentifiers[0])
        submit("查看这张切")
        XCTAssertTrue(app.staticTexts["Live Final · Alice、Bob"].exists || app.staticTexts["Alice、Bob · Live Final"].exists)

        submit("扫描这些切")
        assertTranscriptContains("已识别出 3 张切")
        let dateConfirmations = confirmationIdentifiers(prefix: "chekinana.confirm.")
        submit("把全部扫描结果保存给 Alice、Bob，日期是 2026-08-04")
        tapAllNewConfirmations(after: dateConfirmations, expectedCount: 3)
        selectionIdentifiers = listPersistedChekiSelectionIdentifiers(expectedCount: 6)
        assertVisibleIndexesOneThroughThree()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2026-08-04")).count >= 3)

        app.terminate()
        launchApp(
            stub: "ambiguous_idol",
            resetStore: false,
            mediaFixture: true,
            enrichmentFixture: true
        )
        submit("显示所有活动")
        assertTranscriptContains("链接：https://example.com/events/url-only")
        assertTranscriptContains("名称：Live Final")
        XCTAssertFalse(transcriptValue.contains("Cancelled Event"))
        selectionIdentifiers = listPersistedChekiSelectionIdentifiers(expectedCount: 6)
        assertVisibleIndexesOneThroughThree()

        submit("请展示这个人的资料")
        assertTranscriptContains("找到多个匹配的 Idol")
        XCTAssertTrue(app.buttons["Alice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Alicia"].exists)
        app.buttons["Alice"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { self.app.staticTexts["Alice"].exists })

        submitAndConfirm("把偶像 Alice 的名字改成 AlicePrime")
        submit("查看偶像 AlicePrime")
        XCTAssertTrue(waitUntil(timeout: 8) { self.app.staticTexts["AlicePrime"].exists })

        selectPersistedCheki(identifier: selectionIdentifiers[0])
        submitAndConfirm("把这张切的备注改成 updated")
        submit("查看这张切")
        XCTAssertTrue(waitUntil(timeout: 8) { self.app.staticTexts["备注：updated"].exists })

        for remainingCount in stride(from: 6, through: 1, by: -1) {
            let remaining = listPersistedChekiSelectionIdentifiers(expectedCount: remainingCount)
            selectPersistedCheki(identifier: remaining[0])
            submitAndConfirm("删除这张切")
            assertTranscriptContains("已删除这张切")
        }
        submit("清空聊天记录")
        submit("显示所有切")
        assertTranscriptContains("还没有保存的切")

        submitAndConfirm("删除活动 https://example.com/events/url-only")
        submitAndConfirm("删除活动 Live Final")
        submit("清空聊天记录")
        submit("显示所有活动")
        assertTranscriptContains("还没有添加 Event")

        submitAndConfirm("删除偶像 AlicePrime")
        submitAndConfirm("删除偶像 Alicia")
        submitAndConfirm("删除偶像 Bob")
        submit("清空聊天记录")
        submit("列出所有偶像")
        assertTranscriptContains("还没有添加 Idol")
        */
    }

    private var prompt: XCUIElement {
        app.textFields["chekinana.prompt"]
    }

    private var sendButton: XCUIElement {
        app.buttons["chekinana.send"]
    }

    private var transcript: XCUIElement {
        app.otherElements["chekinana.transcript"]
    }

    private var transcriptValue: String {
        transcript.value as? String ?? ""
    }

    private func launchApp(
        stub: String? = nil,
        resetStore: Bool = true,
        mediaFixture: Bool = false,
        chekiPreviewFixture: Bool = false,
        enrichmentFixture: Bool = false,
        multiEnrichmentFixture: Bool = false,
        nineEnrichmentFixture: Bool = false,
        idolConfirmationStub: String? = nil,
        eventCandidateStub: String? = nil,
        realNLEndpoint: Bool = false,
        prefill: String? = nil
    ) {
        continueAfterFailure = false
        terminateCurrentAppAndWait()
        let launchID = UUID().uuidString.lowercased()
        app = XCUIApplication()
        app.launchEnvironment["CHEKINANA_UI_TEST_STORE"] = "1"
        app.launchEnvironment["CHEKINANA_UI_LAUNCH_ID"] = launchID
        if resetStore {
            app.launchEnvironment["CHEKINANA_UI_RESET_STORE"] = "1"
        }
        if let stub {
            app.launchEnvironment["CHEKINANA_NL_UI_STUB"] = stub
        } else if !realNLEndpoint {
            app.launchEnvironment["CHEKINANA_NL_UI_STUB"] = "ui_router"
        }
        if mediaFixture {
            app.launchEnvironment["CHEKINANA_MEDIA_UI_STUB"] = "fixture"
        }
        if chekiPreviewFixture {
            app.launchEnvironment["CHEKINANA_CHEKI_PREVIEW_UI_STUB"] = "fixture"
        }
        if nineEnrichmentFixture {
            app.launchEnvironment["CHEKINANA_IDOL_UI_STUB"] = "nine_fixture"
        } else if multiEnrichmentFixture {
            app.launchEnvironment["CHEKINANA_IDOL_UI_STUB"] = "multi_fixture"
        } else if enrichmentFixture {
            app.launchEnvironment["CHEKINANA_IDOL_UI_STUB"] = "fixture"
        }
        if let idolConfirmationStub {
            app.launchEnvironment["CHEKINANA_IDOL_CONFIRM_UI_STUB"] = idolConfirmationStub
        }
        if let eventCandidateStub {
            app.launchEnvironment["CHEKINANA_EVENT_CANDIDATE_UI_STUB"] = eventCandidateStub
        }
        if let prefill {
            app.launchEnvironment["CHEKINANA_UI_PREFILL"] = prefill
        }
        app.launch()
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.app.state == .runningForeground },
            "App did not reach the foreground"
        )
        let launchMarker = app.descendants(matching: .any)
            .matching(identifier: "chekinana.launch-marker")
            .firstMatch
        XCTAssertTrue(
            launchMarker.waitForExistence(timeout: 8)
                && waitUntil(timeout: 8) { launchMarker.value as? String == launchID },
            "App did not expose the marker for this launch"
        )
        XCTAssertTrue(prompt.waitForExistence(timeout: 8), "Prompt field did not appear")
        XCTAssertTrue(waitForReady(timeout: 8), "App did not become ready")
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.prompt.isHittable },
            "Prompt field did not become hittable"
        )
        if let prefill {
            XCTAssertFalse(prefill.isEmpty)
            XCTAssertTrue(
                waitUntil(timeout: 8) { self.sendButton.isEnabled && self.sendButton.isHittable },
                "Prefilled prompt did not enable submission"
            )
        }
    }

    private func terminateCurrentAppAndWait(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard app.state != .notRunning else { return }
        app.terminate()
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.app.state == .notRunning },
            "Previous app process did not terminate",
            file: file,
            line: line
        )
    }

    private func submit(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard typeIntoPrompt(text, file: file, line: line) else { return }
        prompt.typeText("\n")
    }

    private func submitWithArrow(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard typeIntoPrompt(text, file: file, line: line) else { return }
        guard dismissPromptKeyboard() else {
            XCTFail("Keyboard did not dismiss through its semantic toolbar action", file: file, line: line)
            return
        }
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.sendButton.isEnabled && self.sendButton.isHittable },
            "Send button did not become actionable",
            file: file,
            line: line
        )
        sendButton.tap()
    }

    private func typeIntoPrompt(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.app.state == .runningForeground },
            "App left the foreground before submission",
            file: file,
            line: line
        )
        XCTAssertTrue(waitForReady(timeout: 8), "Previous operation did not finish", file: file, line: line)
        XCTAssertTrue(waitUntil(timeout: 8) { self.prompt.isEnabled }, "Prompt remained disabled", file: file, line: line)
        XCTAssertTrue(waitUntil(timeout: 8) { self.prompt.isHittable }, "Prompt was not hittable", file: file, line: line)
        guard focusPrompt() else {
            XCTFail("Keyboard did not appear after three semantic focus attempts", file: file, line: line)
            return false
        }
        prompt.typeText(text)
        return true
    }

    private func focusPrompt() -> Bool {
        let keyboard = app.keyboards.firstMatch
        for attempt in 0..<3 {
            guard waitUntil(timeout: 1, condition: {
                self.app.state == .runningForeground
            }), waitForReady(timeout: 1), waitUntil(timeout: 1, condition: {
                self.prompt.isHittable
            }) else {
                return false
            }

            prompt.tap()
            if keyboard.waitForExistence(timeout: 4) {
                return true
            }

            if attempt < 2 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.75))
            }
        }

        return false
    }

    private func dismissPromptKeyboard() -> Bool {
        let keyboard = app.keyboards.firstMatch
        let done = app.buttons["chekinana.keyboard.done"]
        guard done.waitForExistence(timeout: 4), done.isHittable else {
            return false
        }
        done.tap()
        return waitUntil(timeout: 4) { !keyboard.exists }
    }

    private func submitPrefilled(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(sendButton.isEnabled, "Send button remained disabled", file: file, line: line)
        XCTAssertTrue(sendButton.isHittable, "Send button was not hittable", file: file, line: line)
        sendButton.tap()
    }

    private func submitAndConfirm(_ command: String, file: StaticString = #filePath, line: UInt = #line) {
        let existing = confirmationIdentifiers(prefix: "chekinana.confirm.")
        submit(command, file: file, line: line)
        assertTranscriptContains(command, file: file, line: line)
        XCTAssertTrue(
            waitForReady(timeout: 15),
            "Command did not finish preparing its confirmation",
            file: file,
            line: line
        )
        let identifier = waitForNewConfirmation(
            after: existing,
            prefix: "chekinana.confirm.",
            file: file,
            line: line
        )
        tapConfirmation(identifier: identifier, file: file, line: line)
    }

    private func confirmationButtons(prefix: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    private func confirmationIdentifiers(prefix: String) -> Set<String> {
        Set(confirmationButtons(prefix: prefix).allElementsBoundByIndex.map(\.identifier))
    }

    private func waitForNewConfirmation(
        after existing: Set<String>,
        prefix: String,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        var result: String?
        XCTAssertTrue(waitUntil(timeout: timeout) {
            result = self.confirmationIdentifiers(prefix: prefix).subtracting(existing).first
            return result != nil
        }, "No new confirmation control appeared", file: file, line: line)
        return result ?? ""
    }

    private func tapConfirmation(
        identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Confirmation control did not exist", file: file, line: line)
        XCTAssertTrue(waitUntil(timeout: 5) { button.isHittable }, "Confirmation control was not hittable", file: file, line: line)
        let expectedText = identifier.hasPrefix("chekinana.cancel.")
            ? "已选择取消"
            : "已选择确认"
        button.tap()
        assertTranscriptContains(expectedText, file: file, line: line)
        XCTAssertTrue(waitForReady(timeout: 15), "Confirmed operation did not finish", file: file, line: line)
    }

    private func tapAllNewConfirmations(
        after existing: Set<String>,
        expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var identifiers: [String] = []
        XCTAssertTrue(waitUntil(timeout: 8) {
            identifiers = Array(
                self.confirmationIdentifiers(prefix: "chekinana.confirm.")
                    .subtracting(existing)
            ).sorted()
            return identifiers.count == expectedCount
        }, "Expected \(expectedCount) new confirmation controls", file: file, line: line)

        for identifier in identifiers {
            tapConfirmation(identifier: identifier, file: file, line: line)
        }
    }

    private func listPersistedChekiSelectionIdentifiers(
        expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [String] {
        submit("清空聊天记录", file: file, line: line)
        submit("显示所有切", file: file, line: line)
        var result: [String] = []
        XCTAssertTrue(waitUntil(timeout: 8) {
            let buttons = self.app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.cheki.select.")
            )
            result = buttons.allElementsBoundByIndex.map(\.identifier)
            return result.count == expectedCount
        }, "Expected \(expectedCount) selectable Cheki cards, found \(result.count)", file: file, line: line)
        return result
    }

    private func selectPersistedCheki(
        identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(waitUntil(timeout: 5) { button.isHittable }, file: file, line: line)
        button.tap()
        assertTranscriptContains("已选中", file: file, line: line)
    }

    private func assertVisibleIndexesOneThroughThree(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for idx in 1...3 {
            XCTAssertTrue(
                app.staticTexts["第 \(idx) 张切"].waitForExistence(timeout: 5),
                "Missing visible Cheki index \(idx)",
                file: file,
                line: line
            )
        }
    }

    private func assertTranscriptContains(
        _ text: String,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntil(timeout: timeout) { self.transcriptValue.contains(text) },
            "Transcript did not contain: \(text)",
            file: file,
            line: line
        )
    }

    private func assertIdolCardInformation(
        lineCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lines = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chekinana.idol.card.line.")
        )
        XCTAssertTrue(
            waitUntil(timeout: 8) { lines.count == lineCount },
            "Expected \(lineCount) Idol information lines, found \(lines.count)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Catalogue ID:")).count,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Bio:")).count,
            0,
            file: file,
            line: line
        )
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }

    private func waitForReady(timeout: TimeInterval) -> Bool {
        let root = app.descendants(matching: .any)
            .matching(identifier: "chekinana.root")
            .firstMatch
        return root.waitForExistence(timeout: min(timeout, 3)) && waitUntil(timeout: timeout) {
            root.value as? String == "ready"
        }
    }
}
