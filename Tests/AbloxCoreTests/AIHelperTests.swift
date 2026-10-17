import XCTest
@testable import AbloxCore

/// The AI helper: what is refused before anything is sent, the request as
/// the provider reads it, answers and failures, the day's count, and the
/// help list that answers most questions without the network.
final class AIHelperTests: XCTestCase {

    func testQuestionsThatAreNotSent() {
        XCTAssertEqual(AIHelper.check("   "), .empty)
        XCTAssertEqual(AIHelper.check(String(repeating: "あ", count: AIHelper.maximumQuestionLength + 1)), .tooLong)
        XCTAssertEqual(AIHelper.check("my number is 090 1234 5678"), .personal)
        XCTAssertEqual(AIHelper.check("write to sam@example.com"), .personal)
        XCTAssertEqual(AIHelper.check("住所は 1-2-3 です"), .personal)
        XCTAssertEqual(AIHelper.check("you are stupid"), .unkind)
        XCTAssertNil(AIHelper.check("How do I make a room?"))
        XCTAssertNil(AIHelper.check("ルームの 作りかたは？"))
        // A room code or a level is not a phone number.
        XCTAssertNil(AIHelper.check("code ABC-123 and level 12"))
    }

    func testTheRequestIsSmallAndCarriesOnlyTheLastTurns() throws {
        let history = (1...5).map { AIHelper.Turn(question: "q\($0)", answer: "a\($0)") }
        let data = AIHelper.requestBody(question: "How do I join?", history: history, japanese: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, AIHelper.model)
        XCTAssertEqual(object["max_tokens"] as? Int, AIHelper.maximumTokens)
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.count, 1 + AIHelper.historyTurns * 2 + 1)
        XCTAssertEqual(messages[1]["content"], "q4")
        XCTAssertEqual(messages.last?["content"], "How do I join?")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Bearer"), "the key never goes in the body")
    }

    func testAModelThatIsGoneMovesOnToTheNext() {
        XCTAssertEqual(AIHelper.model, "qwen/qwen3.8-27b")
        let list = #"{"data":[{"id":"whisper-large-v3"},{"id":"openai/gpt-oss-20b"},{"id":"zz-chat"}]}"#
        XCTAssertEqual(AIHelper.chooseModel(fromList: Data(list.utf8)), "openai/gpt-oss-20b")
        let unknown = #"{"data":[{"id":"whisper-large-v3"},{"id":"meta-llama/llama-prompt-guard-2-22m"},{"id":"new-chat-9b"}]}"#
        XCTAssertEqual(AIHelper.chooseModel(fromList: Data(unknown.utf8)), "new-chat-9b")
        XCTAssertNil(AIHelper.chooseModel(fromList: Data("{}".utf8)))
        XCTAssertEqual(AIHelper.clean("<think>hmm</think>Tap Host."), "Tap Host.")
        XCTAssertGreaterThan(AIHelper.models.count, 1)
        XCTAssertTrue(AIHelper.modelIsGone(status: 404))
        XCTAssertFalse(AIHelper.modelIsGone(status: 401))
        XCTAssertFalse(AIHelper.modelIsGone(status: 200))
    }

    func testTheGuideIsShortInBothLanguages() {
        for japanese in [true, false] {
            let prompt = AIHelper.systemPrompt(japanese: japanese)
            XCTAssertGreaterThan(prompt.count, 200)
            XCTAssertLessThan(prompt.count, 1600, "every character is sent with every question")
        }
    }

    func testAnswersAndFailures() {
        let body = #"{"choices":[{"message":{"role":"assistant","content":"**Tap** Host. See https://example.com"}}]}"#
        XCTAssertEqual(try AIHelper.reply(status: 200, data: Data(body.utf8)).get(), "Tap Host. See")
        XCTAssertEqual(AIHelper.reply(status: 401, data: Data()), .failure(.badKey))
        XCTAssertEqual(AIHelper.reply(status: 429, data: Data()), .failure(.busy))
        XCTAssertEqual(AIHelper.reply(status: 500, data: Data()), .failure(.server(500)))
        XCTAssertEqual(AIHelper.reply(status: 200, data: Data("{}".utf8)), .failure(.unreadable))
        let rude = #"{"choices":[{"message":{"content":"you are stupid"}}]}"#
        XCTAssertEqual(try AIHelper.reply(status: 200, data: Data(rude.utf8)).get(), "you are ******")
    }

    func testKeysAreCheckedForShapeOnly() {
        XCTAssertTrue(AIHelper.isPlausibleKey("gsk_" + String(repeating: "x", count: 40)))
        XCTAssertFalse(AIHelper.isPlausibleKey("short"))
        XCTAssertFalse(AIHelper.isPlausibleKey("has a space in it but is long enough"))
    }

    func testTheDailyCountStartsAgainEachDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = Date(timeIntervalSince1970: 1_760_000_000)
        var usage = AIHelperUsage()
        XCTAssertEqual(usage.left(limit: 3, on: monday, calendar: calendar), 3)
        usage.record(on: monday, calendar: calendar)
        usage.record(on: monday, calendar: calendar)
        XCTAssertEqual(usage.left(limit: 3, on: monday, calendar: calendar), 1)
        XCTAssertTrue(usage.coolingDown(at: monday.timeIntervalSince1970 + 1))
        XCTAssertFalse(usage.coolingDown(at: monday.timeIntervalSince1970 + AIHelper.cooldownSeconds + 1))
        let tuesday = monday.addingTimeInterval(86_400)
        XCTAssertEqual(usage.left(limit: 3, on: tuesday, calendar: calendar), 3)
        usage.record(on: tuesday, calendar: calendar)
        XCTAssertEqual(usage.count, 1)
    }

    func testTheHelpListAnswersCommonQuestionsInBothLanguages() {
        XCTAssertNotNil(HelpFAQ.answer(for: "How do I make a room?"))
        XCTAssertNotNil(HelpFAQ.answer(for: "コインの あつめかたは？"))
        XCTAssertNotNil(HelpFAQ.answer(for: "アバターの 服を かえたい"))
        XCTAssertNil(HelpFAQ.answer(for: "zzzz"))
        // Every suggestion button gets an answer from the list.
        for s in HelpFAQ.suggestions {
            XCTAssertNotNil(HelpFAQ.answer(for: s), s)
        }
        let previous = Localization.language
        Localization.language = .japanese
        defer { Localization.language = previous }
        for s in HelpFAQ.suggestions {
            XCTAssertNotNil(HelpFAQ.answer(for: L(s)), "the Japanese button \(L(s))")
        }
        for entry in HelpFAQ.entries {
            XCTAssertNotEqual(L(entry.answer), entry.answer, "translated: \(entry.answer)")
        }
    }
}
