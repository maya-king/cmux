extension AgentNotificationReconciler {
    /// Carries reconciled pending work into surface delivery policy without delaying admission.
    static func completionNotificationEvent(
        _ event: AgentJournalEvent,
        phase: AgentLifecyclePhase
    ) -> AgentJournalEvent? {
        guard event.draft.kind == .turnCompleted, phase != .idle else { return nil }
        // A known surface can enter delivery policy immediately. Keep
        // the semantic receipt so settlement cannot notify twice, and
        // carry child evidence into the user's pending-work gate.
        var pending = event.draft
        pending.pendingWork = true
        return AgentJournalEvent(sequence: event.sequence,
            committedAtMs: event.committedAtMs, draft: pending)
    }
}
