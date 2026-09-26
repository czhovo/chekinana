import AVFoundation
import Foundation
import XCTest
@testable import Chekinana

@MainActor
final class ChekinanaMatchGameLocalizationTests: XCTestCase {
    func testAllRuntimeCopyHasAllFourLanguageValues() throws {
        let expected: [ChekinanaAppLanguage: (
            stats: [String],
            statuses: [String],
            audioErrors: [String],
            accessibility: [String],
            title: String,
            close: String
        )] = [
            .english: (
                ["Time", "Remaining"],
                [
                    "The images do not match.",
                    "No valid path connects these images.",
                    "Solving…",
                    "No solution is available for the current board.",
                    "The answer has ended.",
                    "Paused",
                    "Complete!",
                ],
                ["Local audio is unavailable.", "Local audio could not be played."],
                ["Blank", "Pattern 7", "Play", "Pause"],
                "Link Link",
                "Close Link Link"
            ),
            .japanese: (
                ["時間", "残り"],
                [
                    "画像が一致しません",
                    "有効な経路ではありません",
                    "解答中…",
                    "現在のボードには解がありません",
                    "解答が終了しました",
                    "一時停止しました",
                    "完成！",
                ],
                ["ローカル音声を利用できません。", "ローカル音声を再生できません。"],
                ["空白", "パターン7", "再生", "一時停止"],
                "リンクリンク",
                "リンクリンクを閉じる"
            ),
            .traditionalChinese: (
                ["時間", "剩餘"],
                ["圖片不同。", "沒有有效路徑可連接這兩張圖片。", "正在求解…", "目前的棋盤無解。", "解答已結束。", "已暫停", "完成！"],
                ["無法使用本機音訊。", "無法播放本機音訊。"],
                ["空白", "圖案 7", "播放", "暫停"],
                "連連看",
                "關閉連連看"
            ),
            .simplifiedChinese: (
                ["时间", "剩余"],
                ["图片不同", "路径不合法", "正在求解…", "当前棋盘无解", "解答已结束", "已暂停", "完成！"],
                ["本地音频不可用", "本地音频无法播放"],
                ["空白", "图案7", "播放", "暂停"],
                "连连看",
                "关闭连连看"
            ),
        ]

        for (language, expected) in expected {
            let bundle = try localizedBundle(for: language)
            let locale = Locale(identifier: language.rawValue)
            XCTAssertEqual([
                ChekinanaL10n.text("match_game.stat.time", fallback: "Time", bundle: bundle),
                ChekinanaL10n.text("match_game.stat.remaining", fallback: "Remaining", bundle: bundle),
            ], expected.stats, language.rawValue)
            XCTAssertEqual(
                ChekinanaMatchGameStatus.allCases.map { $0.text(bundle: bundle) },
                expected.statuses,
                language.rawValue
            )
            XCTAssertEqual(
                ChekinanaMatchGameAudioError.allCases.map { $0.text(bundle: bundle) },
                expected.audioErrors,
                language.rawValue
            )
            XCTAssertEqual([
                ChekinanaL10n.text("空白", fallback: "Blank", bundle: bundle),
                ChekinanaL10n.format(
                    "图案 %lld",
                    fallback: "Pattern %lld",
                    bundle: bundle,
                    locale: locale,
                    Int64(7)
                ),
                ChekinanaL10n.text("播放", fallback: "Play", bundle: bundle),
                ChekinanaL10n.text("暂停", fallback: "Pause", bundle: bundle),
            ], expected.accessibility, language.rawValue)
            XCTAssertEqual(
                ChekinanaProductCopy.text("sidebar.match", "Link Link", bundle: bundle),
                expected.title,
                language.rawValue
            )
            XCTAssertEqual(
                ChekinanaL10n.text("关闭连连看", fallback: "Close Link Link", bundle: bundle),
                expected.close,
                language.rawValue
            )
        }
    }

