import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Append-only, on-device log of ranking-feedback events — every skip,
/// complete, snooze, and delete, together with the ranked context the user
/// saw when they did it. Each action is an implicit preference judgment
/// about the current ordering (completing the top item says the ranking was
/// right; skipping it says something below deserved the spot), which makes
/// this file the raw training data for the eventual custom ranking model
/// (see the README to-do). JSON Lines, one event per line, stored in
/// Application Support. Never leaves the device.
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
    private static let maxFileBytes = 10_000_000

    /// Records one feedback event. Snapshotting happens on the caller
    /// (items are value types); encoding and file I/O run off the caller's
    /// actor so UI actions never wait on disk.
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
            item: loggedItem(item, position: position, now: now),
            context: ranked.prefix(contextLimit).enumerated().map { index, contextItem in
                loggedItem(contextItem, position: index, now: now)
            }
        )
        Task.detached(priority: .utility) {
            append(event)
        }
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RemindSort/preferences.jsonl")
    }

    private static var rotatedFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("preferences.1.jsonl")
    }

    // MARK: Export

    static var hasLoggedData: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: fileURL.path) || fm.fileExists(atPath: rotatedFileURL.path)
    }

    /// The full log as one blob — rotated history first, then the current
    /// file, so exported lines stay in chronological order.
    static func exportData() -> Data {
        var data = (try? Data(contentsOf: rotatedFileURL)) ?? Data()
        data.append((try? Data(contentsOf: fileURL)) ?? Data())
        return data
    }

    /// JSON Lines; falls back to plain text if the runtime can't mint the
    /// dynamic type (the export is text either way).
    static let exportType = UTType(filenameExtension: "jsonl", conformingTo: .plainText) ?? .plainText

    /// Minimal FileDocument wrapper so SettingsView can hand the log to
    /// SwiftUI's `.fileExporter` (save panel on macOS, Files sheet on iOS).
    struct ExportDocument: FileDocument {
        static var readableContentTypes: [UTType] { [exportType, .plainText] }

        let data: Data

        init(data: Data) {
            self.data = data
        }

        init(configuration: ReadConfiguration) throws {
            data = configuration.file.regularFileContents ?? Data()
        }

        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            FileWrapper(regularFileWithContents: data)
        }
    }

    private static func loggedItem(_ item: ReminderItem, position: Int, now: Date) -> LoggedItem {
        LoggedItem(
            position: position,
            id: item.id,
            title: item.title,
            notes: item.notes.map { $0.count > 140 ? String($0.prefix(140)) + "…" : $0 },
            list: item.listName,
            dueInDays: item.dueDate.map { days(from: now, to: $0) },
            createdDaysAgo: item.creationDate.map { days(from: $0, to: now) },
            priority: item.rawPriority,
            score: item.score
        )
    }

    private static func days(from: Date, to: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: from),
            to: calendar.startOfDay(for: to)
        ).day ?? 0
    }

    private static func append(_ event: Event) {
        guard var line = try? JSONEncoder().encode(event) else { return }
        line.append(UInt8(ascii: "\n"))

        let url = fileURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                try line.write(to: url)
                return
            }
            // One-level rotation keeps the log from growing unbounded while
            // preserving roughly the most recent history for training.
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxFileBytes {
                let rotated = url.deletingLastPathComponent().appendingPathComponent("preferences.1.jsonl")
                try? fm.removeItem(at: rotated)
                try fm.moveItem(at: url, to: rotated)
                try line.write(to: url)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Logging is best-effort; never surface an error for it.
        }
    }
}
