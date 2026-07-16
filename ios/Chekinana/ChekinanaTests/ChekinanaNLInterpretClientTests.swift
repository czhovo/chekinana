import Foundation
import XCTest
@testable import Chekinana

final class ChekinanaNLInterpretClientTests: XCTestCase {
    override func tearDown() {
        ChekinanaMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testRequestIsMinimalNoStoreAndDecodesPlan() async throws {
        let expectation = expectation(description: "request captured")
        nonisolated(unsafe) var capturedRequest: URLRequest?
        nonisolated(unsafe) var capturedBody: Data?
        ChekinanaMockURLProtocol.handler = { request in
            capturedRequest = request
            capturedBody = requestBodyData(request)
            expectation.fulfill()
            return (
                200,
                Data(#"{"version":1,"kind":"plan","operations":[{"intent":"addcheki","slots":{"idols":["用户输入的名字"],"date":"2026-07-16","user":"?"}}]}"#.utf8)
            )
        }
        let client = makeClient()
        let draft = ChekinanaNLRequestDraft(
            operation: ChekinanaNLOperation(
                intent: .addcheki,
                slots: .init(idols: ["用户输入的名字"])
            ),
            missing: [.eventOrDate]
        )

        let result = try await client.interpret(
            utterance: "用户输入的续句",
            localDate: "2026-07-16",
            timezone: "Asia/Shanghai",
            draft: draft
        )
        await fulfillment(of: [expectation], timeout: 1)

        guard case .plan(let operations) = result else {
            return XCTFail("expected plan")
        }
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations[0].intent, .addcheki)
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.timeoutInterval, 12)
        XCTAssertEqual(ChekinanaNLInterpretClient.transportTimeout, 12)
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Cookie"))

        let body = try XCTUnwrap(capturedBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "utterance", "localDate", "timezone", "draft"])
        XCTAssertEqual(object["utterance"] as? String, "用户输入的续句")
        let encodedDraft = try XCTUnwrap(object["draft"] as? [String: Any])
        XCTAssertEqual(Set(encodedDraft.keys), ["intent", "slots", "missing"])
        XCTAssertEqual(encodedDraft["intent"] as? String, "addcheki")
        XCTAssertEqual(encodedDraft["missing"] as? [String], ["event_or_date"])
        let encodedSlots = try XCTUnwrap(encodedDraft["slots"] as? [String: Any])
        XCTAssertEqual(Set(encodedSlots.keys), ["idols"])
        XCTAssertEqual(encodedSlots["idols"] as? [String], ["用户输入的名字"])
        let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(bodyText.contains("本地数据库私有名字"))
        XCTAssertFalse(bodyText.contains("deadbeef"))
        XCTAssertFalse(bodyText.contains("imageData"))
        XCTAssertFalse(bodyText.contains("AAECAwQ="))
        XCTAssertFalse(bodyText.contains("selections"))
        XCTAssertFalse(bodyText.contains("localChoice"))
        XCTAssertFalse(bodyText.contains("selectedIdolIDs"))
        XCTAssertFalse(bodyText.contains("selectedEventID"))
        XCTAssertFalse(bodyText.contains("confirmationCode"))
        XCTAssertFalse(bodyText.contains("550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertFalse(bodyText.contains("database"))
        XCTAssertFalse(bodyText.contains("photo"))
    }

    func testUtteranceOverBackendLimitDoesNotSendRequest() async {
        nonisolated(unsafe) var requestCount = 0
        ChekinanaMockURLProtocol.handler = { _ in
            requestCount += 1
            return (200, Data(#"{"version":1,"kind":"reject","code":"unexpected"}"#.utf8))
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await self.makeClient().interpret(
                utterance: String(repeating: "a", count: 1_001),
                localDate: "2026-07-16",
                timezone: "Asia/Shanghai"
            )
        } verify: { error in
            XCTAssertEqual(error as? ChekinanaNLClientError, .invalidRequest)
        }
        XCTAssertEqual(requestCount, 0)
    }

    func testSensitiveInputGuardFailsClosedBeforeURLSession() async {
        nonisolated(unsafe) var requestCount = 0
        ChekinanaMockURLProtocol.handler = { _ in
            requestCount += 1
            return (200, Data(#"{"version":1,"kind":"reject","code":"unexpected"}"#.utf8))
        }
        let client = makeClient()
        let sensitiveInputs = [
            "请处理 deadbeef",
            "对象 00000000-0000-4000-8000-000000000000",
            "Authorization: secret-value",
            "Cookie: session=value",
            "cookie=session=value",
            "Bearer secret-value",
            "X-Cheki-Token: secret-value",
            "access_token=secret-value",
            "refresh token: secret-value",
            "token=secret-value",
            "pod id: example",
            "pod_token=example",
            "pod abc123xyz",
            "runpod abc123xyz",
            "Pod ID 为 abc123xyz，用来扫描这些照片",
            "Pod ID 是 abc123xyz，扫描这些照片",
            "Pod ID 为 abcdefghi，用来扫描这些照片",
            "Pod ID 是 abcdefgh-，扫描这些照片",
            "Pod ID：abcdefgh_，用于识别这些照片",
            "scancheki abcdefghi",
            "scancheki pod=abcdefghi",
            "scancheki expected=2",
            "scancheki;",
            "scancheki;expected=2",
            "scancheki：expected=2",
            "scancheki\nexpected=2",
            "scanchekipod=abcdefghi",
            "https://abc123xyz-8000.proxy.runpod.net/api",
            "添加 Event https://user:password@example.com/live",
        ]

        for input in sensitiveInputs {
            await XCTAssertThrowsErrorAsync {
                _ = try await client.interpret(
                    utterance: input,
                    localDate: "2026-07-16",
                    timezone: "Asia/Shanghai",
                    activeConfirmationCodes: ["deadbeef"]
                )
            } verify: { error in
                XCTAssertEqual(error as? ChekinanaNLClientError, .sensitiveInput)
            }
        }
        XCTAssertEqual(requestCount, 0)

        let localConfirmation = ChekinanaNaturalLanguageTranslator.translate("confirm deadbeef")
        XCTAssertEqual(localConfirmation.command, "confirm deadbeef")
        XCTAssertFalse(localConfirmation.needsClarification)
        XCTAssertEqual(requestCount, 0)

        XCTAssertTrue(ChekinanaNLPrivacyGuard.allowsRemoteInterpretation("请解释 token 的用途"))
        XCTAssertTrue(ChekinanaNLPrivacyGuard.allowsRemoteInterpretation("讨论 Pod 架构"))
        XCTAssertTrue(ChekinanaNLPrivacyGuard.allowsRemoteInterpretation("RunPod 的产品介绍"))
    }

    func testPodScanCredentialGuardCoversNaturalAndDirectForms() {
        let podScanInputs = [
            "使用 Pod abcdefghi 扫描这些切",
            "用 Pod abcdefghi 扫描这些切",
            "Pod ID 为 abc123xyz，用来扫描这些照片",
            "Pod ID 是 abc123xyz，扫描这些照片",
            "Pod ID：abc123xyz，用于识别这些照片",
            "Pod ID 为 abcdefghi，用来扫描这些照片",
            "Pod ID 是 abcdefgh-，扫描这些照片",
            "Pod ID：abcdefgh_，用于识别这些照片",
            "scancheki abcdefghi",
            "scancheki pod=abcdefghi",
            "scancheki expected=2",
            "scancheki;",
            "scancheki;expected=2",
            "scancheki：expected=2",
            "scancheki\nexpected=2",
            "scanchekipod=abcdefghi",
            "SCANCHEKI POD=ABCDEFGHI expected=2",
        ]

        for input in podScanInputs {
            XCTAssertTrue(ChekinanaNLPrivacyGuard.containsPodScanCredential(input), input)
            XCTAssertFalse(ChekinanaNLPrivacyGuard.allowsRemoteInterpretation(input), input)
        }
        XCTAssertFalse(ChekinanaNLPrivacyGuard.containsPodScanCredential("扫描这些切"))
        XCTAssertFalse(ChekinanaNLPrivacyGuard.containsPodScanCredential("讨论 Pod 架构"))
        XCTAssertFalse(ChekinanaNLPrivacyGuard.containsPodScanCredential("  SCANCHEKI\n"))
    }

    func testTypedScannerSchemaRejectsModelSuppliedPodSlot() async {
        ChekinanaMockURLProtocol.handler = { _ in
            (
                200,
                Data(#"{"version":1,"kind":"plan","operations":[{"intent":"scancheki","slots":{"pod":"model-supplied"}}]}"#.utf8)
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await self.makeClient().interpret(
                utterance: "扫描这些切",
                localDate: "2026-07-16",
                timezone: "Asia/Shanghai"
            )
        } verify: { error in
            XCTAssertEqual(error as? ChekinanaNLClientError, .invalidSchema)
        }
    }

    func testMalformedRequestDraftFailsBeforeURLSession() async {
        nonisolated(unsafe) var requestCount = 0
        ChekinanaMockURLProtocol.handler = { _ in
            requestCount += 1
            return (200, Data(#"{"version":1,"kind":"reject","code":"unexpected"}"#.utf8))
        }
        let draft = ChekinanaNLRequestDraft(
            operation: .init(intent: .addidol),
            missing: [.date]
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await self.makeClient().interpret(
                utterance: "补充名字",
                localDate: "2026-07-16",
                timezone: "Asia/Shanghai",
                draft: draft
            )
        } verify: { error in
            XCTAssertEqual(error as? ChekinanaNLClientError, .invalidSchema)
        }
        XCTAssertEqual(requestCount, 0)
    }

    func testCancelledGenerationRejectsControlledStalePlanAndError() async {
        for outcome in [ChekinanaDeferredOutcome.plan, .failure] {
            var gate = ChekinanaNLRequestGenerationGate()
            let generation = gate.begin()
            let deferred = ChekinanaDeferredOutcomeSource()
            let task = Task { () -> (ChekinanaDeferredOutcome, Bool) in
                let result = await deferred.wait()
                return (result, Task.isCancelled)
            }
            while !(await deferred.hasWaiter()) {
                await Task.yield()
            }

            gate.invalidate()
            task.cancel()
            await deferred.resolve(outcome)
            let (result, wasCancelled) = await task.value

            var restoredDraft = false
            var executedCommand = false
            var appendedError = false
            if gate.accepts(generation, isCancelled: wasCancelled) {
                switch result {
                case .plan:
                    restoredDraft = true
                    executedCommand = true
                case .failure:
                    appendedError = true
                }
            }
            XCTAssertFalse(restoredDraft)
            XCTAssertFalse(executedCommand)
            XCTAssertFalse(appendedError)
        }
    }

    func testClarifyDraftCanBeSentOnSecondTurn() async throws {
        nonisolated(unsafe) var requestCount = 0
        nonisolated(unsafe) var firstBody: Data?
        nonisolated(unsafe) var secondBody: Data?
        ChekinanaMockURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                firstBody = requestBodyData(request)
                return (
                    200,
                    Data(#"{"version":1,"kind":"clarify","draft":{"intent":"addcheki","slots":{"idols":["A"]}},"missing":["event_or_date"]}"#.utf8)
                )
            }
            secondBody = requestBodyData(request)
            return (
                200,
                Data(#"{"version":1,"kind":"plan","operations":[{"intent":"addcheki","slots":{"idols":["A"],"date":"2026-07-16"}}]}"#.utf8)
            )
        }
        let client = makeClient()
        let first = try await client.interpret(
            utterance: "记录 A 的切",
            localDate: "2026-07-16",
            timezone: "Asia/Shanghai"
        )
        guard case .clarify(let operation, let missing) = first else {
            return XCTFail("expected clarify")
        }

        let second = try await client.interpret(
            utterance: "就按今天",
            localDate: "2026-07-16",
            timezone: "Asia/Shanghai",
            draft: ChekinanaNLRequestDraft(operation: operation, missing: missing)
        )

        guard case .plan(let operations) = second else {
            return XCTFail("expected plan")
        }
        XCTAssertEqual(operations.first?.slots.date, "2026-07-16")
        XCTAssertEqual(requestCount, 2)
        let initialBody = try XCTUnwrap(firstBody)
        let initialObject = try XCTUnwrap(JSONSerialization.jsonObject(with: initialBody) as? [String: Any])
        XCTAssertEqual(Set(initialObject.keys), ["version", "utterance", "localDate", "timezone"])
        let body = try XCTUnwrap(secondBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let draft = try XCTUnwrap(object["draft"] as? [String: Any])
        XCTAssertEqual(Set(draft.keys), ["intent", "slots", "missing"])
        XCTAssertEqual(draft["missing"] as? [String], ["event_or_date"])
    }

    func testContinuationRejectsChangedIntentExistingSlotsAndUnrequestedSlots() async {
        let draft = ChekinanaNLRequestDraft(
            operation: .init(intent: .addcheki, slots: .init(idols: ["A"])),
            missing: [.eventOrDate]
        )
        let invalidResponses = [
            #"{"version":1,"kind":"plan","operations":[{"intent":"showidol","slots":{"target":"A"}}]}"#,
            #"{"version":1,"kind":"clarify","draft":{"intent":"addidol","slots":{}},"missing":["idol"]}"#,
            #"{"version":1,"kind":"plan","operations":[{"intent":"addcheki","slots":{"idols":["B"],"date":"2026-07-16"}}]}"#,
            #"{"version":1,"kind":"plan","operations":[{"intent":"addcheki","slots":{"idols":["A"],"date":"2026-07-16","note":"invented"}}]}"#,
        ]
        for json in invalidResponses {
            ChekinanaMockURLProtocol.handler = { _ in (200, Data(json.utf8)) }
            await XCTAssertThrowsErrorAsync {
                _ = try await self.makeClient().interpret(
                    utterance: "继续",
                    localDate: "2026-07-16",
                    timezone: "Asia/Shanghai",
                    draft: draft
                )
            } verify: { error in
                XCTAssertEqual(error as? ChekinanaNLClientError, .invalidSchema)
            }
        }
    }

    func testRejectCodeAndHTTPPairingAreFailClosed() async {
        let invalidResponses: [(Int, String)] = [
            (200, #"{"version":1,"kind":"reject","code":"unsupported"}"#),
            (200, #"{"version":1,"kind":"reject","code":"rate_limited"}"#),
            (503, #"{"version":1,"kind":"reject","code":"invalid_model_output"}"#),
            (422, #"{"version":1,"kind":"reject","code":"upstream_timeout"}"#),
        ]
        for (status, json) in invalidResponses {
            ChekinanaMockURLProtocol.handler = { _ in (status, Data(json.utf8)) }
            await XCTAssertThrowsErrorAsync {
                _ = try await self.makeClient().interpret(
                    utterance: "请求",
                    localDate: "2026-07-16",
                    timezone: "Asia/Shanghai"
                )
            } verify: { error in
                XCTAssertEqual(error as? ChekinanaNLClientError, .invalidSchema)
            }
        }
    }

    func testWorkerStringAndIdentityBoundsAreEnforcedLocally() {
        let invalidOperations: [ChekinanaNLOperation] = [
            .init(intent: .addidol, slots: .init(name: String(repeating: "a", count: 201))),
            .init(intent: .addevent, slots: .init(name: String(repeating: "e", count: 301), date: "2026-07-16")),
            .init(intent: .addevent, slots: .init(name: "https://example.com/live", date: "2026-07-16")),
            .init(intent: .addevent, slots: .init(name: "E", url: "https://example.com/" + String(repeating: "u", count: 1_000), date: "2026-07-16")),
            .init(intent: .addcheki, slots: .init(date: "2026-07-16", idols: ["Ａ", "a"])),
            .init(intent: .addcheki, slots: .init(date: "2026-07-16", idols: [String(repeating: "i", count: 201)])),
            .init(intent: .addcheki, slots: .init(date: "2026-07-16", idols: ["A"], note: String(repeating: "n", count: 501))),
            .init(intent: .listcheki, slots: .init(date: "2026-07-16", event: "E")),
        ]
        for operation in invalidOperations {
            XCTAssertThrowsError(try ChekinanaNLSchemaValidator.validatePlan([operation]), operation.intent.rawValue)
        }
    }

    func testDecodesClarifyAndReject() async throws {
        ChekinanaMockURLProtocol.handler = { _ in
            (200, Data(#"{"version":1,"kind":"clarify","draft":{"intent":"addcheki","slots":{"note":"用户输入"}},"missing":["idol","event_or_date"]}"#.utf8))
        }
        let client = makeClient()
        let clarify = try await client.interpret(
            utterance: "保存这张切",
            localDate: "2026-07-16",
            timezone: "Asia/Shanghai"
        )
        guard case .clarify(let draft, let missing) = clarify else {
            return XCTFail("expected clarify")
        }
        XCTAssertEqual(draft.intent, .addcheki)
        XCTAssertEqual(missing, [.idol, .eventOrDate])

        ChekinanaMockURLProtocol.handler = { _ in
            (200, Data(#"{"version":1,"kind":"reject","code":"unsupported_request"}"#.utf8))
        }
        let reject = try await client.interpret(
            utterance: "删除全部",
            localDate: "2026-07-16",
            timezone: "Asia/Shanghai"
        )
        guard case .reject(let code) = reject else {
            return XCTFail("expected reject")
        }
        XCTAssertEqual(code, "unsupported_request")
    }

    func testClarifyMissingSetMatchesWorkerContract() async throws {
        let invalidClarifies = [
            #"{"version":1,"kind":"clarify","draft":{"intent":"addidol","slots":{}},"missing":["date"]}"#,
            #"{"version":1,"kind":"clarify","draft":{"intent":"addidol","slots":{"name":"A"}},"missing":["idol"]}"#,
            #"{"version":1,"kind":"clarify","draft":{"intent":"addevent","slots":{}},"missing":["date"]}"#,
            #"{"version":1,"kind":"clarify","draft":{"intent":"addevent","slots":{"name":"E"}},"missing":["event_name_or_url"]}"#,
            #"{"version":1,"kind":"clarify","draft":{"intent":"addcheki","slots":{}},"missing":["idol"]}"#,
            #"{"version":1,"kind":"clarify","draft":{"intent":"addscancheki","slots":{}},"missing":["temporary_cheki","event_or_date"]}"#,
            #"{"version":1,"kind":"clarify","draft":{"intent":"listidol","slots":{}},"missing":["idol"]}"#,
            #"{"version":1,"kind":"clarify","draft":{"intent":"showevent","slots":{}},"missing":["date"]}"#,
        ]
        let client = makeClient()
        for json in invalidClarifies {
            ChekinanaMockURLProtocol.handler = { _ in (200, Data(json.utf8)) }
            await XCTAssertThrowsErrorAsync {
                _ = try await client.interpret(
                    utterance: "请求",
                    localDate: "2026-07-16",
                    timezone: "Asia/Shanghai"
                )
            } verify: { error in
                XCTAssertEqual(error as? ChekinanaNLClientError, .invalidSchema)
            }
        }

        ChekinanaMockURLProtocol.handler = { _ in
            (
                200,
                Data(#"{"version":1,"kind":"clarify","draft":{"intent":"addscancheki","slots":{}},"missing":["event_or_date","idol","temporary_cheki"]}"#.utf8)
            )
        }
        let reordered = try await client.interpret(
            utterance: "继续",
            localDate: "2026-07-16",
            timezone: "Asia/Shanghai"
        )
        guard case .clarify(_, let missing) = reordered else {
            return XCTFail("expected clarify")
        }
        XCTAssertEqual(missing, [.eventOrDate, .idol, .temporaryCheki])
    }

    func testEventNameMissingContractAcceptsURLPartialDrafts() async throws {
        let cases: [(String, [ChekinanaNLMissing])] = [
            (
                #"{"version":1,"kind":"clarify","draft":{"intent":"addevent","slots":{"url":"https://example.com/live"}},"missing":["event_name","date"]}"#,
                [.eventName, .date]
            ),
            (
                #"{"version":1,"kind":"clarify","draft":{"intent":"addevent","slots":{"url":"https://example.com/live","name":"Cheki Demo"}},"missing":["date"]}"#,
                [.date]
            ),
            (
                #"{"version":1,"kind":"clarify","draft":{"intent":"addevent","slots":{"url":"https://example.com/live","date":"2026-07-11"}},"missing":["event_name"]}"#,
                [.eventName]
            ),
        ]
        let client = makeClient()
        for (json, expectedMissing) in cases {
            ChekinanaMockURLProtocol.handler = { _ in (200, Data(json.utf8)) }
            let result = try await client.interpret(
                utterance: "添加 Event",
                localDate: "2026-07-16",
                timezone: "Asia/Shanghai"
            )
            guard case .clarify(let draft, let missing) = result else {
                return XCTFail("expected Event clarification")
            }
            XCTAssertEqual(draft.slots.url, "https://example.com/live")
            XCTAssertEqual(missing, expectedMissing)
        }
    }

    func testEventPlanRequiresNameAndDateWithOptionalURL() async throws {
        let client = makeClient()
        ChekinanaMockURLProtocol.handler = { _ in
            (
                200,
                Data(#"{"version":1,"kind":"plan","operations":[{"intent":"addevent","slots":{"url":"https://example.com/live","name":"Cheki Demo","date":"2026-07-11"}}]}"#.utf8)
            )
        }
        let valid = try await client.interpret(
            utterance: "添加完整 Event",
            localDate: "2026-07-16",
            timezone: "Asia/Shanghai"
        )
        guard case .plan(let operations) = valid else { return XCTFail("expected plan") }
        XCTAssertEqual(operations.first?.slots.name, "Cheki Demo")

        ChekinanaMockURLProtocol.handler = { _ in
            (
                200,
                Data(#"{"version":1,"kind":"plan","operations":[{"intent":"addevent","slots":{"url":"https://example.com/live"}}]}"#.utf8)
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await client.interpret(
                utterance: "添加 URL Event",
                localDate: "2026-07-16",
                timezone: "Asia/Shanghai"
            )
        } verify: { error in
            XCTAssertEqual(error as? ChekinanaNLClientError, .invalidSchema)
        }
    }

    func testHTTPTimeoutAndInvalidSchemaFailSafely() async throws {
        let client = makeClient()
        ChekinanaMockURLProtocol.handler = { _ in
            (503, Data())
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await client.interpret(
                utterance: "请求",
                localDate: "2026-07-16",
                timezone: "Asia/Shanghai"
            )
        } verify: { error in
            XCTAssertEqual(error as? ChekinanaNLClientError, .invalidHTTPStatus(503))
        }

        ChekinanaMockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await client.interpret(
                utterance: "请求",
                localDate: "2026-07-16",
                timezone: "Asia/Shanghai"
            )
        } verify: { error in
            XCTAssertEqual(error as? ChekinanaNLClientError, .timedOut)
        }

        let invalidResponses = [
            #"{"version":1,"kind":"plan","operations":[{"intent":"deletecheki","slots":{}}]}"#,
            #"{"version":1,"kind":"plan","operations":[{"intent":"addcheki","slots":{"idols":["A"],"date":"2026-07-16","user":true}}]}"#,
            #"{"version":1,"kind":"plan","operations":[{"intent":"addcheki","slots":{"idols":["A"],"date":"2026-07-16","idx":1}}]}"#,
            #"{"version":1,"kind":"plan","operations":[{"intent":"addidol","slots":{"name":"A"}},{"intent":"addevent","slots":{"name":"E","date":"2026-07-16"}}]}"#,
            #"{"version":1,"kind":"plan","operations":[{"intent":"addevent","slots":{"url":"https://example.com/live"}}]}"#,
            #"{"version":1,"kind":"plan","operations":[{"intent":"addcheki","slots":{"idols":["A"],"event":"E","date":"2026-07-16"}}]}"#,
            #"{"version":1,"kind":"plan","operations":[{"intent":"addcheki","slots":{"idols":["Ａ","a"],"date":"2026-07-16"}}]}"#,
            #"{"version":1,"kind":"plan","operations":[{"intent":"addevent","slots":{"name":"https://example.com/live","date":"2026-07-16"}}]}"#,
            #"{"version":1,"kind":"plan","operations":[{"intent":"addidol","slots":{"name":"A"}}],"extra":true}"#,
        ]
        for json in invalidResponses {
            ChekinanaMockURLProtocol.handler = { _ in (200, Data(json.utf8)) }
            await XCTAssertThrowsErrorAsync {
                _ = try await client.interpret(
                    utterance: "请求",
                    localDate: "2026-07-16",
                    timezone: "Asia/Shanghai"
                )
            } verify: { error in
                XCTAssertEqual(error as? ChekinanaNLClientError, .invalidSchema)
            }
        }
    }

    func testTransportErrorsAreClassifiedWithoutChangingProxySettings() async {
        let cases: [(URLError.Code, ChekinanaNLClientError)] = [
            (.cannotFindHost, .cannotFindHost),
            (.dnsLookupFailed, .cannotFindHost),
            (.notConnectedToInternet, .notConnectedToInternet),
            (.cannotConnectToHost, .notConnectedToInternet),
            (.timedOut, .timedOut),
            (.networkConnectionLost, .networkConnectionLost),
            (.cancelled, .cancelled),
        ]
        for (urlError, expected) in cases {
            ChekinanaMockURLProtocol.handler = { _ in throw URLError(urlError) }
            await XCTAssertThrowsErrorAsync {
                _ = try await self.makeClient().interpret(
                    utterance: "未知闲聊",
                    localDate: "2026-07-16",
                    timezone: "Asia/Shanghai"
                )
            } verify: { error in
                XCTAssertEqual(error as? ChekinanaNLClientError, expected)
            }
        }
    }

    func testNon200TypedRejectAndHTTPDeploymentStatusesRemainDistinct() async {
        let typed = [
            (503, "rate_limit_unavailable"),
            (503, "upstream_timeout"),
            (503, "upstream_unavailable"),
            (503, "service_unavailable"),
            (422, "invalid_model_output"),
            (429, "rate_limited"),
            (400, "invalid_request"),
            (405, "method_not_allowed"),
        ]
        for (status, code) in typed {
            ChekinanaMockURLProtocol.handler = { _ in
                (status, Data("{\"version\":1,\"kind\":\"reject\",\"code\":\"\(code)\"}".utf8))
            }
            await XCTAssertThrowsErrorAsync {
                _ = try await self.makeClient().interpret(
                    utterance: "未知闲聊",
                    localDate: "2026-07-16",
                    timezone: "Asia/Shanghai"
                )
            } verify: { error in
                XCTAssertEqual(error as? ChekinanaNLClientError, .serviceRejected(code: code, status: status))
            }
        }

        for status in [401, 404, 429] {
            ChekinanaMockURLProtocol.handler = { _ in (status, Data()) }
            await XCTAssertThrowsErrorAsync {
                _ = try await self.makeClient().interpret(
                    utterance: "未知闲聊",
                    localDate: "2026-07-16",
                    timezone: "Asia/Shanghai"
                )
            } verify: { error in
                XCTAssertEqual(error as? ChekinanaNLClientError, .invalidHTTPStatus(status))
            }
        }
    }

    func testAsyncDeadlineReturnsOnTimeoutAndCancellationEvenIfOperationDoesNotCooperate() async {
        let started = Date()
        await XCTAssertThrowsErrorAsync {
            _ = try await ChekinanaAsyncDeadline.run(nanoseconds: 50_000_000) {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return 1
            }
        } verify: { error in
            XCTAssertEqual(error as? ChekinanaAsyncDeadlineError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        let task = Task {
            try await ChekinanaAsyncDeadline.run(nanoseconds: 30_000_000_000) {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return 1
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? ChekinanaAsyncDeadlineError, .cancelled)
        }
    }

    func testValidHomogeneousMultiAddPlans() async throws {
        ChekinanaMockURLProtocol.handler = { _ in
            (200, Data(#"{"version":1,"kind":"plan","operations":[{"intent":"addidol","slots":{"name":"A"}},{"intent":"addidol","slots":{"name":"B"}}]}"#.utf8))
        }
        let result = try await makeClient().interpret(
            utterance: "添加 A 和 B",
            localDate: "2026-07-16",
            timezone: "Asia/Shanghai"
        )
        guard case .plan(let operations) = result else {
            return XCTFail("expected plan")
        }
        XCTAssertEqual(operations.map(\.intent), [.addidol, .addidol])
    }

    private func makeClient() -> ChekinanaNLInterpretClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChekinanaMockURLProtocol.self]
        return ChekinanaNLInterpretClient(
            endpoint: URL(string: "https://unit.test/api/nl/interpret")!,
            session: URLSession(configuration: configuration)
        )
    }
}

private final class ChekinanaMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum ChekinanaDeferredOutcome: Sendable {
    case plan
    case failure
}

private actor ChekinanaDeferredOutcomeSource {
    private var continuation: CheckedContinuation<ChekinanaDeferredOutcome, Never>?

    func wait() async -> ChekinanaDeferredOutcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasWaiter() -> Bool {
        continuation != nil
    }

    func resolve(_ outcome: ChekinanaDeferredOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { return nil }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}