    func testRenderTimeLanguageChangeDoesNotMutateGameOrAudioState() throws {
        let audioPlayer = ChekinanaMatchGameAudioPlayer(
            victoryAudioURL: { nil },
            makeAudioPlayer: { _ in
                throw MatchGameMockAudioError.unexpectedFactoryCall
            },
            activateAudioSession: {
                XCTFail("An unavailable audio resource must not activate the audio session")
            }
        )
        let model = ChekinanaMatchGameViewModel(
            initialBoardIndex: 0,
            audioPlayer: audioPlayer
        )

        model.tap(MatchGamePosition(row: 0, column: 0))
        model.tap(MatchGamePosition(row: 0, column: 1))
        audioPlayer.playFromBeginning()
        XCTAssertEqual(model.status, .imagesDiffer)
        XCTAssertEqual(audioPlayer.error, .unavailable)

        let modelIdentity = ObjectIdentifier(model)
        let audioIdentity = ObjectIdentifier(audioPlayer)
        let engine = model.engine
        let remainingPairs = model.engine.remainingPairs
        let selected = model.selected
        let visiblePath = model.visiblePath
        let elapsedSeconds = model.elapsedSeconds
        let status = model.status
        let isAutoSolving = model.isAutoSolving
        let isSolving = model.isSolving
        let assetIDs = (0...14).map(model.assetID(for:))
        let isPlaying = audioPlayer.isPlaying
        let currentTime = audioPlayer.currentTime
        let duration = audioPlayer.duration
        let audioError = audioPlayer.error

        let englishBundle = try localizedBundle(for: .english)
        let japaneseBundle = try localizedBundle(for: .japanese)
        XCTAssertEqual(model.status?.text(bundle: englishBundle), "The images do not match.")
        XCTAssertEqual(model.status?.text(bundle: japaneseBundle), "画像が一致しません")
        XCTAssertEqual(audioPlayer.error?.text(bundle: englishBundle), "Local audio is unavailable.")
        XCTAssertEqual(audioPlayer.error?.text(bundle: japaneseBundle), "ローカル音声を利用できません。")

        XCTAssertEqual(ObjectIdentifier(model), modelIdentity)
        XCTAssertEqual(ObjectIdentifier(audioPlayer), audioIdentity)
        XCTAssertEqual(model.engine, engine)
        XCTAssertEqual(model.engine.remainingPairs, remainingPairs)
        XCTAssertEqual(model.selected, selected)
        XCTAssertEqual(model.visiblePath, visiblePath)
        XCTAssertEqual(model.elapsedSeconds, elapsedSeconds)
        XCTAssertEqual(model.status, status)
        XCTAssertEqual(model.isAutoSolving, isAutoSolving)
        XCTAssertEqual(model.isSolving, isSolving)
        XCTAssertEqual((0...14).map(model.assetID(for:)), assetIDs)
        XCTAssertEqual(audioPlayer.isPlaying, isPlaying)
        XCTAssertEqual(audioPlayer.currentTime, currentTime)
        XCTAssertEqual(audioPlayer.duration, duration)
        XCTAssertEqual(audioPlayer.error, audioError)
    }

    func testMockedAudioFailuresUseStableErrorStatesWithoutPlayingAudio() {
        let unavailable = ChekinanaMatchGameAudioPlayer(
            victoryAudioURL: { nil },
            makeAudioPlayer: { _ in throw MatchGameMockAudioError.unexpectedFactoryCall },
            activateAudioSession: {}
        )
        unavailable.playFromBeginning()
        XCTAssertEqual(unavailable.error, .unavailable)
        XCTAssertFalse(unavailable.isPlaying)

        let cannotPlay = ChekinanaMatchGameAudioPlayer(
            victoryAudioURL: { URL(fileURLWithPath: "/mock/muguang.m4a") },
            makeAudioPlayer: { _ in throw MatchGameMockAudioError.cannotPlay },
            activateAudioSession: {}
        )
        cannotPlay.playFromBeginning()
        XCTAssertEqual(cannotPlay.error, .cannotPlay)
        XCTAssertFalse(cannotPlay.isPlaying)
    }

