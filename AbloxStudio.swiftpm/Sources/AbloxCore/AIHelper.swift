import Foundation

// The AI helper: questions about using Ablox, answered in a few short lines.
//
// Most questions are the same twenty ("how do I make a room?"), so they are
// answered on the iPad from `HelpFAQ` first and cost nothing. Only what the
// list cannot answer goes to the model, and only when a grown-up has turned
// the helper on in Family settings and typed their own API key there (kept
// in the keychain, never in a file, a world or a message). The request is
// small on purpose: a short guide as the system prompt, the last few turns,
// a low token limit — the free tier lasts longer and answers stay short.
//
// The provider is any OpenAI-compatible chat endpoint; the default is Groq
// with Llama 3.1 8B Instant (the free tier's most generous limits), and
// another model is tried when the provider says a model is gone (404).
// Net/AIHelperClient.swift sends it; everything here is
// plain data, tested on Linux.

public enum AIHelper {
    public static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    /// Tried in order: the next one only when the provider no longer has a model.
    public static let models = ["llama-3.1-8b-instant", "llama-3.3-70b-versatile"]
    public static var model: String { models[0] }
    /// The provider's answer when the model named in the request is gone.
    public static func modelIsGone(status: Int) -> Bool { status == 404 || status == 400 }
    /// Enough for four or five short sentences.
    public static let maximumTokens = 260
    /// Turns of the conversation sent with each question (question + answer each).
    public static let historyTurns = 2
    public static let maximumQuestionLength = 300
    /// Between two questions to the model.
    public static let cooldownSeconds: Double = 4
    /// A key looks like this before it is believed: no spaces, a sensible length.
    public static func isPlausibleKey(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.count >= 20 && k.count <= 200 && !k.contains(" ") && k.allSatisfy { $0.isASCII }
    }

    // MARK: What it knows

    /// The guide the model answers from. Short: every word is sent with every question.
    public static func systemPrompt(japanese: Bool) -> String {
        if japanese {
            return """
            あなたは 子ども向けゲームアプリ「Ablox」の 案内係「アブロボ」です。小学生にも わかる やさしい日本語で、\
            3〜4文で みじかく 答えます。むずかしい漢字は ひらがなにします。
            Ablox でできること: 「あそぶ」タブで ゲームをえらぶ／ルームを作る（ホスト）／コードで入る。\
            同じWi-Fi・インターネット（おうちの人が 家族設定で オン）・Bluetooth で いっしょに あそべる。\
            「つくる」タブ（Ablox Studio）で ブロックを おいて ワールドを作り、.absc スクリプトで ルールを 書ける。\
            「ミー」タブで アバター・クローゼット・アルバム・ごほうび。コインは ゲームや ミッションで もらえる。\
            設定: 音・グラフィック・操作・ことば。家族設定（パスコード）: 時間・チャット・ルーム・コイン。\
            うまくいかないとき: アプリを 開きなおす、Wi-Fi を たしかめる、ゲームを ダウンロードしなおす。
            きまり: Ablox の使い方と ゲームの あそび方だけに 答える。名前・住所・学校・電話・写真など \
            個人のことは 聞かない・言わない。こわい話・らんぼうな話・おとなの話は しない。わからないことは \
            「おうちの人に きいてね」と言う。ほかのアプリや サイトへ さそわない。
            """
        }
        return """
        You are "Ablobo", the guide inside Ablox, a building-and-games app for children. Answer in plain words a \
        seven-year-old can follow, in three or four short sentences.
        Ablox: the Play tab lists games; host a room or join with a code. Play together on the same Wi-Fi, over the \
        internet (a grown-up turns it on in Family settings) or over Bluetooth. The Create tab is Ablox Studio: place \
        blocks to build a world and write rules in .absc scripts. The Me tab has the avatar, closet, album and rewards. \
        Coins come from games and missions. Settings: sound, graphics, controls, language. Family settings (passcode): \
        play time, chat, rooms, coins. If something breaks: reopen the app, check the Wi-Fi, download the game again.
        Rules: only help with using Ablox and playing its games. Never ask for or repeat names, addresses, schools, \
        phone numbers or photos. Nothing scary, violent or grown-up. If unsure, say "ask a grown-up". Never send \
        anyone to other apps or websites.
        """
    }

    // MARK: Asking

    public struct Turn: Codable, Hashable, Sendable {
        public var question: String
        public var answer: String
        public init(question: String, answer: String) {
            self.question = question
            self.answer = answer
        }
    }

    /// Why a question is not sent.
    public enum Refusal: Equatable, Sendable {
        case empty
        case tooLong
        /// It looks like it holds a phone number, an email or a street address.
        case personal
        case unkind

        public var message: String {
            switch self {
            case .empty: return L("Type a question first.")
            case .tooLong: return L("That question is long. Try asking it in fewer words.")
            case .personal: return L("Please don't write phone numbers, emails or addresses. Ask about the app instead!")
            case .unkind: return L("Let's keep it kind. Ask me about Ablox!")
            }
        }
    }

