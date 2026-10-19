import CmuxAgentJournal
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    @Test("Replayed needs-input state does not suppress shell OSC notifications")
    func desktopOSCAfterUncleanRestore() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-osc-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentJournalStore(databaseURL: root.appendingPathComponent("journal.sqlite3"))
        defer { store.close() }
        // No session-ended event was written before the unclean restart.
        _ = try store.append(AgentJournalEventDraft(
            kind: .approvalRequested, occurredAtMs: 1, source: "claude", agentKey: "claude_code",
            sessionId: "interrupted-session", workspaceId: fixture.source.id.uuidString,
            surfaceId: fixture.panelId.uuidString
        ))
        var state = AgentLifecycleReducerState()
        var notifications = AgentNotificationReconciler()
        let assignments = AgentJournalLifecycleCenter.reduceStartupReplay(
            store: store, aliases: AgentJournalAliasResolver(workspaces: [:], surfaces: [:]),
            reducer: AgentLifecycleReducer(), replayPolicy: AgentJournalReplayPolicy(),
            state: &state, notifications: &notifications
        )
        #expect(assignments.count == 1)
        for assignment in assignments {
            AgentJournalLifecycleCenter.apply(assignment, workspaceHint: nil)
        }
        #expect(fixture.source.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"] == .needsInput)
        #expect(fixture.source.agentPIDKeysByPanelId[fixture.panelId]?.isEmpty != false)
        #expect(!fixture.source.suppressesRawTerminalNotification(panelId: fixture.panelId))
        await fixture.store.addDesktopNotificationResolvingHooks(
            tabId: fixture.source.id, surfaceId: fixture.panelId, hookDirectory: nil,
            title: "Shell", body: "Human notification after restore"
        )
        #expect(fixture.store.notifications.map(\.body) == ["Human notification after restore"])
    }

    @Test("Hook lifecycle without a wrapper PID suppresses OSC only on its live surface")
    func desktopOSCSuppressionUsesHookLifecycleWithoutPID() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let siblingId = try #require(fixture.source.newTerminalSplit(
            from: fixture.panelId, orientation: .horizontal
        )?.id)

        for phase in [AgentLifecyclePhase.running, .idle, .needsInput] {
            AgentJournalLifecycleCenter.apply(
                AgentLifecycleAssignment(
                    surfaceId: fixture.panelId.uuidString, agentKey: "claude_code", phase: phase
                ),
                workspaceHint: fixture.source.id.uuidString, isLive: true
            )
            #expect(fixture.source.agentPIDKeysByPanelId[fixture.panelId]?.isEmpty != false)
            #expect(fixture.source.suppressesRawTerminalNotification(panelId: fixture.panelId))
            #expect(!fixture.source.suppressesRawTerminalNotification(panelId: siblingId))
        }

        try movePanel(fixture)
        await fixture.store.addDesktopNotificationResolvingHooks(
            tabId: fixture.source.id, surfaceId: fixture.panelId, hookDirectory: nil,
            title: "Attached session", body: "Duplicate completion"
        )
        #expect(fixture.store.notifications.isEmpty)

        AgentJournalLifecycleCenter.apply(
            AgentLifecycleAssignment(
                surfaceId: fixture.panelId.uuidString, agentKey: "claude_code", phase: nil
            ),
            workspaceHint: fixture.destination.id.uuidString
        )
        #expect(!fixture.destination.suppressesRawTerminalNotification(panelId: fixture.panelId))
        await fixture.store.addDesktopNotificationResolvingHooks(
            tabId: fixture.source.id, surfaceId: fixture.panelId, hookDirectory: nil,
            title: "Shell", body: "Human notification after session end"
        )
        #expect(fixture.store.notifications.map(\.body) == ["Human notification after session end"])
    }

    @Test("Live control lifecycle suppresses only structured hook keys", arguments: [
        ("claude_code", true), ("custom-agent", false)
    ])
    func desktopOSCControlLifecycle(agentKey: String, suppresses: Bool) throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let owner = ControlSidebarPanelOwner.workspace(fixture.source)
        // Exercise the same focused-panel fallback as a control lifecycle report.
        owner.setAgentLifecycle(key: agentKey, panelId: nil, lifecycle: .needsInput)
        #expect(fixture.source.suppressesRawTerminalNotification(panelId: fixture.panelId) == suppresses)
        owner.clearAgentLifecycle(key: agentKey, panelId: fixture.panelId)
        #expect(!fixture.source.suppressesRawTerminalNotification(panelId: fixture.panelId))
    }

    @Test("Live hook evidence follows Dock transfers and clears on session end", arguments: [false, true])
    func desktopOSCHookEvidenceAcrossDockTransfer(endsInDock: Bool) throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
        let destinationPane = try #require(fixture.destination.bonsplitController.allPaneIds.first)
        ControlSidebarPanelOwner.workspace(fixture.source).setAgentLifecycle(
            key: "claude_code", panelId: fixture.panelId, lifecycle: .needsInput
        )
        let outbound = try #require(fixture.source.detachSurface(panelId: fixture.panelId))
        #expect(dock.attachDetachedSurface(outbound, inPane: dockPane, focus: false) == fixture.panelId)
        let dockOwner = ControlSidebarPanelOwner.dock(dock)
        dockOwner.setAgentLifecycle(key: "claude_code", panelId: fixture.panelId, lifecycle: .idle)
        if endsInDock {
            dockOwner.clearAgentLifecycle(key: "claude_code", panelId: fixture.panelId)
        }
        let inbound = try #require(dock.detachSurface(panelId: fixture.panelId))
        #expect(fixture.destination.attachDetachedSurface(inbound, inPane: destinationPane, focus: false) == fixture.panelId)
        #expect(fixture.destination.suppressesRawTerminalNotification(panelId: fixture.panelId) == !endsInDock)
    }

    @Test("Machine-shaped OSC never reaches notification history", arguments: [
        ("scheme://target", "Completed"),
        ("custom+notify.v1://target", "Completed"),
        ("SCHEME://target", "Completed"),
        ("Task", #"{"v":1,"event":"stop","query":"<task-notification>"}"#),
        ("Task", " \n [1, {\"event\": \"stop\"}]"),
        ("Task", "Completed\u{001b}[31m"),
        ("Task\u{0007}", "Completed"),
        ("Task", "Completed\u{007f}"),
        ("Task", "Completed\u{0085}")
    ])
    func desktopOSCRejectsMachinePayload(title: String, body: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        await fixture.store.addDesktopNotificationResolvingHooks(
            tabId: fixture.source.id, surfaceId: fixture.panelId, hookDirectory: nil,
            title: title, body: body
        )

        #expect(fixture.store.notifications.isEmpty)
        #expect(!fixture.store.hasUnreadNotification(forTabId: fixture.source.id, surfaceId: fixture.panelId))
        #expect(!fixture.store.hasPendingNotification(forTabId: fixture.source.id, surfaceId: fixture.panelId))
    }

    @Test("Human OSC text remains supported", arguments: [
        ("Build", "Completed"),
        ("", "Completed"),
        ("Build", ""),
        ("Build", "First line\nSecond line\tDetails\r\nDone"),
        ("Build", "[build] completed"),
        ("Build", "{not JSON}"),
        ("Build", "See https://example.com/results"),
        (String(repeating: "x", count: 256), String(repeating: "x", count: 1024)),
        (String(repeating: "x", count: 257), String(repeating: "x", count: 4096))
    ])
    func desktopOSCAcceptsHumanText(title: String, body: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        await fixture.store.addDesktopNotificationResolvingHooks(
            tabId: fixture.source.id, surfaceId: fixture.panelId, hookDirectory: nil,
            title: title, body: body
        )

        #expect(fixture.store.notifications.count == 1)
        #expect(fixture.store.notifications.first?.body == body)
    }

}