    func testFourLanguageBundlesIncludeEveryCatalogValueAndPermissionPrompt() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Chekinana/Localizable.xcstrings")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sourceURL)) as? [String: Any])
        let strings = try XCTUnwrap(object["strings"] as? [String: [String: Any]])
        for language in ChekinanaAppLanguage.allCases where language != .system {
            let bundle = try localizedBundle(for: language)
            for (key, entry) in strings {
                if entry["shouldTranslate"] as? Bool == false { continue }
                let localizations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]], key)
                let localization = try XCTUnwrap(localizations[language.rawValue], "Missing \(language.rawValue): \(key)")
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: String], key)
                let expected = try XCTUnwrap(unit["value"], key)
                XCTAssertFalse(expected.isEmpty, key)
                XCTAssertEqual(bundle.localizedString(forKey: key, value: "__missing__", table: nil), expected, "\(language.rawValue): \(key)")
            }
            for key in ["NSCameraUsageDescription", "NSPhotoLibraryAddUsageDescription"] {
                let prompt = bundle.localizedString(forKey: key, value: "__missing__", table: "InfoPlist")
                XCTAssertFalse(prompt.isEmpty)
                XCTAssertNotEqual(prompt, "__missing__", "\(language.rawValue): \(key)")
            }
        }
    }

    func testTypedRuntimeInterpolationUsesRequestedLanguageWithoutChangingUserValues() throws {
        let userName = "Alice 中文 100%"
        for language in ChekinanaAppLanguage.allCases where language != .system {
            let bundle = try localizedBundle(for: language)
            let locale = Locale(identifier: language.rawValue)
            let result = ChekinanaL10n.message("Reorder \(userName)", bundle: bundle, locale: locale)
            let expected = String(format: bundle.localizedString(forKey: "Reorder %@", value: "__missing__", table: nil), locale: locale, userName)
            XCTAssertEqual(result, expected, language.rawValue)
            XCTAssertTrue(result.contains(userName), language.rawValue)
            let pattern = ChekinanaL10n.message("Remove pattern \(3)", bundle: bundle, locale: locale)
            XCTAssertTrue(pattern.contains("3"), language.rawValue)
            XCTAssertFalse(pattern.contains("%lld"), language.rawValue)
        }
    }

    func testLocalizedFailuresStillStopCommandPlansInAllFourLanguages() throws {
        let previous = ChekinanaLanguageStore.shared.language
        defer { ChekinanaLanguageStore.shared.language = previous }
        for language in ChekinanaAppLanguage.allCases where language != .system {
            ChekinanaLanguageStore.shared.language = language
            let error = ChekinanaCommandCopy.errorDetail(ChekinanaL10n.format(
                "assistant.photo.load_failed",
                fallback: "The selected photos could not be loaded. Keep them selected and try again. %@",
                "sample"
            ))
            XCTAssertTrue(error.hasPrefix("error: "))
            XCTAssertTrue(ChekinanaConversationCoordinator.responseStopsPlan(.text(error)))
            XCTAssertTrue(ChekinanaConfirmationResponseValidator.isDeleteChekiSuccess(
                .text(ChekinanaConfirmationResponseValidator.chekiDeletionSuccessText)
            ))
            XCTAssertFalse(ChekinanaConfirmationResponseValidator.isDeleteChekiSuccess(.text("unrelated response")))
            XCTAssertEqual(ChekinanaNaturalLanguageTranslator.translate("help").command, "help")
            XCTAssertTrue(ChekinanaCommandCopy.displayText(error).contains("sample"))
            XCTAssertFalse(ChekinanaCommandCopy.displayText(error).contains("error: error:"))
            XCTAssertEqual(ChekinanaCommandCopy.displayText("A user-entered value"), "A user-entered value")
        }
    }

    func testKnownRuntimeDiagnosticsUseAppLanguageAndUnknownTextIsPreserved() throws {
        let previous = ChekinanaLanguageStore.shared.language
        defer { ChekinanaLanguageStore.shared.language = previous }
        for language in ChekinanaAppLanguage.allCases where language != .system {
            ChekinanaLanguageStore.shared.language = language
            let bundle = try localizedBundle(for: language)
            let expected = bundle.localizedString(
                forKey: "The RunPod status request timed out. Try again later.",
                value: "__missing__", table: nil
            )
            XCTAssertEqual(ChekinanaScannerRuntimeCopy.message(
                errorCode: "runpod_status_timeout", message: nil
            ), expected)
            XCTAssertEqual(ChekinanaScannerRuntimeCopy.message(
                message: "RunPod 状态查询超时，请稍后重试。"
            ), expected)
            XCTAssertEqual(ChekinanaScannerRuntimeCopy.message(
                errorCode: "future_external_code", message: "External diagnostic text"
            ), "External diagnostic text")
        }
    }

    private func localizedBundle(for language: ChekinanaAppLanguage) throws -> Bundle {
        let candidates = [Bundle.main, Bundle(for: Self.self)]
            + Bundle.allBundles
            + Bundle.allFrameworks
        for candidate in candidates {
            guard let path = candidate.path(
                forResource: language.rawValue,
                ofType: "lproj"
            ), let bundle = Bundle(path: path) else { continue }
            return bundle
        }
        throw MatchGameLocalizationTestError.missingBundle(language.rawValue)
    }
}

private enum MatchGameMockAudioError: Error {
    case unexpectedFactoryCall
    case cannotPlay
}

private enum MatchGameLocalizationTestError: Error {
    case missingBundle(String)
}
