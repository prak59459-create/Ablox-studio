import Foundation

/// A name for a new world, for someone staring at an empty field: two words
/// that go together, in the app's language, never one already used.
public enum WorldNameIdeas {

    static let english = (
        first: ["Mystic", "Secret", "Sparkly", "Floating", "Lost", "Wobbly", "Sunny", "Quiet",
                "Fluffy", "Bouncy", "Frozen", "Candy", "Neon", "Hidden", "Giant", "Tiny"],
        second: ["Forest", "Island", "Castle", "Cave", "Tower", "Maze", "Park", "Station",
                 "Reef", "Clouds", "Village", "Canyon", "Garden", "Temple", "Harbour", "Desert"]
    )

    static let japanese = (
        first: ["ふしぎな", "ひみつの", "きらきら", "空とぶ", "まよいの", "ぐらぐら", "ぽかぽか", "しずかな",
                "ふわふわ", "ぴょんぴょん", "こおりの", "おかしの", "ネオンの", "かくれた", "でっかい", "ちいさな"],
        second: ["森", "島", "お城", "どうくつ", "タワー", "迷路", "公園", "ステーション",
                 "海の底", "雲の上", "村", "谷", "庭", "神殿", "港", "砂ばく"]
    )

    /// A name from `seed` (the same seed, the same name), in `language`,
    /// not among `taken`. Falls back to numbering when every pair is taken.
    public static func suggest(seed: UInt64, language: Language = Localization.language, taken: Set<String> = []) -> String {
        let words = language == .japanese ? japanese : english
        let joiner = language == .japanese ? "" : " "
        let count = words.first.count * words.second.count
        var state = seed
        for _ in 0..<32 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let pick = Int((state >> 33) % UInt64(count))
            let name = words.first[pick / words.second.count] + joiner + words.second[pick % words.second.count]
            if !taken.contains(name) { return name }
        }
        let base = words.first[Int(seed % UInt64(words.first.count))] + joiner + words.second[0]
        var number = 2
        while taken.contains(base + " " + String(number)) { number += 1 }
        return base + " " + String(number)
    }
}
