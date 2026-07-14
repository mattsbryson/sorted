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
        let ts: String
        let winner: DecodedReminder
        let loser: DecodedReminder
    }

    /// Identity of one logged event across devices and exports: the same
    /// pick of the same pair at the same second. Distinct re-judgments of a
    /// pair (different timestamps) are distinct events and are kept.
    private static func eventKey(_ event: DecodedEvent) -> String {
        [event.ts, event.winner.id, event.loser.id].joined(separator: "|")
    }

    /// Splits a log blob into JSON lines and returns those whose event key
    /// isn't already in `seenKeys`, adding kept keys as it goes — so calling
    /// this over successive blobs yields their de-duplicated union in order.
    /// Undecodable lines are dropped (they're unusable as training data).
    static func dedupedLines(_ blob: Data, seenKeys: inout Set<String>) -> [Data] {
        let decoder = JSONDecoder()
        return blob.split(separator: UInt8(ascii: "\n")).compactMap { line in
            let lineData = Data(line)
            guard let event = try? decoder.decode(DecodedEvent.self, from: lineData),
                  seenKeys.insert(eventKey(event)).inserted
            else { return nil }
            return lineData
        }
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

    // MARK: Import (idempotent merge + compaction)

    /// Merges an exported log (e.g. from the iPhone app) into this device's
    /// log and returns how many *new* judgments were added.
    ///
    /// Exports are cumulative — each one contains the device's whole history
    /// — so overlap with what's already here is the norm, not the exception.
    /// Import is therefore an **idempotent merge**: events are identified by
    /// timestamp + pair, anything already present is skipped, and importing
    /// the same (or an older, subset) export twice adds nothing. The pass
    /// also rewrites the current file de-duplicated against itself and the
    /// rotated history, healing duplicates left by earlier naive imports.
    /// The local log is the canonical store; exporting it yields the
    /// combined history for training.
    @discardableResult
    static func importData(_ data: Data) -> Int {
        var seen = Set<String>()

        // Rotated history is old and bounded — left untouched, but its keys
        // seed the dedupe so nothing it holds is duplicated again.
        let rotated = (try? Data(contentsOf: TrainingLog.rotatedURL(for: fileURL))) ?? Data()
        _ = dedupedLines(rotated, seenKeys: &seen)

        let current = (try? Data(contentsOf: fileURL)) ?? Data()
        let compacted = dedupedLines(current, seenKeys: &seen)
        let fresh = dedupedLines(data, seenKeys: &seen)

        var merged = Data()
        for line in compacted + fresh {
            merged.append(line)
            merged.append(UInt8(ascii: "\n"))
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try merged.write(to: fileURL, options: .atomic)
        } catch {
            return 0
        }
        return fresh.count
    }

    // MARK: Export

    static var hasLoggedData: Bool { TrainingLog.hasData(fileURL) }
    static func exportData() -> Data { TrainingLog.exportData(fileURL) }
}
