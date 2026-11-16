import Foundation

extension Notification.Name {
    static let settingsChanged = Notification.Name("HarnessSettingsChanged")
    static let modelsChanged = Notification.Name("HarnessModelsChanged")
}

@MainActor
final class ModelCatalog {
    static let shared = ModelCatalog()

    nonisolated static func preferredModel(models: [String], settingsDefault: String, sessionModel: String) -> String {
        // The session's own pick wins when still valid; the global default
        // only seeds sessions that never chose one of their own.
        if models.contains(sessionModel) { return sessionModel }
        if models.contains(settingsDefault) { return settingsDefault }
        return models.first ?? sessionModel
    }

    enum State { case disconnected, loading, ready, failed(String) }
    private(set) var state: State = .disconnected
    private(set) var models: [String] = []
    private var task: Task<Void, Never>?

    func refresh() {
        task?.cancel()
        models = []
        guard !Settings.shared.apiKey.isEmpty else {
            state = .disconnected; notify(); return
        }
        state = .loading; notify()
        let client = DeepSeekClient()
        client.config = .init(baseURL: Settings.shared.baseURL, apiKey: Settings.shared.apiKey)
        task = Task {
            do {
                let fetched = try await client.models()
                guard !Task.isCancelled else { return }
                models = fetched; state = .ready
                // Never overwrite the persisted default here: the effective model
                // falls back via preferredModel(...) at selection time, and only
                // an explicit user pick persists a new Settings.model.
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
            notify()
        }
    }
    private func notify() { NotificationCenter.default.post(name: .modelsChanged, object: nil) }
}
