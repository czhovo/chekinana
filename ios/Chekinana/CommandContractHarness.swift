import Foundation
import SwiftData

@main
enum CommandContractHarness {
    @MainActor
    static func main() throws {
        try testDirectCommandRegistry()
        testLLMFirstPromptRouting()
        try testParserURLTarget()
        try testEventURLDraftContract()
        try testExtractedEventCandidateContract()
        try testIndexGrouping()
        try testSwiftDataAssociations()
        print("command contract harness: all checks passed")
    }

    private static func testLLMFirstPromptRouting() {
        for input in ["确认上一步", "confirm deadbeef", "取消全部操作", "清空聊天记录"] {
            precondition(ChekinanaPromptRouting.localStateCommand(from: input) != nil, input)
        }
        for input in [
            "你好",
            "列出所有偶像",
            "添加活动 Summer Live 2026-08-01",
            "查看这张切",
            "扫描这些切",
            "https://weibo.com/123456/AbC123",
            "创建 Event https://weibo.com/123456/AbC123",
            "listidol",
        ] {
            precondition(ChekinanaPromptRouting.localStateCommand(from: input) == nil, input)
        }

        precondition(
            ChekinanaQuickActions.all.map(\.label)
                == ["添加 Idol", "微博建 Event", "扫描照片", "查看 Cheki"]
        )
        precondition(
            ChekinanaQuickActions.all.map {
                $0.suggestedPrompt(hasSelectedPhotos: false)
            } == [
                "添加 Idol ",
                "根据这条公开微博创建 Event：",
                "请先选择照片，再扫描这些照片",
                "查看所有 Cheki",
            ]
        )
        for action in ChekinanaQuickActions.all {
            precondition(ChekinanaQuickActions.shouldApply(to: " \n"))
            precondition(!ChekinanaQuickActions.shouldApply(to: "existing"))
            precondition(
                ChekinanaQuickActions.prefilledPrompt(
                    currentPrompt: "",
                    action: action,
                    hasSelectedPhotos: false
                ).isEmpty == false
            )
            precondition(
                ChekinanaQuickActions.prefilledPrompt(
                    currentPrompt: "existing",
                    action: action,
                    hasSelectedPhotos: false
                ) == "existing"
            )
        }
        precondition(ChekinanaTranscriptEmptyStatePolicy.shouldShow(
            messageCount: 0,
            hasDraft: false,
            hasEventCandidatePanel: false
        ))
        precondition(!ChekinanaTranscriptEmptyStatePolicy.shouldShow(
            messageCount: 1,
            hasDraft: false,
            hasEventCandidatePanel: false
        ))
    }

    private static func testDirectCommandRegistry() throws {
        try expectRejected("addevent https://example.com/e?a=1&b=2")
        try expectCommand("addevent https://example.com/e?a=1&b=2 name=Demo date=2026-07-16", intent: "addevent")
        try expectCommand("addevent \"Event Name\" date=2026-07-16", intent: "addevent")
        try expectCommand("listevent", intent: "listevent")
        try expectCommand("showevent abcdef12", intent: "showevent")
        try expectCommand("editevent abcdef12 date=-", intent: "editevent")
        try expectCommand("deleteevent abcdef12", intent: "deleteevent")
        try expectCommand("addcheki idol-a event=abcdef12", intent: "addcheki")
        try expectCommand("addcheki idol-a date=2026-07-16", intent: "addcheki")
        try expectRejected("addcheki idol-a")
        try expectRejected("addcheki date=2026-07-16")
        try expectRejected("addcheki idol-a event=abcdef12 date=2026-07-16")
        try expectRejected("addcheki idol-a date=2026-07-16 idx=1")
        try expectCommand("addscancheki aaaaaaaa idol=idol-a date=2026-07-16 user=true size=wide note=x", intent: "addscancheki")
        try expectCommand("showcheki abcdef12", intent: "showcheki")
        try expectCommand("editcheki abcdef12 idols=idol-b,idol-a event=eeeeeeee note=x", intent: "editcheki")
    }

    private static func testParserURLTarget() throws {
        let parsed = try ChekinanaCommandParser.parse("addevent https://example.com/e?a=1&b=2 name=Demo date=2026-07-16")
        precondition(parsed.target == "https://example.com/e?a=1&b=2")
        precondition(parsed.arguments == ["name": "Demo", "date": "2026-07-16"])
    }

