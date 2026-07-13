import Foundation

/// Append-only, on-device log of *implicit* ranking feedback — every skip,
/// complete, snooze, and delete, together with the ranked context the user
/// saw when they did it. Each action is an implicit preference judgment
/// about the current ordering (completing the top item says the ranking was
/// right; skipping it says something below deserved the spot). For *explicit*
/// pairwise judgments, see `FaceOffLog`. Both are training data for the
/// eventual custom ranking model (see the README to-do), share the same file
/// machinery (`TrainingLog`), and never leave the device unless exported.
enum PreferenceLog {
    struct LoggedItem: Encodable, Sendable {
        let position: Int
        let id: String
        let title: String
        let notes: String?
        let list: String
        let dueInDays: Int?
        let createdDaysAgo: Int?
        let priority: Int
        let score: Int?

        init(_ item: ReminderItem, position: Int, now: Date) {
            self.position = position
            let base = TrainingLog.LoggedReminder(item, now: now)
            id = base.id
            title = base.title
            notes = base.notes
            list = base.list
            dueInDays = base.dueInDays
            createdDaysAgo = base.createdDaysAgo
            priority = base.priority
            score = base.score
        }
    }

    struct Event: Encodable, Sendable {
        let ts: String
        let action: String
        let snoozeDays: Int?
        let item: LoggedItem
        /// The top of the ranked list the user was looking at (capped),
        /// so pairwise preferences can be reconstructed later.
        let context: [LoggedItem]
    }

    private static let contextLimit = 10

    static var fileURL: URL {
        TrainingLog.directory.appendingPathComponent("preferences.jsonl")
    }

    /// Records one feedback event. Snapshotting happens on the caller (items
    /// are value types); encoding and file I/O run off the caller's actor so
    /// UI actions never wait on disk.
    static func record(
        action: String,
        item: ReminderItem,
        position: Int,
        context ranked: [ReminderItem],
        snoozeDays: Int? = nil
    ) {
        let now = Date()
        let event = Event(
            ts: ISO8601DateFormatter().string(from: now),
            action: action,
            snoozeDays: snoozeDays,
            item: LoggedItem(item, position: position, now: now),
            context: ranked.prefix(contextLimit).enumerated().map { index, contextItem in
                LoggedItem(contextItem, position: index, now: now)
            }
        )
        Task.detached(priority: .utility) {
            guard let line = try? JSONEncoder().encode(event) else { return }
            TrainingLog.append(line, to: fileURL)
        }
    }

    // MARK: Export

    static var hasLoggedData: Bool { TrainingLog.hasData(fileURL) }
    static func exportData() -> Data { TrainingLog.exportData(fileURL) }
    static let exportType = TrainingLog.exportType
    typealias ExportDocument = TrainingLog.ExportDocument
}
