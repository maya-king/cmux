import Foundation

extension DockSplitStore {
    func noteLiveAgentHook(key: String, panelId: UUID) {
        guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(key) else { return }
        mutateAgentRuntime(panelId: panelId) {
            $0.liveAgentHookKeys.insert(key)
        }
    }

    func setAgentLifecycle(
        key: String,
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState
    ) {
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            $0.agentLifecycleStates[key] = lifecycle
        }
    }

    @discardableResult
    func clearAgentLifecycle(key: String, panelId: UUID) -> Bool {
        var didClear = false
        mutateAgentRuntime(panelId: panelId, updatesAgentAttention: true) {
            didClear = $0.agentLifecycleStates.removeValue(forKey: key) != nil
        }
        return didClear
    }

}
