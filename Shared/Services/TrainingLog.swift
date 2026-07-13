import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Shared machinery for the on-device, append-only JSON Lines training logs
/// (`PreferenceLog`'s implicit feedback and `FaceOffLog`'s explicit pairwise
/// judgments). Centralizes the file I/O, one-level rotation, export blob,
/// and the per-reminder feature snapshot so the two logs can't drift apart.
/// Nothing here ever leaves the device unless the user exports it.
enum TrainingLog {
    static let maxFileBytes = 10_000_000

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemindSort")
    }

    /// `preferences.jsonl` -> `preferences.1.jsonl` (the rotated older half).
    static func rotatedURL(for url: URL) -> URL {
        let ext = url.pathExtension
        return url.deletingPathExtension().appendingPathExtension("1").appendingPathExtension(ext)
    }

    /// Appends one JSON line (a trailing newline is added if missing), with
    /// one-level rotation at `maxFileBytes` so a log can't grow unbounded
    /// while keeping roughly the most recent history. Best-effort: logging
    /// never surfaces an error.
    static func append(_ line: Data, to url: URL) {
        var line = line
        if line.last != UInt8(ascii: "\n") { line.append(UInt8(ascii: "\n")) }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                try line.write(to: url)
                return
            }
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxFileBytes {
                let rotated = rotatedURL(for: url)
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
            // Best-effort.
        }
    }

    static func hasData(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path) || fm.fileExists(atPath: rotatedURL(for: url).path)
    }

    /// The whole log as one blob — rotated history first, then the current
    /// file, so exported lines stay in chronological order.
    static func exportData(_ url: URL) -> Data {
        var data = (try? Data(contentsOf: rotatedURL(for: url))) ?? Data()
        data.append((try? Data(contentsOf: url)) ?? Data())
        return data
    }

    /// JSON Lines; falls back to plain text if the runtime can't mint the
    /// dynamic type (the export is text either way).
    static let exportType = UTType(filenameExtension: "jsonl", conformingTo: .plainText) ?? .plainText

    /// Minimal FileDocument wrapper so SettingsView can hand a log blob to
    /// SwiftUI's `.fileExporter` (save panel on macOS, Files sheet on iOS).
    struct ExportDocument: FileDocument {
        static var readableContentTypes: [UTType] { [exportType, .plainText] }

        let data: Data

        init(data: Data) { self.data = data }

        init(configuration: ReadConfiguration) throws {
            data = configuration.file.regularFileContents ?? Data()
        }

        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            FileWrapper(regularFileWithContents: data)
        }
    }

    /// The feature snapshot of one reminder written into a log line — the
    /// same fields regardless of which log records it, so a trained model
    /// sees a consistent schema.
    struct LoggedReminder: Encodable, Sendable {
        let id: String
        let title: String
        let notes: String?
        let list: String
        let dueInDays: Int?
        let createdDaysAgo: Int?
        let priority: Int
        let score: Int?

        init(_ item: ReminderItem, now: Date = Date()) {
            id = item.id
            title = item.title
            notes = item.notes.map { $0.count > 140 ? String($0.prefix(140)) + "…" : $0 }
            list = item.listName
            dueInDays = item.dueDate.map { TrainingLog.days(from: now, to: $0) }
            createdDaysAgo = item.creationDate.map { TrainingLog.days(from: $0, to: now) }
            priority = item.rawPriority
            score = item.score
        }
    }

    static func days(from: Date, to: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: from),
            to: calendar.startOfDay(for: to)
        ).day ?? 0
    }
}
