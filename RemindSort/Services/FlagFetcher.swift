import Foundation

/// EventKit does not expose the Reminders app's "flagged" attribute, so we read
/// it via AppleScript instead and match results back to EventKit's
/// calendarItemIdentifier (both use the same underlying UUID).
enum FlagFetcher {
    static func fetchFlags() async -> [String: Bool] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: fetchFlagsSync())
            }
        }
    }

    private static func fetchFlagsSync() -> [String: Bool] {
        let source = """
        tell application "Reminders"
            set output to ""
            repeat with aList in lists
                repeat with r in reminders of aList
                    set output to output & (id of r as string) & tab & (flagged of r as string) & linefeed
                end repeat
            end repeat
            return output
        end tell
        """

        guard let script = NSAppleScript(source: source) else { return [:] }

        var errorDict: NSDictionary?
        let result = script.executeAndReturnError(&errorDict)
        guard errorDict == nil, let text = result.stringValue else { return [:] }

        var flags: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }
            let id = parts[0].replacingOccurrences(of: "x-apple-reminder://", with: "")
            flags[id] = (parts[1] == "true")
        }
        return flags
    }
}
