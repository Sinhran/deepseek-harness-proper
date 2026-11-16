import Foundation

/// Opt-in local UI fixtures. Never reads a real API key or writes production sessions.
enum Preview {
    static var enabled: Bool { CommandLine.arguments.contains("--preview") }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewProtocol.self]
        return URLSession(configuration: configuration)
    }()
    static func seed() {
        let titles = ["Research notes for the launch", "A cleaner project structure", "Weekly report, without the busywork"]
        for title in titles.reversed() {
            var session = SessionStore.shared.newSession(workspace: Settings.shared.workspace)
            session.title = title
            SessionStore.shared.touch(session)
        }
        var conversation = SessionStore.shared.newSession(workspace: Settings.shared.workspace)
        conversation.title = "Make the model picker future-proof"
        conversation.model = "fixture/fast"
        conversation.changes = [FileChange(path: Settings.shared.workspace + "/Sources/dsh/ModelCatalog.swift",
                                           before: "let models = [\"deepseek-chat\", \"deepseek-reasoner\"]\n",
                                           after: "let models = try await client.models()\n", turn: 1)]
        conversation.messages = [
            Message(role: .user, content: "Fetch models from the API instead of keeping a hardcoded list. Keep the selection when possible."),
            Message(role: .assistant, content: "I'll trace the model selection from the composer through to the request, then replace the static list.",
                    steps: [Step(name: "read", payload: "{\"file_path\":\"Sources/dsh/DeepSeekClient.swift\"}", result: "Read 164 lines", status: .ok, durationMS: 12),
                            Step(name: "read", payload: "{\"file_path\":\"Sources/dsh/UI/Composer.swift\"}", result: "Read 203 lines", status: .ok, durationMS: 8),
                            // A file-writing step: shows the Review link and a sub-second duration.
                            Step(name: "edit", payload: "{\"file_path\":\"Sources/dsh/ModelCatalog.swift\",\"old_string\":\"let models = [\\\"deepseek-chat\\\", \\\"deepseek-reasoner\\\"]\",\"new_string\":\"let models = try await client.models()\"}",
                                 result: "edited Sources/dsh/ModelCatalog.swift (1 replacement)", status: .ok, durationMS: 340)]),
            Message(role: .assistant, content: """
            The model picker now stays in sync with the API.

            - **Discovered, not hardcoded.** Models come from `GET /models`.
            - **Selection is preserved** if the model is still available.
            - **Nothing fails silently.** Loading and connection errors appear inline.

            ```swift
            let models = try await client.models()
            picker.setModels(models, preferred: session.model)
            ```

            The selected model is passed directly into the next request. No alias or fallback list in between.
            """),
            // A second turn, so the fixture shows both turn-tail states:
            // earlier turn (Branch + Rewind on hover), latest (Branch + Regenerate).
            Message(role: .user, content: "Also mark which models support tool calls.", turn: 2),
            Message(role: .assistant, content: "Done. Models that support tool calls now show a small wrench badge in the picker.", turn: 2),
        ]
        // Mirror the messages into the API transcript the way AgentLoop.run
        // does, so turn-level actions (Branch, Rewind) see a consistent session.
        conversation.wire += conversation.messages.compactMap { m in
            switch m.role {
            case .user: return WireMessage(role: .user, content: m.content)
            case .assistant: return WireMessage(role: .assistant, content: m.content)
            default: return nil
            }
        }
        SessionStore.shared.touch(conversation)
        if !CommandLine.arguments.contains("--conversation") {
            _ = SessionStore.shared.newSession(workspace: Settings.shared.workspace)
        }
    }
}

final class PreviewProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path.hasSuffix("/models") == true {
            let json = "{\"data\":[{\"id\":\"fixture/fast\"},{\"id\":\"fixture/reasoning\"}]}"
            respond(json, type: "application/json")
        } else {
            let text = "The connection is working. This is a local UI test response, not a request to DeepSeek.\n\nYour message and selected model reached the streaming client successfully."
            let chunk: [String: Any] = ["choices": [["delta": ["content": text]]]]
            respond("data: \(JSON.compact(chunk))\n\ndata: [DONE]\n\n", type: "text/event-stream")
        }
    }
    private func respond(_ string: String, type: String) {
        guard let url = request.url else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(string.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
