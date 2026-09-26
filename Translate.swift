import Foundation
import Combine

enum TranslationPhase: Equatable {
    case idle
    case busy
    case done(String)
    case failed(String)
}

// Single-message hover translation: one message is translated at a time, with a
// text-keyed cache so hovering the same bubble again never re-bills the AI service.
@MainActor
final class TranslateModel: ObservableObject {
    @Published private(set) var target: MessageBubble?
    @Published private(set) var phase: TranslationPhase = .idle
    @Published private(set) var waitingStatus: String?
    /// 失败时记住是哪条消息，让原因气泡上的「重试」有东西可重试。
    private(set) var failedBubble: MessageBubble?
    private var cache: [String: String] = [:]
    private var task: Task<Void,Never>?
    private var statusTask: Task<Void,Never>?

    // Airouter-style routers expose GET /status at the service root; while a request
    // is in flight we poll it so the UI can show real "switching model" waits.
    static func statusURL() -> URL? {
        guard let endpoint = UserDefaults.standard.string(forKey:"endpoint")?.trimmingCharacters(in:.whitespacesAndNewlines),
              !endpoint.isEmpty, let url = URL(string:endpoint),
              let scheme = url.scheme, let host = url.host else { return nil }
        var base = "\(scheme)://\(host)"
        if let port = url.port { base += ":\(port)" }
        return URL(string: base + "/status")
    }

    private func startStatusPolling() {
        statusTask?.cancel()
        waitingStatus = nil
        guard let url = Self.statusURL() else { return }
        statusTask = Task { [weak self] in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 2
            config.timeoutIntervalForResource = 2
            let session = URLSession(configuration:config)
            defer { session.finishTasksAndInvalidate() }
            while !Task.isCancelled {
                if let (data,_) = try? await session.data(from:url),
                   let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                   let requests = root["requests"] as? [String:Any] {
                    let switching = requests["mode_switching"] as? Bool ?? false
                    let queued = requests["queued_local_requests"] as? Int ?? 0
                    self?.waitingStatus = (switching || queued > 0) ? "等待切换模型中…" : nil
                }
                try? await Task.sleep(nanoseconds:1_000_000_000)
            }
        }
    }

    private func stopStatusPolling() {
        statusTask?.cancel()
        statusTask = nil
        waitingStatus = nil
    }

    func show(_ bubble: MessageBubble) {
        let key = bubble.text
        target = bubble
        if let cached = cache[key] {
            failedBubble = nil
            phase = .done(cached)
            return
        }
        guard phase != .busy || target?.text != key else { return }
        phase = .busy
        startStatusPolling()
        task?.cancel()
        task = Task { [weak self] in
            do {
                let configuration = try Self.configuration()
                let translation = try await APIClient().translate(key,target:APIClient.incomingTarget,configuration:configuration)
                guard let self, !Task.isCancelled, self.target?.text == key else { return }
                self.cache[key] = translation
                self.failedBubble = nil
                self.phase = .done(translation)
                self.stopStatusPolling()
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.target?.text == key else { return }
                self.phase = .failed(error.localizedDescription)
                // 失败必须留下痕迹：记住这条消息，并让 AppDelegate 弹原因气泡。
                // target 留着不会卡住悬停按钮——按钮只在 phase == .busy 时转圈。
                self.failedBubble = self.target
                self.stopStatusPolling()
            }
        }
    }

    /// 原因气泡上的「重试」：清掉失败态，对同一条消息重新发一次。
    func retry() {
        guard let bubble = failedBubble else { return }
        failedBubble = nil
        phase = .idle
        show(bubble)
    }

    func dismiss() {
        task?.cancel(); task = nil
        stopStatusPolling()
        target = nil
        failedBubble = nil
        phase = .idle
    }

    var doneText: String? {
        if case .done(let translation) = phase { return translation }
        return nil
    }

    static func configuration() throws -> APIConfiguration {
        let endpoint = UserDefaults.standard.string(forKey:"endpoint") ?? "https://api.openai.com/v1"
        let model = UserDefaults.standard.string(forKey:"model") ?? ""
        let casualPrompt = UserDefaults.standard.string(forKey:"casualPrompt") ?? APIClient.defaultCasualPrompt
        let formalPrompt = UserDefaults.standard.string(forKey:"formalPrompt") ?? APIClient.defaultFormalPrompt
        return APIConfiguration(endpoint:endpoint,model:model,key:try SecretStore.read(endpoint),casualPrompt:casualPrompt,formalPrompt:formalPrompt)
    }
}
