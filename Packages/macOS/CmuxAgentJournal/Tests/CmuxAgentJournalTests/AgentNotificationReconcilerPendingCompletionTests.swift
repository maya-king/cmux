import Foundation
import Testing
@testable import CmuxAgentJournal

extension AgentNotificationReconcilerTests {
    @Test(arguments: [false, true], [nil, "turn-1"] as [String?])
    func pendingCompletionReachesSurfaceAdmissionWithoutAnotherEvent(knownChild: Bool, turn: String?) throws {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: "claude", turn: turn, notify: false))
        if knownChild {
            _ = reconciler.apply(event(2, .childSpawned, source: "claude", turn: turn,
                                       request: "child", notify: false))
        }
        let stop = event(3, .turnCompleted, source: "claude", turn: turn, pending: !knownChild)
        let candidate = reconciler.apply(stop)
        #expect(candidate.disposition == .accepted)
        let identity = try #require(candidate.identity)
        #expect(!identity.isEmpty)
        let delivery = candidate.notificationEvent ?? stop
        #expect(delivery.draft.surfaceId == surface)
        #expect(delivery.draft.pendingWork)
        #expect(reconciler.lifecycleEvent(stop).draft.pendingWork)

        // An always-enabled completion can notify now, but settlement must use
        // the same durable receipt even if its hook carries a different event ID.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentJournalStore(databaseURL: root.appendingPathComponent("journal.sqlite"))
        defer { store.close() }
        #expect(try store.claimNotification(identity: identity))
        let settled: AgentNotificationDecision
        if knownChild {
            settled = reconciler.apply(event(4, .childCompleted, source: "claude", turn: turn,
                                             request: "child", notify: false))
        } else {
            settled = reconciler.apply(event(4, .turnCompleted, source: "claude", turn: turn))
        }
        #expect(settled.disposition == .accepted)
        #expect(settled.identity == identity)
        #expect(try !store.claimNotification(identity: #require(settled.identity)))
    }
}