    private static func testEventURLDraftContract() throws {
        let url = "https://example.com/live"
        let partial = ChekinanaLocalEventLanguage.draft(from: "添加 Event \(url)")
        precondition(partial?.operation.slots.url == url)
        precondition(partial?.missing == [.eventName, .date])

        let complete = ChekinanaLocalEventLanguage.draft(
            from: "添加 Event \(url) 名称 Cheki Demo 日期 2026-07-11"
        )
        precondition(complete?.missing.isEmpty == true)
        try ChekinanaNLSchemaValidator.validatePlan([complete!.operation])
        let completeTranslation = ChekinanaNaturalLanguageTranslator.translate(
            "添加 Event \(url) 名称 Cheki Demo 日期 2026-07-11"
        )
        precondition(
            completeTranslation.command
                == "addevent https://example.com/live name=\"Cheki Demo\" date=2026-07-11"
        )
        let partialTranslation = ChekinanaNaturalLanguageTranslator.translate(
            "添加 Event \(url)"
        )
        precondition(partialTranslation.command == nil)
        precondition(partialTranslation.requiresLocalClarification)

        do {
            try ChekinanaNLSchemaValidator.validatePlan([
                .init(intent: .addevent, slots: .init(url: url))
            ])
            preconditionFailure("URL-only Event plan must be rejected")
        } catch ChekinanaNLClientError.invalidSchema {
            // Expected.
        }
    }

