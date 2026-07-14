import Foundation

/// Decoders for the two on-device training logs the app exports, plus the flat
/// feature snapshot both share. The field names mirror `TrainingLog.LoggedReminder`
/// / `PreferenceLog.LoggedItem` in the app exactly, so an exported `.jsonl`
/// decodes here without transformation.
public struct LoggedReminder: Decodable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let notes: String?
    public let list: String
    public let dueInDays: Int?
    public let createdDaysAgo: Int?
    public let priority: Int
    public let score: Int?
}

/// One line of `faceoffs.jsonl`: an explicit "winner should rank above loser".
public struct FaceOffEvent: Decodable, Sendable {
    public let ts: String
    public let winner: LoggedReminder
    public let loser: LoggedReminder
}

/// One line of `preferences.jsonl`: an implicit action plus the ranked context
/// the user saw. `context` positions are top-first, matching what the app logs.
public struct PreferenceEvent: Decodable, Sendable {
    public struct Item: Decodable, Sendable, Hashable {
        public let position: Int
        public let id: String
        public let title: String
        public let notes: String?
        public let list: String
        public let dueInDays: Int?
        public let createdDaysAgo: Int?
        public let priority: Int
        public let score: Int?

        var reminder: LoggedReminder {
            LoggedReminder(
                id: id, title: title, notes: notes, list: list,
                dueInDays: dueInDays, createdDaysAgo: createdDaysAgo,
                priority: priority, score: score
            )
        }
    }

    public let ts: String
    public let action: String
    public let snoozeDays: Int?
    public let item: Item
    public let context: [Item]
}

/// JSON Lines parsing: one JSON object per non-empty line, tolerant of blank
/// lines and (best-effort) skipping any single line that fails to decode rather
/// than aborting the whole file — an exported log can contain a truncated final
/// line after rotation.
public enum JSONL {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var result: [T] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            if let value = try? decoder.decode(T.self, from: lineData) {
                result.append(value)
            }
        }
        return result
    }

    public static func decode<T: Decodable>(_ type: T.Type, fromFile url: URL) throws -> [T] {
        try decode(type, from: Data(contentsOf: url))
    }
}
