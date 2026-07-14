import Foundation

/// Append-only, on-device log of *explicit* pairwise judgments from the Face
/// Off tab: the user is shown two reminders and picks the more important one.
/// This is the cleanest training signal the app collects — a direct
/// preference label (`winner` should rank above `loser`) with no ranked-order
/// noise to untangle, unlike `PreferenceLog`'s implicit actions. Shares the
/// `TrainingLog` file machinery; never leaves the device unless exported.
enum FaceOffLog {
    struct Event: Encodable, Sendable {
        let ts: String
        let winner: TrainingLog.LoggedReminder
        let loser: TrainingLog.LoggedReminder
    }

    static var fileURL: URL {
        TrainingLog.directory.appendingPathComponent("faceoffs.jsonl")
    }

    /// Records one comparison. Snapshotting is synchronous (value types);
    /// encoding and file I/O run off the caller's actor.
    static func record(winner: ReminderItem, loser: ReminderItem) {
        let now = Date()
        let event = Event(
            ts: ISO8601DateFormatter().string(from: now),
            winner: TrainingLog.LoggedReminder(winner, now: now),
            loser: TrainingLog.LoggedReminder(loser, now: now)
        )
        Task.detached(priority: .utility) {
            guard let line = try? JSONEncoder().encode(event) else { return }
            TrainingLog.append(line, to: fileURL)
        }
    }

    // MARK: Reading (personalization + pair dedupe)

    /// One recorded judgment, decoded minimally — just what prompt
    /// personalization and pair-dedupe need.
    struct Judgment: Sendable {
        let winnerID: String
        let winnerTitle: String
        let loserID: String
        let loserTitle: String
    }

    private struct DecodedReminder: Decodable {
        let id: String
        let title: String
    }

    private struct DecodedEvent: Decodable {
        let winner: DecodedReminder
        let loser: DecodedReminder
    }

    /// Order-independent key identifying a pair regardless of who won or
    /// which side each was shown on.
    static func pairKey(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "|")
    }

    /// Every judgment in the log (rotated history included), oldest first.
    /// Lines that fail to decode are skipped. Synchronous file I/O — fine at
    /// the log's bounded size (`TrainingLog.maxFileBytes`), but call it once
    /// per need, not per row.
    static func allJudgments() -> [Judgment] {
        let decoder = JSONDecoder()
        return exportData().split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let event = try? decoder.decode(DecodedEvent.self, from: Data(line)) else { return nil }
            return Judgment(
                winnerID: event.winner.id,
                winnerTitle: event.winner.title,
                loserID: event.loser.id,
                loserTitle: event.loser.title
            )
        }
    }

    /// The most recent `limit` judgments, newest first — the freshest signal
    /// for prompt personalization.
    static func recentJudgments(limit: Int) -> [Judgment] {
        Array(allJudgments().suffix(limit).reversed())
    }

    /// Keys of every pair ever compared, so the Face Off tab never asks the
    /// same question twice.
    static func comparedPairKeys() -> Set<String> {
        Set(allJudgments().map { pairKey($0.winnerID, $0.loserID) })
    }

    // MARK: Import

    /// Appends an exported log (e.g. from the iPhone app) into this device's
    /// log, line by line, skipping anything that doesn't decode as a face-off
    /// event. Returns how many judgments were imported. Duplicated history is
    /// possible if the same export is imported twice; harmless for training
    /// (a repeated true label) and excluded from pair selection either way.
    @discardableResult
    static func importData(_ data: Data) -> Int {
        let decoder = JSONDecoder()
        var imported = 0
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let lineData = Data(line)
            guard (try? decoder.decode(DecodedEvent.self, from: lineData)) != nil else { continue }
            TrainingLog.append(lineData, to: fileURL)
            imported += 1
        }
        return imported
    }

    // MARK: Export

    static var hasLoggedData: Bool { TrainingLog.hasData(fileURL) }
    static func exportData() -> Data { TrainingLog.exportData(fileURL) }
}
