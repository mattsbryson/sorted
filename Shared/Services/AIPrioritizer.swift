import Foundation
import FoundationModels

enum AIAvailability: Sendable {
    case available
    case unavailable(String)
}

struct AIPrioritizer: Sendable {
    /// The model's context window limits how many reminders can be judged in
    /// a single call. Kept small (well under the 4096-token ceiling) so each
    /// reminder gets more careful individual attention rather than being
    /// diluted across a large batch.
    private static let batchSize = 15

    /// How many of the top-ranked reminders get the listwise re-rank pass.
    /// Sized to fit one model call.
    private static let reorderCount = 15

    static var availability: AIAvailability {
        // Shared across platforms, so device/settings naming is resolved at
        // compile time — an iPhone shouldn't be told about "This Mac".
        #if os(macOS)
        let device = "Mac"
        let settingsApp = "System Settings"
        #else
        let device = "device"
        let settingsApp = "Settings"
        #endif
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable("This \(device) doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in \(settingsApp) to enable AI sorting.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence model is still downloading. Using basic sorting for now.")
        case .unavailable:
            return .unavailable("Apple Intelligence is unavailable. Using basic sorting for now.")
        }
    }

    /// Returns all items ranked from most to least important. Callers
    /// should show a loading state for the duration of this call — it's
    /// synchronous work with no background refinement afterward.
    ///
    /// Ranking splits into two independent axes, each handled by the part of
    /// the system that's actually good at it:
    ///
    /// - **Importance** (real-world stakes): the model classifies each
    ///   reminder from its title, notes, and list — content only, no dates.
    ///   Cached per reminder (`ImportanceCache`) until its content changes,
    ///   so rescheduling or snoozing never costs a model call.
    /// - **Time urgency**: computed deterministically from the due/creation
    ///   dates at rank time (`UrgencyScorer`), so it's always current — a
    ///   reminder drifting toward its due date climbs the ranking day by day
    ///   even though nothing about it changed.
    ///
    /// After deterministic scoring, the top `reorderCount` candidates get
    /// one **listwise re-rank** model call that judges them side by side
    /// (see `reorderTop`) — comparative fine ordering is the one thing
    /// per-item classification can't provide.
    ///
    /// Anything without an AI judgment (Apple Intelligence unavailable, a
    /// model call failing, or an item omitted from the model's response)
    /// falls back to an importance derived from the explicit priority flag —
    /// computed fresh each rank and never cached, so it self-corrects once
    /// the model can actually judge it. If everything's already cached, this
    /// returns immediately with no model call at all.
    /// With `consideringDueDates` off (user setting), scoring drops the time
    /// axis and ranks purely by importance; classification and caching are
    /// unaffected since the model never sees dates anyway. Same-importance
    /// items still tie-break by due date, which only orders within a tier.
    func rank(
        _ items: [ReminderItem],
        consideringDueDates: Bool = true
    ) async -> [ReminderItem] {
        guard !items.isEmpty else { return [] }

        let aiAvailable: Bool = {
            if case .available = Self.availability { return true }
            return false
        }()

        // AI-classified importance only; fallback tiers are applied at
        // scoring time below and deliberately never enter this dictionary,
        // so they can't be cached as if the model had judged them.
        var aiTiers: [String: ImportanceTier] = [:]

        if aiAvailable {
            aiTiers = ImportanceCache.cachedTiers(for: items)
            let toClassify = items.filter { aiTiers[$0.id] == nil }
            if !toClassify.isEmpty {
                let classified = await batchClassify(toClassify)
                aiTiers.merge(classified) { _, new in new }
            }
            ImportanceCache.save(items: items, tiers: aiTiers)
        }

        let now = Date()
        let scored = items.map { item in
            let tier = aiTiers[item.id] ?? UrgencyScorer.fallbackImportance(for: item)
            return item.withScore(UrgencyScorer.score(
                importance: tier,
                item: item,
                now: now,
                consideringDueDates: consideringDueDates
            ))
        }
        var ranked = sortRanked(scored, originalOrder: items)
        if aiAvailable {
            ranked = await reorderTop(ranked, consideringDueDates: consideringDueDates, now: now)
        }
        return ranked
    }

    /// Listwise re-rank of the top of the list: the deterministic score
    /// picks *which* reminders matter most, then one model call orders that
    /// group by judging its members side by side — restoring the
    /// comparative context that per-item classification into coarse tiers
    /// throws away. The result is cached per candidate set per calendar day
    /// (`TopOrderCache`), so relaunches with unchanged data cost no model
    /// call; if the call fails, the deterministic order simply stands. The
    /// slice's existing scores are reassigned in the new order so displayed
    /// scores stay monotonically decreasing down the list.
    private func reorderTop(
        _ ranked: [ReminderItem],
        consideringDueDates: Bool,
        now: Date
    ) async -> [ReminderItem] {
        let count = min(Self.reorderCount, ranked.count)
        guard count > 1 else { return ranked }
        let candidates = Array(ranked.prefix(count))

        let orderedIDs: [String]
        if let cached = TopOrderCache.cachedOrder(for: candidates, includesDates: consideringDueDates, now: now) {
            orderedIDs = cached
        } else if let fresh = await listwiseOrder(candidates, includeDates: consideringDueDates, now: now) {
            TopOrderCache.save(order: fresh, for: candidates, includesDates: consideringDueDates, now: now)
            orderedIDs = fresh
        } else {
            return ranked
        }

        // Rebuild the top slice in the model's order; anything the model
        // omitted (or duplicated) keeps its prior relative position at the
        // end of the slice.
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var reordered: [ReminderItem] = []
        var seen: Set<String> = []
        for id in orderedIDs {
            if let item = byID[id], seen.insert(id).inserted {
                reordered.append(item)
            }
        }
        for item in candidates where seen.insert(item.id).inserted {
            reordered.append(item)
        }

        let slotScores = candidates.map { $0.score ?? 0 }
        let rescored = zip(reordered, slotScores).map { $0.withScore($1) }
        return rescored + ranked.dropFirst(count)
    }

    /// One model call ordering the given reminders most-important-first.
    /// Unlike importance classification, this pass *does* see due and
    /// creation dates (as app-computed relative offsets) when the user has
    /// due dates enabled — weighing stakes and timing together across the
    /// whole group is exactly the comparative judgment this call exists
    /// for. Returns nil if the call fails or yields no usable tokens.
    private func listwiseOrder(
        _ batch: [ReminderItem],
        includeDates: Bool,
        now: Date
    ) async -> [String]? {
        let lines = batch.enumerated().map { index, item in
            var line = formatLine(token: "R\(index)", item: item)
            if includeDates {
                line += " due=\(relativeDayDescription(for: item.dueDate, now: now, pastPrefix: "overdue by", pastSuffix: "", futurePrefix: "in", noneValue: "none"))"
                if let created = item.creationDate {
                    line += " created=\(relativeDayDescription(for: created, now: now, pastPrefix: "", pastSuffix: "ago", futurePrefix: "in", noneValue: "unknown"))"
                }
            }
            return line
        }

        let timingClause = includeDates
            ? "Weigh real-world stakes and timing together: due dates and "
                + "creation dates are given as relative offsets from today, "
                + "already computed by the app — use them directly."
            : "Judge by real-world stakes alone — what each task is, not when."
        let session = LanguageModelSession(
            instructions: """
            You order a person's reminders (to-dos) by which deserves \
            attention first, judging all of them together as a group. \
            \(timingClause) Respond only with the requested ordering of \
            tokens, most important first, every token exactly once.
            """
        )

        var tokenToID: [String: String] = [:]
        for (index, item) in batch.enumerated() {
            tokenToID["R\(index)"] = item.id
        }

        do {
            let prompt = "Order these reminders, most important first:\n" + lines.joined(separator: "\n")
            let response = try await session.respond(to: prompt, generating: RankedOrder.self)
            let ids = response.content.tokens.compactMap { tokenToID[$0] }
            return ids.isEmpty ? nil : ids
        } catch {
            return nil
        }
    }

    /// Converts an absolute date into a human-readable relative description
    /// ("overdue by 12 days", "in 3 days", "45 days ago", "today") anchored
    /// to `now`, computed by the app rather than left for the model to
    /// infer — on-device models are unreliable at date arithmetic, so doing
    /// it here removes that entire failure mode.
    private func relativeDayDescription(
        for date: Date?,
        now: Date,
        pastPrefix: String,
        pastSuffix: String,
        futurePrefix: String,
        noneValue: String
    ) -> String {
        guard let date else { return noneValue }
        // Calendar-day difference (midnight to midnight), not a raw 24h
        // rounding — otherwise something due at 11pm today, checked at 9am,
        // would misleadingly read as "in 1 day" instead of "today".
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days == 0 { return "today" }
        let magnitude = abs(days)
        let unit = "day\(magnitude == 1 ? "" : "s")"
        if days < 0 {
            let words = [pastPrefix, "\(magnitude) \(unit)", pastSuffix].filter { !$0.isEmpty }
            return words.joined(separator: " ")
        } else {
            return "\(futurePrefix) \(magnitude) \(unit)"
        }
    }

    /// Highest score first; ties break by earlier due date (undated last),
    /// then stable original fetch order so equal items don't jump around
    /// between runs.
    private func sortRanked(_ scored: [ReminderItem], originalOrder: [ReminderItem]) -> [ReminderItem] {
        let originalIndex = Dictionary(uniqueKeysWithValues: originalOrder.enumerated().map { ($1.id, $0) })
        return scored.sorted { a, b in
            let scoreA = a.score ?? 0
            let scoreB = b.score ?? 0
            if scoreA != scoreB { return scoreA > scoreB }
            switch (a.dueDate, b.dueDate) {
            case let (dueA?, dueB?) where dueA != dueB:
                return dueA < dueB
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return (originalIndex[a.id] ?? .max) < (originalIndex[b.id] ?? .max)
            }
        }
    }

    /// Splits items into <=batchSize chunks and classifies each with the
    /// model.
    private func batchClassify(_ items: [ReminderItem]) async -> [String: ImportanceTier] {
        guard !items.isEmpty else { return [:] }
        var result: [String: ImportanceTier] = [:]
        for start in stride(from: 0, to: items.count, by: Self.batchSize) {
            let chunk = Array(items[start..<min(start + Self.batchSize, items.count)])
            let batchTiers = await classifyWithModel(chunk)
            for (id, tier) in batchTiers {
                result[id] = tier
            }
        }
        return result
    }

    /// The model echoes back each reminder's token alongside its tier, so
    /// mapping back to items is unambiguous even if the model reorders or
    /// omits entries. Returns only what the model actually classified —
    /// omissions and thrown calls yield no entry, leaving the caller's
    /// priority-flag fallback to cover those items for this rank only.
    private func classifyWithModel(_ batch: [ReminderItem]) async -> [String: ImportanceTier] {
        let lines = batch.enumerated().map { index, item in
            formatLine(token: "R\(index)", item: item)
        }

        // Anchors pin the rubric's scale; the user's own recent Face Off
        // picks personalize it (see ClassificationExamples). Both are small
        // relative to the ~4096-token context shared with the batch lines.
        let session = LanguageModelSession(
            instructions: """
            You judge the real-world importance of a person's reminders \
            (to-dos): how much it matters that each task ever gets done, \
            based only on what the task is — its title, notes, and which \
            list it's in. Ignore timing entirely: due dates and scheduling \
            are handled separately by the app, so importance here means \
            consequence, not deadline pressure. A trivial errand is still \
            low importance even if marked urgent, and a serious obligation \
            is still critical even with no deadline mentioned. \
            \(ClassificationExamples.tierAnchors) Respond only \
            with the requested classifications.\
            \(ClassificationExamples.userJudgmentsClause())
            """
        )

        var tokenToID: [String: String] = [:]
        for (index, item) in batch.enumerated() {
            tokenToID["R\(index)"] = item.id
        }

        do {
            let prompt = "Classify these reminders' importance:\n" + lines.joined(separator: "\n")
            let response = try await session.respond(to: prompt, generating: ImportanceTiers.self)

            var result: [String: ImportanceTier] = [:]
            for entry in response.content.entries {
                if let id = tokenToID[entry.token] {
                    result[id] = entry.tier
                }
            }
            return result
        } catch {
            return [:]
        }
    }

    /// Content only — no due date, creation date, or priority flag. Dates
    /// are handled by deterministic scoring code, and the priority flag was
    /// shown (in earlier testing) to be over-weighted by the model.
    private func formatLine(token: String, item: ReminderItem) -> String {
        var parts = ["[\(token)]", "title=\"\(item.title)\"", "list=\"\(item.listName)\""]
        if let notes = item.notes, !notes.isEmpty {
            let trimmed = notes.count > 140 ? String(notes.prefix(140)) + "…" : notes
            parts.append("notes=\"\(trimmed)\"")
        }
        return parts.joined(separator: " ")
    }
}