    /// Checks a question before anything leaves the iPad.
    public static func check(_ question: String, moderator: ChatModerator = ChatModerator()) -> Refusal? {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return .empty }
        if q.count > maximumQuestionLength { return .tooLong }
        if looksPersonal(q) { return .personal }
        if moderator.filter(q).wasFiltered { return .unkind }
        return nil
    }

    /// Phone numbers (eight or more digits), email addresses and "1-2-3"-style
    /// street numbers. Rough on purpose: a false alarm only asks the child to
    /// rephrase.
    public static func looksPersonal(_ text: String) -> Bool {
        let digits = text.filter { $0.isNumber }
        if digits.count >= 8 { return true }
        if text.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"\d+\s*[-ー−]\s*\d+\s*[-ー−]\s*\d+"#, options: .regularExpression) != nil { return true }
        for word in ["住所", "電話番号", "でんわばんごう", "じゅうしょ", "address", "phone number"] where text.lowercased().contains(word) {
            return true
        }
        return false
    }

    /// The request body: OpenAI-compatible chat completions.
    public static func requestBody(question: String, history: [Turn], japanese: Bool, model: String = model) -> Data {
        var messages: [[String: String]] = [["role": "system", "content": systemPrompt(japanese: japanese)]]
        for turn in history.suffix(historyTurns) {
            messages.append(["role": "user", "content": String(turn.question.prefix(maximumQuestionLength))])
            messages.append(["role": "assistant", "content": String(turn.answer.prefix(600))])
        }
        messages.append(["role": "user", "content": String(question.prefix(maximumQuestionLength))])
        let body: [String: Any] = ["model": model, "messages": messages, "max_tokens": maximumTokens, "temperature": 0.3]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    public enum Failure: Error, Equatable, Sendable {
        case badKey
        case busy
        case offline
        case unreadable
        case server(Int)

        public var message: String {
            switch self {
            case .badKey: return L("The AI key doesn't work. Ask a grown-up to check it in Family settings.")
            case .busy: return L("The AI is busy right now. Try again in a minute.")
            case .offline: return L("Can't reach the AI. Check the internet connection.")
            case .unreadable: return L("The AI's answer didn't make sense. Try asking again.")
            case let .server(code): return L("The AI had a problem ({}). Try again later.", code)
            }
        }
    }

    /// What came back, or why not.
    public static func reply(status: Int, data: Data, moderator: ChatModerator = ChatModerator()) -> Result<String, Failure> {
        switch status {
        case 200: break
        case 401, 403: return .failure(.badKey)
        case 429: return .failure(.busy)
        default: return .failure(.server(status))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return .failure(.unreadable) }
        let text = clean(content)
        guard !text.isEmpty else { return .failure(.unreadable) }
        return .success(moderator.filter(text).text)
    }

    /// Trims, drops Markdown the bubble cannot show, and caps the length.
    public static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for mark in ["**", "__", "```", "##", "#"] { t = t.replacingOccurrences(of: mark, with: "") }
        // Links are not followed from here: the model is told not to give them.
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 700 { t = String(t.prefix(700)) + "…" }
        return t
    }
}

// MARK: - Settings and the daily count

/// The grown-up's choices (Family settings). The key itself is not here: it
/// lives in the keychain.
public struct AIHelperSettings: Codable, Hashable, Sendable {
    public var enabled = false
    /// Questions to the model a day; the built-in answers never count.
    public var dailyLimit = 20

    public static let limits = [5, 10, 20, 50]

    public init(enabled: Bool = false, dailyLimit: Int = 20) {
        self.enabled = enabled
        self.dailyLimit = dailyLimit
    }
}

public struct AIHelperUsage: Codable, Hashable, Sendable {
    public var day = ""
    public var count = 0
    public var lastAsked: Double = 0

    public init() {}

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func left(limit: Int, on date: Date, calendar: Calendar = .current) -> Int {
        Self.dayKey(date, calendar: calendar) == day ? max(0, limit - count) : limit
    }

    public func coolingDown(at time: Double) -> Bool {
        time - lastAsked < AIHelper.cooldownSeconds
    }

    public mutating func record(on date: Date, calendar: Calendar = .current) {
        let key = Self.dayKey(date, calendar: calendar)
        if key != day {
            day = key
            count = 0
        }
        count += 1
        lastAsked = date.timeIntervalSince1970
    }
}

// MARK: - Answers on the iPad

/// The questions children ask most, answered without the network. Matching is
/// by keywords in either language; the best entry wins if it matches well.
public enum HelpFAQ {
    public struct Entry: Sendable {
        public let keywords: [String]
        public let answer: String
    }

