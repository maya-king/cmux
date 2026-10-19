import CMUXAgentLaunch
import CmuxFoundation
import CmuxAgentJournal
import CmuxNotifications
import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    @Test(arguments: ["always", "whenIdle", "never"])
    func pendingCompletionResolvesImmediatelyThroughSurfacePolicy(mode: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        bindAgentSession(fixture, source: "claude")
        var deliveries = 0
        fixture.store.configureNotificationDeliveryHandlerForTesting { _, _, _ in deliveries += 1 }
        let key = NotificationsCatalogSection().agentTurnComplete
        let previous = UserDefaults.standard.object(forKey: key.userDefaultsKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key.userDefaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: key.userDefaultsKey) }
        }
        key.set(mode, in: .standard)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let firstSequence = CmuxEventBus.shared.latestSequence
        var stop = AgentJournalEventDraft(kind: .turnCompleted, occurredAtMs: 1,
            source: "claude", agentKey: "claude_code", sessionId: "session",
            workspaceId: fixture.source.id.uuidString, surfaceId: fixture.panelId.uuidString,
            pendingWork: true, attention: AgentAttentionContext(
                notification: AgentJournalNotification(title: "Agent", subtitle: "", body: "Ready",
                    category: "turn-complete")))
        func flush() async {
            _ = await center.admitNotification(AgentJournalEventDraft(kind: .stateChanged,
                occurredAtMs: 0, source: "barrier", agentKey: "barrier", unattributedReason: "test-barrier"))
            TerminalMutationBus.shared.drainForTesting()
        }
        center.observe(stop)
        await flush()
        #expect(fixture.store.notifications.count == (mode == "always" ? 1 : 0))
        #expect(deliveries == (mode == "always" ? 1 : 0))
        #expect(fixture.store.notifications.allSatisfy { $0.surfaceId == fixture.panelId })
        var idle = stop
        idle.eventId = UUID().uuidString
        idle.kind = .idleObserved
        idle.occurredAtMs = 2
        idle.pendingWork = false
        idle.attention?.notification?.category = "idle-reminder"
        center.observe(idle)
        await flush()
        let snapshot = CmuxEventBus.shared.subscribe(afterSequence: firstSequence,
            names: ["agent.notification.decision"], categories: [])
        defer { CmuxEventBus.shared.unsubscribe(snapshot.subscription) }
        let decisions = snapshot.replay.compactMap { $0["payload"] as? [String: Any] }
            .filter { $0["event_id"] as? String == stop.eventId }
        #expect(decisions.contains { $0["reason"] as? String == (mode == "always" ? "accepted" : "preference-filtered") })
        #expect(!decisions.contains { $0["reason"] as? String == "delayed" })
        #expect(snapshot.replay.contains {
            guard let payload = $0["payload"] as? [String: Any] else { return false }
            return payload["event_id"] as? String == idle.eventId
                && payload["reason"] as? String == "dropped-ineligible-idle"
        })

        // A later settled hook cannot double-notify an always-enabled turn,
        // and an idle-only turn must still be able to claim its first delivery.
        stop.eventId = UUID().uuidString
        stop.occurredAtMs = 3
        stop.pendingWork = false
        center.observe(stop)
        await flush()
        #expect(fixture.store.notifications.count == (mode == "never" ? 0 : 1))
        #expect(deliveries == (mode == "never" ? 0 : 1))
    }
}
