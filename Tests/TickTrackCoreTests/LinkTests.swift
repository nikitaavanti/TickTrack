import Foundation
import Testing
@testable import TickTrackCore

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func after(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

private let offline = YouTrackError.network("The Internet connection appears to be offline.")

@Suite struct LinkWatchTests {
    @Test func shortFailureIsNotShown() {
        var link = LinkWatch()
        link.record(offline, networkAvailable: false, at: start)
        link.record(offline, networkAvailable: false, at: after(30))
        #expect(link.isFailing)
        #expect(link.problem == nil)
        let recovered = link.record(nil, networkAvailable: true, at: after(40))
        #expect(!recovered)
        #expect(!link.isFailing)
    }

    @Test func failureLongerThanGraceIsShown() {
        var link = LinkWatch()
        link.record(offline, networkAvailable: false, at: start)
        link.record(offline, networkAvailable: false, at: after(LinkWatch.grace))
        #expect(link.problem == .noNetwork)
        #expect(link.failingSince == start)
    }

    @Test func networkUpButNoAnswerIsNotResponding() {
        var link = LinkWatch()
        link.record(YouTrackError.server(status: 503, message: ""), networkAvailable: true, at: start)
        link.record(offline, networkAvailable: true, at: after(90))
        #expect(link.problem == .notResponding)
    }

    @Test func recoveryIsReportedOnce() {
        var link = LinkWatch()
        link.record(offline, networkAvailable: false, at: start)
        link.record(offline, networkAvailable: false, at: after(60))
        let first = link.record(nil, networkAvailable: true, at: after(70))
        let second = link.record(nil, networkAvailable: true, at: after(80))
        #expect(first)
        #expect(!second)
        #expect(link.problem == nil)
    }

    @Test func rejectedTokenIsShownAtOnce() {
        var link = LinkWatch()
        link.record(YouTrackError.unauthorized, networkAvailable: true, at: start)
        #expect(link.problem == .tokenRejected)
    }

    @Test func anyServerAnswerMeansConnected() {
        var link = LinkWatch()
        link.record(YouTrackError.unauthorized, networkAvailable: true, at: start)
        let recovered = link.record(YouTrackError.notFound, networkAvailable: true, at: after(5))
        #expect(recovered)
        #expect(!link.isFailing)
    }

    @Test func otherErrorsChangeNothing() {
        var link = LinkWatch()
        link.record(offline, networkAvailable: false, at: start)
        link.record(CancellationError(), networkAvailable: false, at: after(90))
        link.record(YouTrackError.notConfigured, networkAvailable: false, at: after(90))
        #expect(link.problem == nil)
        #expect(link.failingSince == start)
    }

    @Test func sleepRestartsGrace() {
        var link = LinkWatch()
        link.record(offline, networkAvailable: false, at: start)
        link.restartGrace()
        link.record(offline, networkAvailable: false, at: after(8 * 3600))
        #expect(link.problem == nil)
        #expect(link.failingSince == after(8 * 3600))
    }

    @Test func shownProblemSurvivesSleep() {
        var link = LinkWatch()
        link.record(offline, networkAvailable: false, at: start)
        link.record(offline, networkAvailable: false, at: after(60))
        link.restartGrace()
        #expect(link.problem == .noNetwork)
    }

    @Test func gatewayErrorsAreConnectivity() {
        #expect(YouTrackError.server(status: 502, message: "").isConnectivity)
        #expect(YouTrackError.server(status: 504, message: "").isConnectivity)
        #expect(!YouTrackError.server(status: 500, message: "").isConnectivity)
        #expect(!YouTrackError.unauthorized.isConnectivity)
    }
}

@Suite struct PendingQueueTests {
    private func state(entries count: Int) -> TrackerState {
        var state = TrackerState()
        for index in 0..<count {
            let draft = SegmentDraft(
                issueId: "A-\(index)", start: after(Double(index) * 3600), end: after(Double(index) * 3600 + 1800),
                rawMinutes: 30, minutes: 30, suggestedType: .analysis
            )
            _ = state.commit(draft, comment: "Анализ", type: .analysis)
        }
        return state
    }

    @Test func pendingEntriesSkipSynced() {
        var state = state(entries: 2)
        state.markCreated(entryId: state.entries[0].id, workItemId: "w1", issueId: "A-0", revision: 0)
        #expect(state.pendingEntries.map(\.issueId) == ["A-1"])
    }

    @Test func waitingIsMarkedOnce() {
        var state = state(entries: 2)
        let first = state.markWaiting(message: "Нет связи")
        let second = state.markWaiting(message: "Нет связи")
        #expect(first.count == 2)
        #expect(second.isEmpty)
        #expect(state.entries.allSatisfy { $0.lastError == "Нет связи" })
    }

    @Test func editedEntryIsMarkedAgain() {
        var state = state(entries: 1)
        _ = state.markWaiting(message: "Нет связи")
        state.updateEntry(id: state.entries[0].id, issueId: "A-0", minutes: 20, comment: "Анализ")
        let marked = state.markWaiting(message: "Нет связи")
        #expect(marked.map(\.minutes) == [20])
    }

    @Test func russianPlural() {
        #expect(RussianPlural.count(1, "списание", "списания", "списаний") == "1 списание")
        #expect(RussianPlural.count(3, "списание", "списания", "списаний") == "3 списания")
        #expect(RussianPlural.count(5, "списание", "списания", "списаний") == "5 списаний")
        #expect(RussianPlural.count(11, "списание", "списания", "списаний") == "11 списаний")
        #expect(RussianPlural.count(21, "списание", "списания", "списаний") == "21 списание")
        #expect(RussianPlural.count(112, "списание", "списания", "списаний") == "112 списаний")
        #expect(RussianPlural.isSingular(1) && RussianPlural.isSingular(21))
        #expect(!RussianPlural.isSingular(11) && !RussianPlural.isSingular(3))
    }
}