    /// The answers are written in English and translated with the rest of the app.
    public static let entries: [Entry] = [
        Entry(keywords: ["room", "host", "ルーム", "へや", "部屋", "ホスト", "つくる部屋"],
              answer: "Open the Play tab, choose a game and tap Host. Your room gets a code — tell it to your friends so they can join."),
        Entry(keywords: ["join", "code", "入る", "はいる", "コード", "さんか", "参加"],
              answer: "Open the Play tab and tap Join. Type the room code your friend shows you, or pick a room nearby."),
        Entry(keywords: ["friend", "together", "友だち", "ともだち", "友達", "いっしょ", "一緒"],
              answer: "On the same Wi-Fi, one of you hosts and the others join. Over the internet, a grown-up turns it on in Family settings first."),
        Entry(keywords: ["internet", "online", "インターネット", "オンライン", "遠く", "とおく"],
              answer: "Internet play is off until a grown-up turns it on in Settings → Family. Then rooms can be joined from anywhere with the code."),
        Entry(keywords: ["bluetooth", "ブルートゥース"],
              answer: "Turn on Rooms over Bluetooth in Settings. Then rooms nearby show up even without Wi-Fi."),
        Entry(keywords: ["coin", "money", "コイン", "おかね", "お金"],
              answer: "You get coins by playing games, finishing missions and opening the daily reward. Spend them in the shop on looks for your avatar."),
        Entry(keywords: ["avatar", "clothes", "closet", "hat", "アバター", "服", "ふく", "クローゼット", "きがえ", "着替え", "ぼうし"],
              answer: "Open the Me tab and tap Closet. Pick colours, hats, faces and pets, then tap Done."),
        Entry(keywords: ["build", "studio", "world", "make", "つくる", "作る", "ワールド", "スタジオ", "ブロック"],
              answer: "Open the Create tab to start Ablox Studio. Place blocks, paint them, and press Play to test your world."),
        Entry(keywords: ["script", "absc", "rule", "code", "スクリプト", "プログラム", "ルール"],
              answer: "In Studio, open the Script tab. Try a sample game first, then change a number and press Test run to see what happens."),
        Entry(keywords: ["move", "control", "jump", "walk", "うごかし", "動かし", "操作", "ジャンプ", "あるく", "歩く"],
              answer: "Use the stick on the left to walk and the button on the right to jump. Drag on the screen to look around. With a keyboard: WASD and space."),
        Entry(keywords: ["camera", "first person", "カメラ", "視点", "してん", "一人称"],
              answer: "Tap the eye button in a game to switch between first and third person. Pinch to zoom the camera."),
        Entry(keywords: ["chat", "message", "talk", "チャット", "メッセージ", "話す", "はなす"],
              answer: "Tap the chat bubble in a game to send a message or a ready-made phrase. Be kind — rude words are hidden."),
        Entry(keywords: ["download", "update", "ダウンロード", "アップデート", "更新", "こうしん"],
              answer: "Games download when you open them. If one looks old or broken, open its page and download it again."),
        Entry(keywords: ["lag", "slow", "laggy", "重い", "おもい", "カクカク", "おそい"],
              answer: "Lower the graphics in Settings, close other apps, and stay close to the Wi-Fi router."),
        Entry(keywords: ["crash", "broken", "error", "bug", "バグ", "エラー", "こわれ", "とまった", "止まった", "落ちる"],
              answer: "Close Ablox and open it again. If it keeps happening, tell us in the suggestion box in Settings."),
        Entry(keywords: ["sound", "music", "volume", "音", "おと", "音楽", "おんがく"],
              answer: "Settings has the sound, effects and music volumes. In a game, the pause menu has them too."),
        Entry(keywords: ["language", "english", "japanese", "言語", "ことば", "英語", "日本語"],
              answer: "Settings → Language switches Ablox between English and Japanese."),
        Entry(keywords: ["time", "limit", "play time", "時間", "じかん", "あとどれ"],
              answer: "A grown-up can set how long you can play each day in Family settings. The app shows how many minutes are left."),
        Entry(keywords: ["suggest", "idea", "request", "目安箱", "めやすばこ", "アイデア", "リクエスト", "要望"],
              answer: "Settings has a suggestion box. Write your idea for a game or a feature — the team reads every one."),
        Entry(keywords: ["photo", "picture", "album", "写真", "しゃしん", "アルバム", "スクショ"],
              answer: "Tap the camera button in a game to take a picture. Your pictures are in the Album on the Me tab."),
        Entry(keywords: ["npc", "bot", "ボット", "なかま", "ひとり", "一人"],
              answer: "Many games bring NPC friends when few people are playing. Say /npc in chat to turn them on or off."),
        Entry(keywords: ["web", "browser", "computer", "ブラウザ", "パソコン", "ウェブ"],
              answer: "Ablox also runs in a web browser. You can join an iPad's internet room from there with the room code.")
    ]

    /// The answer for a question, and how sure the match is (0 to 1).
    public static func answer(for question: String) -> (text: String, score: Double)? {
        let q = question.lowercased()
        var best: (Entry, Int)?
        for entry in entries {
            let hits = entry.keywords.filter { q.contains($0.lowercased()) }.count
            if hits > 0, hits > (best?.1 ?? 0) { best = (entry, hits) }
        }
        guard let (entry, hits) = best else { return nil }
        return (L(entry.answer), min(1, 0.55 + Double(hits) * 0.2))
    }

    /// Buttons to tap instead of typing.
    public static let suggestions = [
        "How do I make a room?", "How do I play with friends?", "How do I get coins?",
        "How do I change my avatar?", "How do I build a world?", "The game is slow"
    ]
}
