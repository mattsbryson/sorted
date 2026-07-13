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

    // MARK: Export

    static var hasLoggedData: Bool { TrainingLog.hasData(fileURL) }
    static func exportData() -> Data { TrainingLog.exportData(fileURL) }
}
