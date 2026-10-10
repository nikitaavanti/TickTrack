import Foundation
import Testing
@testable import TickTrackCore

private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Moscow")!
    return c
}()

private let config = TrackerConfig(rules: WriteOffRules(roundUpToFive: true, minimumMinutes: 2), defaultType: .analysis, calendar: calendar)

private func at(_ hour: Int, _ minute: Int, day: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private func drafts(_ events: [TrackerEvent]) -> [SegmentDraft] {
    events.compactMap { if case .draft(let d) = $0 { d } else { nil } }
}

@Suite struct RulesTests {
    @Test func roundsUpToFive() {
        let rules = WriteOffRules(roundUpToFive: true, minimumMinutes: 2)
        #expect(rules.billableMinutes(raw: 42) == 45)
        #expect(rules.billableMinutes(raw: 45) == 45)
        #expect(rules.billableMinutes(raw: 2) == 5)
    }

    @Test func keepsMinutesWithoutRounding() {
        #expect(WriteOffRules(roundUpToFive: false, minimumMinutes: 2).billableMinutes(raw: 42) == 42)
    }

    @Test func commentTypeChangeKeepsText() {
        let text = "Анализ: разобрал замечания"
        #expect(CommentText.replacingType(in: text, with: .call) == "Созвон: разобрал замечания")
        #expect(CommentText.replacingType(in: "свой текст", with: .call) == "Созвон: свой текст")
    }

    @Test func emptyCommentBecomesType() {
        #expect(CommentText.finalized("Анализ: ", type: .analysis) == "Анализ")
        #expect(CommentText.finalized("  ", type: .testing) == "Тестирование")
        #expect(CommentText.finalized("Анализ: готово", type: .analysis) == "Анализ: готово")
    }

    @Test func youTrackDateIsUTCMidnightOfLocalDay() {
        // 00:30 по Москве 13 октября — это ещё 12 октября по UTC, но списание идёт датой 13-го.
        let ms = TimeMath.youTrackDate(for: at(0, 30, day: 13), calendar: calendar)
        #expect(ms == 1_791_849_600_000)
    }

    @Test func formatsHoursMinutes() {
        #expect(TimeMath.hm(45) == "0:45")
        #expect(TimeMath.hm(125) == "2:05")
    }
}

@Suite struct TrackingTests {
    @Test func switchingCreatesRoundedDraft() {
        var state = TrackerState()
        _ = state.start(issueId: "A-1", at: at(10, 0), config: config)
        let events = state.start(issueId: "B-2", at: at(10, 42), config: config)
        let draft = try! #require(drafts(events).first)
        #expect(draft.issueId == "A-1")
        #expect(draft.rawMinutes == 42)
        #expect(draft.minutes == 45)
        #expect(state.current == ActiveSegment(issueId: "B-2", start: at(10, 42)))
        #expect(state.plan == ["A-1", "B-2"])
    }

    @Test func shortSegmentIsNotWrittenOff() {
        var state = TrackerState()
        _ = state.start(issueId: "A-1", at: at(10, 0), config: config)
        let events = state.start(issueId: "B-2", at: at(10, 1), config: config)
        #expect(events == [.tooShort(issueId: "A-1", rawMinutes: 1)])
    }

    @Test func clickingCurrentTaskDoesNothing() {
        var state = TrackerState()
        _ = state.start(issueId: "A-1", at: at(10, 0), config: config)
        #expect(state.start(issueId: "A-1", at: at(10, 30), config: config).isEmpty)
        #expect(state.current?.start == at(10, 0))
    }

    @Test func suggestsLastTypeForIssue() {
        var state = TrackerState()
        state.lastTypeByIssue["A-1"] = .testing
        _ = state.start(issueId: "A-1", at: at(10, 0), config: config)
        let draft = drafts(state.pause(at: at(10, 20), config: config)).first
        #expect(draft?.suggestedType == .testing)
        #expect(state.status == .paused)
    }

    @Test func forgotToSwitchSplitsAtBoundary() {
        var state = TrackerState()
        _ = state.start(issueId: "A-1", at: at(10, 0), config: config)
        let events = state.reassign(lastMinutes: 20, to: "B-2", now: at(11, 0), config: config)
        #expect(drafts(events).first?.end == at(10, 40))
        #expect(drafts(events).first?.rawMinutes == 40)
        #expect(state.current == ActiveSegment(issueId: "B-2", start: at(10, 40)))
    }

    @Test func segmentAcrossMidnightIsSplit() {
        var state = TrackerState()
        _ = state.start(issueId: "A-1", at: at(23, 30), config: config)
        let parts = drafts(state.endDay(at: at(0, 40, day: 13), config: config))
        #expect(parts.map(\.rawMinutes) == [30, 40])
        #expect(parts[1].start == at(0, 0, day: 13))
        #expect(state.status == .ended)
    }

    @Test func idleGoesToOtherTaskAsCall() {
        var state = TrackerState()
        _ = state.start(issueId: "A-1", at: at(10, 0), config: config)
        let events = state.resolveIdle(
            from: at(11, 5), to: at(11, 25), choice: .otherIssue("ORG-3"), continueTracking: true, config: config
        )
        let list = drafts(events)
        #expect(list.count == 2)
        #expect(list[0].issueId == "A-1" && list[0].end == at(11, 5))
        #expect(list[1].issueId == "ORG-3" && list[1].rawMinutes == 20 && list[1].suggestedType == .call)
        #expect(state.current == ActiveSegment(issueId: "A-1", start: at(11, 25)))
        #expect(state.lastIdleIssueId == "ORG-3")
    }

    @Test func discardIdleWithoutContinuingPauses() {
        var state = TrackerState()
        _ = state.start(issueId: "A-1", at: at(10, 0), config: config)
        let list = drafts(state.resolveIdle(from: at(10, 30), to: at(11, 0), choice: .discard, continueTracking: false, config: config))
        #expect(list.map(\.rawMinutes) == [30])
        #expect(state.status == .paused)
    }

    @Test func startCandidatePrefersLastTaskInPlan() {
        var state = TrackerState()
        state.plan = ["A-1", "B-2"]
        #expect(state.startCandidate == "A-1")
        state.lastIssueId = "B-2"
        #expect(state.startCandidate == "B-2")
        state.lastIssueId = "C-3"
        #expect(state.startCandidate == "A-1")
    }

    @Test func newDayMovesPlanToPrevious() {
        var state = TrackerState()
        state.beginDay(plan: ["A-1", "B-2"], at: at(9, 0), calendar: calendar)
        _ = state.endDay(at: at(18, 0), config: config)
        state.rollOver(now: at(9, 0, day: 13), calendar: calendar)
        #expect(state.plan.isEmpty)
        #expect(state.previousPlan == ["A-1", "B-2"])
        #expect(state.status == .notStarted)
    }
}

@Suite struct SyncBookkeepingTests {
    private func committedState() -> (TrackerState, LogEntry) {
        var state = TrackerState()
        let draft = SegmentDraft(issueId: "A-1", start: at(10, 0), end: at(10, 42), rawMinutes: 42, minutes: 45, suggestedType: .analysis)
        let entry = state.commit(draft, comment: "Анализ: ", type: .analysis)
        return (state, entry)
    }

    @Test func commitFinalizesComment() {
        let (state, entry) = committedState()
        #expect(entry.comment == "Анализ")
        #expect(state.lastTypeByIssue["A-1"] == .analysis)
        #expect(state.hasPendingSync)
    }

    @Test func createdWorkItemMarksSynced() {
        var (state, entry) = committedState()
        state.markCreated(entryId: entry.id, workItemId: "w1", issueId: "A-1", revision: 0)
        #expect(state.entries[0].sync == .synced)
        #expect(!state.hasPendingSync)
    }

    @Test func editDuringCreateKeepsEdit() {
        var (state, entry) = committedState()
        state.updateEntry(id: entry.id, issueId: "A-1", minutes: 30, comment: "Анализ: правка")
        state.markCreated(entryId: entry.id, workItemId: "w1", issueId: "A-1", revision: 0)
        #expect(state.entries[0].sync == .pendingUpdate)
        #expect(state.entries[0].workItemId == "w1")
    }

    @Test func movingSyncedEntryDeletesOldWorkItem() {
        var (state, entry) = committedState()
        state.markCreated(entryId: entry.id, workItemId: "w1", issueId: "A-1", revision: 0)
        state.updateEntry(id: entry.id, issueId: "B-2", minutes: 45, comment: "Анализ")
        #expect(state.deletions.map(\.workItemId) == ["w1"])
        #expect(state.entries[0].sync == .pendingCreate)
        #expect(state.entries[0].workItemId == nil)
    }

    @Test func deletingUnsentEntryNeedsNoRequest() {
        var (state, entry) = committedState()
        state.deleteEntry(id: entry.id)
        #expect(state.entries.isEmpty && state.deletions.isEmpty)
    }

    @Test func createdAfterLocalDeleteIsRemoved() {
        var (state, entry) = committedState()
        state.deleteEntry(id: entry.id)
        state.markCreated(entryId: entry.id, workItemId: "w1", issueId: "A-1", revision: 0)
        #expect(state.deletions.map(\.workItemId) == ["w1"])
    }

    @Test func stateSurvivesRoundTrip() throws {
        var (state, _) = committedState()
        _ = state.start(issueId: "B-2", at: at(11, 0), config: config)
        let url = FileManager.default.temporaryDirectory.appending(path: "ticktrack-\(UUID()).json")
        let store = StateStore(url: url)
        try store.save(state)
        let loaded = store.load()
        #expect(loaded.current == state.current)
        #expect(loaded.entries == state.entries)
        try? FileManager.default.removeItem(at: url)
    }
}