    private static func testExtractedEventCandidateContract() throws {
        let url = "https://weibo.com/123456/AbC123"
        precondition(ChekinanaEventWeiboInput.extractedURL(from: url) == url)
        precondition(ChekinanaEventWeiboInput.extractedURL(from: "创建 Event \(url)") == url)
        precondition(ChekinanaEventWeiboInput.extractedURL(from: "添加活动 \(url)。") == url)
        precondition(ChekinanaEventWeiboInput.extractedURL(from: "addevent \(url)") == url)
        precondition(ChekinanaEventCandidateValidator.isPublicWeiboStatusURL(url))
        precondition(ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://www.weibo.com/user_name/Z9"))
        precondition(ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/%E5%81%B6%E5%83%8F/%41bC"))
        precondition(ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/\(String(repeating: "u", count: 200))/AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("http://weibo.com/123/AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://evil.example/123/AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/123/AbC?source=app"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/123/AbC/"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/123/extra/AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/123/AbC-1"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/foo%2Fbar/AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/foo%ZZ/AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/foo%FF/AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/foo%00bar/AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/./AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/../AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/%2e%2e/AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/foo\\bar/AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/foo%5Cbar/AbC"))
        precondition(!ChekinanaEventCandidateValidator.isPublicWeiboStatusURL("https://weibo.com/\(String(repeating: "u", count: 201))/AbC"))
        precondition(ChekinanaEventCandidateValidator.isTrustedTicketURL("https://tickets.showstart.com/e/1"))
        precondition(!ChekinanaEventCandidateValidator.isTrustedTicketURL("https://evil.example/e/1"))

        let fields = ChekinanaEventCandidateFields(
            name: "Contract Live",
            date: "",
            city: "上海",
            livehouse: "新歌空间中大二号馆",
            weiboURL: url,
            ticketURL: "",
            note: ""
        )
        precondition(ChekinanaEventCandidateValidator.blockers(for: fields).isEmpty)
        var address = fields
        address.livehouse = "北京市朝阳区幸福路一百号"
        precondition(ChekinanaEventCandidateValidator.blockers(for: address).contains(.livehouseLooksLikeAddress))
        address.livehouse = "北京市朝阳区幸福路东段"
        precondition(ChekinanaEventCandidateValidator.blockers(for: address).contains(.livehouseLooksLikeAddress))
        address.livehouse = "北京市朝阳区幸福路"
        precondition(ChekinanaEventCandidateValidator.blockers(for: address).contains(.livehouseLooksLikeAddress))
        address.livehouse = "朝阳区幸福街"
        precondition(ChekinanaEventCandidateValidator.blockers(for: address).contains(.livehouseLooksLikeAddress))
        address.livehouse = "Fixture Livehouse 中大二号馆"
        precondition(!ChekinanaEventCandidateValidator.blockers(for: address).contains(.livehouseLooksLikeAddress))

        let envelope = Data(#"{"version":1,"kind":"candidate","candidate":{"name":"Contract Live","date":"","city":"上海","livehouse":"新歌空间中大二号馆","weiboURL":"https://weibo.com/123456/AbC123","ticketURL":"","note":""}}"#.utf8)
        let decoded = try ChekinanaEventCandidateClient.decodeSuccess(envelope)
        precondition(decoded == fields)

        var state = ChekinanaEventCandidateStateMachine()
        let stale = state.begin(url: url)
        state.invalidate()
        precondition(!state.complete(fields, generation: stale))
        let current = state.begin(url: url)
        precondition(state.complete(fields, generation: current))
        precondition(state.phase == .editing(fields))
        precondition(!state.accepts(current, isCancelled: false))

        var busyOwner = ChekinanaEventCandidateBusyOwner()
        precondition(busyOwner.acquire(generation: current))
        precondition(!busyOwner.acquire(generation: current &+ 1))
        precondition(!busyOwner.release(generation: current &+ 1))
        precondition(busyOwner.release(generation: current))
        precondition(busyOwner.generation == nil)
    }

    private static func testIndexGrouping() throws {
        let idolA = UUID()
        let idolB = UUID()
        let event = UUID()
        let groupAB = ChekinanaChekiGroupKey(idolIDs: [idolA, idolB], eventID: event, eventDate: nil)!
        let groupBA = ChekinanaChekiGroupKey(idolIDs: [idolB, idolA], eventID: event, eventDate: nil)!
        precondition(groupAB == groupBA)

        var snapshots: [ChekinanaChekiIndexSnapshot] = []
        let firstID = UUID()
        let first = try ChekinanaChekiIndexing.nextIndex(for: groupAB, existing: snapshots, excludingChekiID: nil)
        precondition(first == 1)
        snapshots.append(.init(chekiID: firstID, group: groupAB, idx: first))
        let second = try ChekinanaChekiIndexing.nextIndex(for: groupBA, existing: snapshots, excludingChekiID: nil)
        precondition(second == 2)
        snapshots.append(.init(chekiID: UUID(), group: groupBA, idx: second))
        let third = try ChekinanaChekiIndexing.nextIndex(for: groupAB, existing: snapshots, excludingChekiID: nil)
        let afterExcludingFirst = try ChekinanaChekiIndexing.nextIndex(for: groupAB, existing: snapshots, excludingChekiID: firstID)
        precondition(third == 3)
        precondition(afterExcludingFirst == 3)

        let formatter = ISO8601DateFormatter()
        let dateMorning = formatter.date(from: "2026-07-16T01:00:00Z")!
        let dateEvening = formatter.date(from: "2026-07-16T23:00:00Z")!
        let dateGroupMorning = ChekinanaChekiGroupKey(idolIDs: [idolA], eventID: nil, eventDate: dateMorning)!
        let dateGroupEvening = ChekinanaChekiGroupKey(idolIDs: [idolA], eventID: nil, eventDate: dateEvening)!
        precondition(dateGroupMorning == dateGroupEvening)
        let movedGroupSnapshots = [ChekinanaChekiIndexSnapshot(chekiID: UUID(), group: dateGroupMorning, idx: 4)]
        let movedIndex = try ChekinanaChekiIndexing.nextIndex(
            for: dateGroupEvening,
            existing: movedGroupSnapshots,
            excludingChekiID: firstID
        )
        precondition(movedIndex == 5)
    }

    @MainActor
    private static func testSwiftDataAssociations() throws {
        let schema = Schema([Idol.self, Event.self, Cheki.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let idolA = Idol(name: "A")
        let idolB = Idol(name: "B")
        let event = Event(name: "E")
        context.insert(idolA)
        context.insert(idolB)
        context.insert(event)

        let eventCheki = Cheki(idx: 1)
        context.insert(eventCheki)
        eventCheki.idols = [idolA, idolB]
        eventCheki.event = event

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let fallbackCheki = Cheki(eventDate: formatter.date(from: "2026-07-16"), idx: 1)
        context.insert(fallbackCheki)
        fallbackCheki.idols = [idolA]
        try context.save()

        let saved = try context.fetch(FetchDescriptor<Cheki>())
        precondition(saved.count == 2)
        precondition(saved.contains { $0.event?.id == event.id && Set($0.idols.map(\.id)) == Set([idolA.id, idolB.id]) })
        precondition(saved.contains { $0.event == nil && $0.eventDate != nil })
        precondition(event.chekis.count == 1)
    }

    private static func expectCommand(_ input: String, intent: String) throws {
        let result = ChekinanaNaturalLanguageTranslator.translate(input)
        precondition(result.command != nil && !result.needsClarification && result.intent == intent, input)
    }

    private static func expectRejected(_ input: String) throws {
        let result = ChekinanaNaturalLanguageTranslator.translate(input)
        precondition(result.command == nil && result.needsClarification, input)
    }
}
